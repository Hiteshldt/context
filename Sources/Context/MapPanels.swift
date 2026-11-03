import SwiftUI

/// What a double-click on the map offers: name a box, paste a link, or pick one of the project's links.
struct QuickAddPanel: View {
    @EnvironmentObject var store: Store
    @Environment(\.pageTint) var tint
    let projectID: UUID
    let onMap: Set<UUID>
    let addBox: (String, NodeKind) -> Void
    let addLink: (Entry) -> Void
    let place: (Entry) -> Void
    let locate: (Entry) -> Void
    let detailed: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var pasted: Entry? { Entry.quick(url: trimmed, projectID: projectID) }

    var matches: [Entry] {
        store.workspace.entries
            .filter { $0.projectID == projectID && EntryKind.linkKinds.contains($0.kind) }
            .filter { trimmed.isEmpty || pasted != nil || [$0.title, $0.url, $0.category].contains { $0.localizedCaseInsensitiveContains(trimmed) } }
            .sorted { (onMap.contains($0.id) ? 1 : 0, $0.title.lowercased()) < (onMap.contains($1.id) ? 1 : 0, $1.title.lowercased()) }
            .prefix(7).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").font(.system(size: 15)).foregroundStyle(tint)
                TextField("Name a box, or paste a link", text: $text)
                    .textFieldStyle(.plain).font(T.body).focused($focused).onSubmit(primary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tint.opacity(0.5)))

            if let link = pasted {
                choice(primary: true, action: { addLink(link) }) {
                    EntryIcon(entry: link, size: 28)
                } text: {
                    Text("Add \(link.title)").font(T.bodyMedium).foregroundStyle(Theme.ink)
                    Text("\(link.kind.shortName) · \(BrandCatalog.host(of: link.url) ?? "")").font(T.caption).foregroundStyle(Theme.ink2)
                }
            } else if !trimmed.isEmpty {
                choice(primary: true, action: { addBox(trimmed, .step) }) {
                    Image(systemName: "square.dashed").font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                        .frame(width: 28, height: 28).background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } text: {
                    Text("Add a box “\(trimmed)”").font(T.bodyMedium).foregroundStyle(Theme.ink).lineLimit(1)
                    Text("Or pick a kind of box below").font(T.caption).foregroundStyle(Theme.ink2)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Box")
                HStack(spacing: 5) {
                    ForEach(NodeKind.allCases) { kind in
                        Button { addBox(trimmed, kind) } label: {
                            Image(systemName: kind.icon).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.color(kind.tint))
                                .frame(width: 27, height: 27).background(Theme.color(kind.tint).opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }.buttonStyle(.plain).help(kind.name)
                    }
                }
            }

            if !matches.isEmpty && pasted == nil {
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(text: trimmed.isEmpty ? "Your links" : "Matching links").padding(.bottom, 4)
                    ForEach(matches) { entry in
                        let placed = onMap.contains(entry.id)
                        choice(action: { placed ? locate(entry) : place(entry) }) {
                            EntryIcon(entry: entry, size: 24)
                        } text: {
                            Text(entry.title).font(T.small).foregroundStyle(Theme.ink).lineLimit(1)
                        } trailing: {
                            if placed { Text("On map").font(T.caption).foregroundStyle(Theme.ink3) }
                            else { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(tint) }
                        }
                    }
                }
            }

