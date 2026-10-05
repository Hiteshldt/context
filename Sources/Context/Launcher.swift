import SwiftUI
import AppKit

/// ⌘K: find and open anything. Used in the main window and in the menu bar.
struct LauncherView: View {
    @EnvironmentObject var store: Store
    @Environment(\.pageTint) var tint
    var compact = false
    /// `alternate` is true for ⌘↩ (show in its project instead of opening).
    let onActivate: (LauncherTarget, _ alternate: Bool) -> Void
    var onClose: () -> Void = {}
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    var results: [LauncherResult] { LauncherSearch.results(for: query, in: store.workspace, limit: compact ? 8 : 10) }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: compact ? 14 : 17, weight: .medium)).foregroundStyle(Theme.ink3)
                TextField("Search links, notes, projects…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: compact ? 15 : 19))
                    .focused($focused)
                    .onSubmit { activate(results, alternate: false) }
                    .onKeyPress(.downArrow) { move(1, count: results.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: results.count); return .handled }
                    .onKeyPress(.escape) { onClose(); return .handled }
                    .onKeyPress(keys: [.return]) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        activate(results, alternate: true)
                        return .handled
                    }
                if !compact { KeyHint(keys: "esc") }
            }
            .padding(.horizontal, compact ? 14 : 18).padding(.vertical, compact ? 11 : 15)
            Rectangle().fill(Theme.border).frame(height: 1)

            if results.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing matches “\(query)”").font(T.bodyMedium).foregroundStyle(Theme.ink)
                    Text("Try a service name, a word from a note, or a project.").font(T.small).foregroundStyle(Theme.ink2)
                }.frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                                Eyebrow(text: "Jump back in").padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
                            }
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                LauncherRow(result: result, selected: index == selected, compact: compact)
                                    .id(index)
                                    .onTapGesture { selected = index; activate(results, alternate: false) }
                                    .onHover { if $0 { selected = index } }
                            }
                        }.padding(6)
                    }
                    .frame(maxHeight: compact ? 330 : 430)
                    .onChange(of: selected) { _, value in proxy.scrollTo(value) }
                }
            }
            if !compact {
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(spacing: 14) {
                    hint("↩", "Open")
                    hint("⌘↩", "Show in project")
                    hint("↑↓", "Move")
                    Spacer()
                    Text("Works from anywhere with ⌃⌥Space").font(T.caption).foregroundStyle(Theme.ink3)
                }.padding(.horizontal, 16).padding(.vertical, 9)
            }
        }
        .onAppear { focused = true; selected = 0 }
        .onChange(of: query) { _, _ in selected = 0 }
    }

    func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 5) { KeyHint(keys: keys); Text(label).font(T.caption).foregroundStyle(Theme.ink2) }
    }

    func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selected = (selected + delta + count) % count
    }

    func activate(_ results: [LauncherResult], alternate: Bool) {
        guard results.indices.contains(selected) else { return }
        onActivate(results[selected].target, alternate)
        query = ""
    }
}

struct LauncherRow: View {
    @EnvironmentObject var store: Store
    @Environment(\.pageTint) var tint
    let result: LauncherResult
    let selected: Bool
    var compact = false

    var body: some View {
        HStack(spacing: 11) {
            icon.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title).font(.system(size: compact ? 13.5 : 14.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(result.subtitle).font(T.caption).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            Spacer(minLength: 8)
            if selected { Text(verb).font(T.caption).foregroundStyle(Theme.ink2); KeyHint(keys: "↩") }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? tint.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }

    var verb: String {
        switch result.target {
        case .entry(let id):
            guard let entry = store.entry(id) else { return "Open" }
            return webURL(entry.url) != nil ? "Open in browser" : (entry.kind == .note || entry.kind == .prompt ? "Open note" : "Edit")
        case .project, .client: return "Go to"
        case .task: return "Open task"
        case .action: return "Run"
        }
    }

    @ViewBuilder var icon: some View {
        switch result.target {
        case .entry(let id):
            if let entry = store.entry(id) {
                if entry.kind == .note || entry.kind == .prompt { symbol(entry.kind.icon, Theme.color(store.project(entry.projectID)?.color ?? "sage")) }
                else { EntryIcon(entry: entry, size: 30) }
            }
        case .project(let id):
            if let project = store.project(id) { ProjectIcon(project: project, size: 30) }
        case .client(let id):
            ClientIcon(name: store.client(id)?.name ?? "", size: 30)
        case .task:
            symbol("checkmark.circle", Theme.today)
        case .action(let action):
            symbol(action.icon, tint)
        }
    }

    func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            .frame(width: 30, height: 30).background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The launcher floating over the main window.
struct LauncherOverlay: View {
    let onActivate: (LauncherTarget, Bool) -> Void
    let onClose: () -> Void
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.28).ignoresSafeArea().onTapGesture(perform: onClose)
            LauncherView(onActivate: onActivate, onClose: onClose)
                .frame(width: 640)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
                .shadow(color: .black.opacity(0.3), radius: 40, y: 18)
                .padding(.top, 96)
        }
        .transition(.opacity)
    }
}
