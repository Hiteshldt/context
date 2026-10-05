import SwiftUI
import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Runs any pending backup before quitting.
    static var onTerminate: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        GlobalHotKey.shared.setEnabled(UserDefaults.standard.object(forKey: "globalShortcut") as? Bool ?? true)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) { Self.onTerminate?() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.show() }
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            MainWindow.show()
            NotificationCenter.default.post(name: .contextShowHome, object: nil)
        }
        completionHandler()
    }
}

@main
struct ContextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store: Store
    @StateObject private var backup: BackupManager

    init() {
        let store = Store()
        let backup = BackupManager(directory: store.disk.directory)
        backup.provider = { [weak store] in
            guard let store, !store.loadFailed else { return nil }
            return try? store.disk.encode(store.workspace)
        }
        store.onChange = { [weak backup] in backup?.noteChange() }
        AppDelegate.onTerminate = { [weak backup] in MainActor.assumeIsolated { backup?.flush() } }
        _store = StateObject(wrappedValue: store)
        _backup = StateObject(wrappedValue: backup)
        GlobalHotKey.shared.action = {
            MainWindow.show()
            NotificationCenter.default.post(name: .contextShowLauncher, object: nil)
        }
    }

    var body: some Scene {
        Window("Context", id: "main") {
            RootView()
                .environmentObject(store).environmentObject(backup)
                .frame(minWidth: 1060, minHeight: 700)
                .task { await store.syncReminders() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { post(.contextNewNote) }.keyboardShortcut("n")
                Button("New Task…") { post(.contextNewTask) }.keyboardShortcut("t")
                Button("New Project…") { post(.contextNewProject) }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Client…") { post(.contextNewClient) }
            }
            CommandMenu("Go") {
                Button("Search or Jump To…") { post(.contextShowLauncher) }.keyboardShortcut("k")
                Button("Home") { post(.contextShowHome) }.keyboardShortcut("1")
            }
            CommandMenu("Backup") {
                Button("Back Up Now") { if backup.isConfigured { backup.backupNow() } else { post(.contextShowBackup) } }.keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Backup & Restore…") { post(.contextShowBackup) }
                Divider()
                Button("Export a Backup File…") { store.exportBackup() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Import a Backup File…") { store.restoreBackup() }
                Divider()
                Button("Show Local Data in Finder") { NSWorkspace.shared.open(store.disk.directory) }
            }
        }
        MenuBarExtra {
            MenuBarPanel().environmentObject(store).environmentObject(backup)
        } label: {
            Image(systemName: "square.stack.3d.up.fill")
        }
        .menuBarExtraStyle(.window)
    }

    func post(_ name: Notification.Name) {
        MainWindow.show()
        NotificationCenter.default.post(name: name, object: nil)
    }
}