            Rectangle().fill(Theme.border).frame(height: 1)
            Button { detailed() } label: { Label("New link with account, notes, or passwords…", systemImage: "link.badge.plus").font(T.small) }
                .buttonStyle(.plain).foregroundStyle(tint)
        }
        .padding(14).frame(width: 340)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } }
    }

    /// Return does the obvious thing: adds the pasted link, places an existing link with that exact name, or adds a box.
    func primary() {
        if let link = pasted { addLink(link); return }
        guard !trimmed.isEmpty else { return }
        if let existing = matches.first(where: { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            onMap.contains(existing.id) ? locate(existing) : place(existing)
        } else {
            addBox(trimmed, .step)
        }
    }

    func choice<Icon: View, Label: View, Trailing: View>(primary: Bool = false, action: @escaping () -> Void, @ViewBuilder icon: () -> Icon,
                                                        @ViewBuilder text: () -> Label, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon()
                VStack(alignment: .leading, spacing: 1) { text() }
                Spacer(minLength: 6)
                trailing()
                if primary { KeyHint(keys: "↩") }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(primary ? tint.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Every link of the project, beside the map: open, edit, or put them on the map.
struct MapLinksPanel: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var reminders = RemindersService.shared
    @Environment(\.present) var present
    @Environment(\.pageTint) var tint
    let projectID: UUID
    let onMap: Set<UUID>
    let place: (Entry) -> Void
    let locate: (Entry) -> Void
    let newLink: () -> Void
    let close: () -> Void
    @State private var query = ""
    @State private var deleting: Entry?

    var entries: [Entry] {
        store.workspace.entries.filter { $0.projectID == projectID }
            .filter { entry in
                query.isEmpty || [entry.title, entry.url, entry.category, entry.account, entry.body].contains { $0.localizedCaseInsensitiveContains(query) }
                    || entry.tags.contains { $0.localizedCaseInsensitiveContains(query) }
            }
            .sorted { ($0.pinned ? 0 : 1, $0.title.lowercased()) < ($1.pinned ? 0 : 1, $1.title.lowercased()) }
    }

    var body: some View {
        let all = entries
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Eyebrow(text: "Links")
                Spacer()
                Button { newLink() } label: { Label("New", systemImage: "plus") }.buttonStyle(.softCompact).help("Add a link and place it on the map")
                IconButton(icon: "xmark", help: "Close (Esc)", size: 22, action: close)
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                TextField("Filter", text: $query).textFieldStyle(.plain).font(T.small)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
            .padding(.horizontal, 14).padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    looseReminders
                    if all.isEmpty {
                        Text(query.isEmpty ? "No links yet. Double-click the map and paste a link, or click New." : "Nothing matches.")
                            .font(T.small).foregroundStyle(Theme.ink2).padding(.horizontal, 6).padding(.vertical, 10)
                    }
                    ForEach(EntryKind.linkKinds + EntryKind.noteKinds) { kind in
                        let group = all.filter { $0.kind == kind }
                        if !group.isEmpty {
                            Text(kind.groupName.uppercased()).font(T.label).tracking(1).foregroundStyle(Theme.ink3)
                                .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 3)
                            ForEach(group) { row($0) }
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            Text("Click to open · ＋ puts it on the map").font(T.caption).foregroundStyle(Theme.ink3)
                .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let deleting { store.deleteEntry(deleting.id) }; deleting = nil }
        } message: {
            Text((deleting?.credentials.isEmpty ?? true) ? "This removes the link from Context. Boxes on the map that show it are marked as removed."
                                                         : "This also deletes \(deleting!.credentials.count) saved password(s) from the Keychain.")
        }
    }

    /// Reminders in the project that aren't on any box (from before reminders lived on boxes, or made in Apple
    /// Reminders), so they're never lost. New ones are added from a box's details.
    @ViewBuilder var looseReminders: some View {
        if reminders.access == .granted, let project = store.project(projectID) {
            let loose = reminders.byBox(for: project, in: store.workspace).loose.filter { !$0.isCompleted }.sorted(by: ReminderItem.order)
            if !loose.isEmpty {
                Text("REMINDERS NOT ON A BOX").font(T.label).tracking(1).foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 3)
                ForEach(loose) { ReminderRow(item: $0) }
            }
        }
    }

    func row(_ entry: Entry) -> some View {
        let placed = onMap.contains(entry.id)
        let url = webURL(entry.url)
        return HStack(spacing: 10) {
            EntryIcon(entry: entry, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(entry.title.ifEmpty("Untitled")).font(T.small.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    if !entry.credentials.isEmpty { Image(systemName: "lock.fill").font(.system(size: 8.5)).foregroundStyle(Theme.ink3) }
                }
                Text(BrandCatalog.host(of: entry.url) ?? entry.kind.shortName).font(T.caption).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            Spacer(minLength: 4)
            if EntryKind.linkKinds.contains(entry.kind) {
                IconButton(icon: placed ? "scope" : "plus.circle", help: placed ? "Show it on the map" : "Put it on the map", size: 24, tint: placed ? Theme.ink3 : tint) {
                    placed ? locate(entry) : place(entry)
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .hoverRow(radius: 8)
        .contentShape(Rectangle())
        .onTapGesture { if url != nil { store.open(entry) } else { present(.entry(entry)) } }
        .help(url.map { "Open \($0.host() ?? "")" } ?? "Edit")
        .contextMenu {
            if let url {
                Button("Open") { store.open(entry) }
                OpenInBrowserMenu(url: url)
                Button("Copy Link") { copyToClipboard(url.absoluteString) }
            }
            Button("Edit…") { present(.entry(entry)) }
            if EntryKind.linkKinds.contains(entry.kind) { Button(placed ? "Show on Map" : "Put on Map") { placed ? locate(entry) : place(entry) } }
            Button(entry.pinned ? "Unpin" : "Pin to Top") { store.togglePin(entry) }
            Divider()
            Button("Delete…", role: .destructive) { deleting = entry }
        }
    }
}
