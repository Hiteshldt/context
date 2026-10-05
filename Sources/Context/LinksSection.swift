import SwiftUI

/// Everything a project links to — services, social accounts, repositories, websites, documents, AI chats.
struct LinksSection: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    let project: Project
    @State private var filter: EntryKind?
    @State private var query = ""
    @State private var tag: String?

    var all: [Entry] {
        store.workspace.entries.filter { $0.projectID == project.id && EntryKind.linkKinds.contains($0.kind) }
            .sorted { ($0.pinned ? 0 : 1, $0.title.lowercased()) < ($1.pinned ? 0 : 1, $1.title.lowercased()) }
    }
    var shown: [Entry] {
        all.filter { entry in
            (filter == nil || entry.kind == filter) && (tag == nil || entry.tags.contains(tag!)) &&
            (query.isEmpty || [entry.title, entry.url, entry.category, entry.account, entry.body, entry.environment].contains { $0.localizedCaseInsensitiveContains(query) } || entry.tags.contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }
    var tags: [String] { Array(Set(all.flatMap(\.tags))).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                    TextField("Filter links", text: $query).textFieldStyle(.plain).font(T.small).frame(width: 170)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
                Spacer()
                AddLinkMenu(projectID: project.id)
            }
            .padding(.horizontal, 40).padding(.vertical, 14)
            Rectangle().fill(Theme.border).frame(height: 1)
            Page(spacing: 18) { list }
        }
    }

    @ViewBuilder var list: some View {
        if !all.isEmpty {
            HStack(spacing: 12) {
                ChipPicker(options: [(nil, "All  \(all.count)")] + EntryKind.linkKinds.compactMap { kind in
                    let count = all.filter { $0.kind == kind }.count
                    return count == 0 ? nil : (Optional(kind), "\(kind.filterName)  \(count)")
                }, selection: $filter)
                if !tags.isEmpty {
                    Menu {
                        Button("Any tag") { tag = nil }
                        ForEach(tags, id: \.self) { t in Button(t) { tag = t } }
                    } label: { Label(tag ?? "Tags", systemImage: "tag") }.menuStyle(.borderlessButton).fixedSize()
                }
            }
        }
        if all.isEmpty {
            Card {
                VStack(spacing: 14) {
                    EmptyState(icon: "link", title: "Everything this project links to",
                               message: "Hosting, payments, domains, Instagram and Facebook pages, the GitHub repo, the live site, design files, and useful AI chats. Each gets its real logo.", compact: true)
                    HStack(spacing: 8) {
                        ForEach(EntryKind.linkKinds) { kind in
                            Button { present(.entry(Entry(projectID: project.id, kind: kind))) } label: { Label(kind.shortName, systemImage: kind.icon) }.buttonStyle(.softCompact)
                        }
                    }.padding(.bottom, 14)
                }
            }
        } else if shown.isEmpty {
            Card { EmptyState(icon: "line.3.horizontal.decrease", title: "No matches", message: "Try another filter.", compact: true) }
        } else if filter == nil && query.isEmpty && tag == nil {
            ForEach(EntryKind.linkKinds) { kind in
                let group = shown.filter { $0.kind == kind }
                if !group.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 7) {
                            Image(systemName: kind.icon).font(.system(size: 11, weight: .semibold))
                            Text(kind.groupName.uppercased()).tracking(1.1)
                            Text("\(group.count)").foregroundStyle(Theme.ink3)
                        }.font(T.label).foregroundStyle(Theme.ink2).padding(.leading, 4)
                        Card(padding: 6) { VStack(spacing: 0) { ForEach(group) { LinkRow(entry: $0) } } }
                    }
                }
            }
        } else {
            Card(padding: 6) { VStack(spacing: 0) { ForEach(shown) { LinkRow(entry: $0) } } }
        }
    }
}

struct AddLinkMenu: View {
    @Environment(\.present) var present
    let projectID: UUID
    var body: some View {
        Menu {
            ForEach(EntryKind.linkKinds) { kind in
                Button { present(.entry(Entry(projectID: projectID, kind: kind))) } label: { Label(kind.rawValue, systemImage: kind.icon) }
            }
        } label: { MenuLabel(title: "Add link", icon: "plus", primary: true) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// A saved link as a list row. Clicking it opens the link in your default browser.
struct LinkRow: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    let entry: Entry
    var showProject = false
    @State private var hovering = false
    @State private var copied = false
    @State private var confirmDelete = false

    var url: URL? { webURL(entry.url) }
    var subtitle: String {
        var parts: [String] = []
        if showProject, let project = store.project(entry.projectID) { parts.append(project.name) }
        if let host = BrandCatalog.host(of: entry.url) { parts.append(host) }
        if !entry.category.isEmpty && BrandCatalog.brand(for: entry)?.name.lowercased() != entry.category.lowercased() { parts.append(entry.category) }
        if !entry.account.isEmpty { parts.append(entry.account) }
        if parts.isEmpty {
            let text = Markdown.plain(entry.body, limit: 100)
            return text.isEmpty ? entry.kind.rawValue : text
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 13) {
            EntryIcon(entry: entry, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title.isEmpty ? "Untitled" : entry.title).font(T.bodyMedium).foregroundStyle(Theme.ink).lineLimit(1)
                    if entry.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.ink3).help("Pinned") }
                    if !entry.credentials.isEmpty { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.ink3).help("\(entry.credentials.count) password(s) in Keychain") }
                }
                Text(subtitle).font(T.small).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !entry.environment.isEmpty { Pill(text: entry.environment, color: environmentColor) }
            ForEach(entry.tags.prefix(2), id: \.self) { Pill(text: $0) }
            HStack(spacing: 2) {
                if let manage = webURL(entry.managementURL) {
                    IconButton(icon: "slider.horizontal.3", help: "Open management page") { NSWorkspace.shared.open(manage) }
                }
                if let folder = store.folder(entry.folderID) {
                    IconButton(icon: "folder", help: "Open local folder in Finder") {
                        do { NSWorkspace.shared.open(try store.resolve(folder)) } catch { store.error = error.localizedDescription }
                    }
                }
                if let url {
                    IconButton(icon: copied ? "checkmark" : "doc.on.doc", help: "Copy link") {
                        copyToClipboard(url.absoluteString); copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                    }
                }
                IconButton(icon: "pencil", help: "Edit details, notes, and passwords") { present(.entry(entry)) }
            }
            .opacity(hovering ? 1 : 0)
            Image(systemName: url == nil ? "chevron.right" : "arrow.up.right").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Theme.ink : Theme.ink3).frame(width: 16)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if url != nil { store.open(entry) } else { present(.entry(entry)) } }
        .help(url.map { "Open \($0.host() ?? "") in your browser" } ?? "Edit")
        .contextMenu {
            if let url {
                Button("Open") { store.open(entry) }
                OpenInBrowserMenu(url: url)
                Button("Copy Link") { copyToClipboard(url.absoluteString) }
            }
            Button("Edit…") { present(.entry(entry)) }
            Button(entry.pinned ? "Unpin" : "Pin to Front") { store.togglePin(entry) }
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Delete “\(entry.title)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.deleteEntry(entry.id) }
        } message: {
            Text(entry.credentials.isEmpty ? "This removes the link from Context." : "This also deletes \(entry.credentials.count) saved password(s) from the Keychain.")
        }
    }

    var environmentColor: Color {
        switch entry.environment {
        case "Production": return Theme.success
        case "Staging": return Theme.today
        case "Development": return Theme.upcoming
        default: return Theme.ink2
        }
    }
}
