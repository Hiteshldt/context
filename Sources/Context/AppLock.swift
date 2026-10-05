import SwiftUI
import AppKit
import LocalAuthentication

/// Optionally requires Touch ID or the Mac's password before Context shows any data.
/// While locked, the main window shows only the lock screen, the menu bar panel hides its contents,
/// and menu commands that read data are disabled. Background backups and reminders keep running.
/// This guards the app's windows; the data files themselves are protected by the Mac account, not encrypted.
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()

    /// How long Context can sit in the background before it locks again.
    enum AutoLock: Int, CaseIterable, Identifiable {
        case immediately = 0, oneMinute = 60, fiveMinutes = 300, fifteenMinutes = 900, oneHour = 3600, never = -1
        var id: Int { rawValue }
        var name: String {
            switch self {
            case .immediately: return "Immediately"
            case .oneMinute: return "After 1 Minute"
            case .fiveMinutes: return "After 5 Minutes"
            case .fifteenMinutes: return "After 15 Minutes"
            case .oneHour: return "After 1 Hour"
            case .never: return "Only When the Mac Sleeps or Locks"
            }
        }
    }

    @Published private(set) var enabled: Bool
    @Published private(set) var isLocked: Bool
    @Published var autoLock: AutoLock { didSet { defaults.set(autoLock.rawValue, forKey: "appLockAfter") } }
    @Published private(set) var authenticating = false
    @Published var message: String?

    private let defaults = UserDefaults.standard
    private var leftAt: Date?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let on = defaults.bool(forKey: "appLock")
        enabled = on
        isLocked = on
        autoLock = AutoLock(rawValue: defaults.object(forKey: "appLockAfter") as? Int ?? AutoLock.fiveMinutes.rawValue) ?? .fiveMinutes
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didLeave() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didReturn() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        })
    }

    /// "Touch ID" on Macs that have it, otherwise "Password".
    var method: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID ? "Touch ID" : "Password"
    }

    func lock() {
        guard enabled else { return }
        isLocked = true
    }

    func unlock() async {
        guard isLocked, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        if await authenticate(reason: "unlock Context") {
            isLocked = false
            message = nil
            leftAt = nil
        }
    }

    /// Turning the lock on or off both need the owner's Touch ID or password.
    func setEnabled(_ on: Bool) async {
        guard on != enabled, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        guard await authenticate(reason: on ? "require Touch ID or your password to open Context" : "stop requiring Touch ID or your password to open Context") else { return }
        leftAt = nil
        enabled = on
        defaults.set(on, forKey: "appLock")
        if !on { isLocked = false }
    }

    private func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            message = "This Mac can't check Touch ID or a password right now. \(error?.localizedDescription ?? "")"
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let failure as LAError where failure.code == .userCancel || failure.code == .appCancel || failure.code == .systemCancel {
            return false
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    private func didLeave() {
        // The Touch ID / password prompt itself can make Context inactive; that isn't leaving.
        guard !authenticating else { return }
        leftAt = Date()
        if autoLock == .immediately { lock() }
    }

    private func didReturn() {
        defer { leftAt = nil }
        guard enabled, !isLocked, let leftAt, autoLock != .never else { return }
        if Date().timeIntervalSince(leftAt) >= Double(autoLock.rawValue) { isLocked = true }
    }
}

/// Shown in place of the main window's contents while Context is locked.
struct LockScreen: View {
    @ObservedObject var lock = AppLock.shared

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
            VStack(spacing: 6) {
                Text("Context is locked").font(T.display(30)).foregroundStyle(Theme.ink)
                Text("Unlock with \(lock.method == "Touch ID" ? "Touch ID or your Mac password" : "your Mac password") to see your projects.")
                    .font(T.body).foregroundStyle(Theme.ink2)
            }
            Button { Task { await lock.unlock() } } label: {
                Label("Unlock", systemImage: lock.method == "Touch ID" ? "touchid" : "lock.open.fill").padding(.horizontal, 8)
            }
            .buttonStyle(.primary).keyboardShortcut(.defaultAction).disabled(lock.authenticating)
            if let message = lock.message {
                Text(message).font(T.small).foregroundStyle(Theme.overdue).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .overlay(alignment: .top) { WindowDragArea().frame(height: 36) }
        .task { await lock.unlock() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await lock.unlock() }
        }
    }
}
