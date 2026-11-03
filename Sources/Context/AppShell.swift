import SwiftUI
import AppKit

/// Brings the main window forward, reopening it if it was closed.
enum MainWindow {
    @MainActor static var opener: (() -> Void)?
    @MainActor static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true || ($0.canBecomeMain && $0.title == "Context") }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            opener?()
        }
    }
}

/// Wraps the main view so the window can be reopened from the menu bar and global shortcut.
struct RootView: View {
    @Environment(\.openWindow) var openWindow
    @AppStorage("globalShortcut") private var globalShortcut = true
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @ObservedObject private var lock = AppLock.shared
    var body: some View {
        Group {
            if lock.isLocked { LockScreen() } else { ContentView() }
        }
            .onAppear { MainWindow.opener = { openWindow(id: "main") } }
            .onChange(of: globalShortcut) { _, on in GlobalHotKey.shared.setEnabled(on) }
            .onChange(of: appearance) { _, value in AppAppearance.apply(AppAppearance(rawValue: value) ?? .system) }
    }
}

/// The menu bar launcher: find and open any link without switching to the main window.
struct MenuBarPanel: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var lock = AppLock.shared
    @ObservedObject private var reminders = RemindersService.shared
    var body: some View {
        if lock.isLocked { locked } else { panel }
    }

    var locked: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.system(size: 22)).foregroundStyle(Theme.ink3)
            Text("Context is locked").font(T.bodyMedium).foregroundStyle(Theme.ink)
            Button { Task { await lock.unlock() } } label: { Label("Unlock", systemImage: lock.method == "Touch ID" ? "touchid" : "lock.open.fill") }
                .buttonStyle(.primaryCompact).disabled(lock.authenticating)
        }
        .padding(24).frame(width: 400).background(Theme.card)
    }

    var panel: some View {
        let due = store.workspace.projects.reduce(0) { $0 + reminders.attentionCount(for: $1) }
        return VStack(spacing: 0) {
            LauncherView(compact: true, onActivate: { target, alternate in
                if case .entry(let id) = target, let entry = store.entry(id), webURL(entry.url) != nil, !alternate {
                    store.open(entry)
                    NSApp.keyWindow?.close()
                } else {
                    NSApp.keyWindow?.close()
                    MainWindow.show()
                    NotificationCenter.default.post(name: .contextOpenTarget, object: target)
                }
            }, onClose: { NSApp.keyWindow?.close() })
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 10) {
                if due > 0 {
                    Label("\(due) due today", systemImage: "exclamationmark.circle.fill").foregroundStyle(Theme.overdue)
                } else {
                    Label("Nothing due", systemImage: "checkmark.circle").foregroundStyle(Theme.ink2)
                }
                Spacer()
                Button("Open Context") { NSApp.keyWindow?.close(); MainWindow.show() }.buttonStyle(.softCompact)
                IconButton(icon: "power", help: "Quit Context", size: 26) { NSApp.terminate(nil) }
            }
            .font(T.small)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 400)
        .background(Theme.card)
    }
}

/// Mouse and trackpad behaviour for the main window, matching other Mac apps:
/// - a click acts straight away, even when Context was behind another app (instead of only bringing the window forward);
/// - swiping sideways (two or three fingers, per the trackpad setting) or a mouse's side buttons go back and forward.
@MainActor
final class WindowGestures {
    var back: () -> Void = {}
    var forward: () -> Void = {}
    private var monitor: Any?
    /// How far the current trackpad scroll has gone, or nil when it can't be a page swipe.
    private var swipe: CGSize?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseUp, .scrollWheel, .swipe]) { [weak self] event in
            self?.handle(event, in: event.window) ?? event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func handle(_ event: NSEvent, in window: NSWindow?) -> NSEvent? {
        // Only the main window: not sheets, popovers, menus, or the menu bar panel.
        guard let window, window.canBecomeMain, window.attachedSheet == nil else { return event }
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        case .otherMouseUp where event.buttonNumber == 3:
            back(); return nil
        case .otherMouseUp where event.buttonNumber == 4:
            forward(); return nil
        case .swipe:
            // Positive is the swipe Safari treats as Back.
            if event.deltaX > 0 { back() } else if event.deltaX < 0 { forward() }
        case .scrollWheel:
            trackSwipe(event, in: window)
        default: break
        }
        return event
    }

    /// With "Swipe between pages" set to two fingers, page swipes arrive as scrolling. A mostly sideways scroll that
    /// starts over something that can't scroll sideways itself (so not the map) goes back or forward when it ends.
    private func trackSwipe(_ event: NSEvent, in window: NSWindow) {
        guard NSEvent.isSwipeTrackingFromScrollEventsEnabled, event.hasPreciseScrollingDeltas else { return }
        if event.phase == .began {
            let view = window.contentView?.superview?.hitTest(event.locationInWindow)
            swipe = Self.scrollsSideways(view) ? nil : .zero
        }
        guard var total = swipe, !event.phase.isEmpty else { return }
        total.width += event.scrollingDeltaX
        total.height += event.scrollingDeltaY
        swipe = total
        guard event.phase == .ended || event.phase == .cancelled else { return }
        swipe = nil
        guard event.phase == .ended, abs(total.width) > 60, abs(total.width) > abs(total.height) * 2 else { return }
        // Fingers moving right go back, whichever way the user has scrolling set to run.
        let fingersRight = (total.width > 0) == event.isDirectionInvertedFromDevice
        if fingersRight { back() } else { forward() }
    }

    /// Whether `view` sits in something that scrolls sideways, which should get sideways scrolls instead.
    static func scrollsSideways(_ view: NSView?) -> Bool {
        var current = view
        while let candidate = current {
            if let scroll = candidate as? NSScrollView,
               scroll.hasHorizontalScroller || (scroll.documentView?.frame.width ?? 0) > scroll.contentView.bounds.width + 1 {
                return true
            }
            current = candidate.superview
        }
        return false
    }
}

/// An invisible strip along the top of the window that drags it (and zooms on double-click), like a title bar.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: NSViewRepresentableContext<WindowDragArea>) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: NSViewRepresentableContext<WindowDragArea>) {}
}
