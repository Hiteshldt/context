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
    var body: some View {
        ContentView()
            .onAppear { MainWindow.opener = { openWindow(id: "main") } }
            .onChange(of: globalShortcut) { _, on in GlobalHotKey.shared.setEnabled(on) }
    }
}

/// The menu bar launcher: find and open any link without switching to the main window.
struct MenuBarPanel: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let due = Buckets.needsAttention(store.workspace.tasks).count
        VStack(spacing: 0) {
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
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.plain).foregroundStyle(Theme.ink2).help("Quit Context")
            }
            .font(T.small)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 400)
        .background(Theme.card)
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
