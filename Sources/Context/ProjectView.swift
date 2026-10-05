import SwiftUI
import UniformTypeIdentifiers

struct ProjectView: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    @Environment(\.navigate) var navigate
    let project: Project
    /// When this project was last opened before now, captured on arrival.
    @State private var previousVisit: Date?

    var tint: Color { Theme.color(project.color) }
    var section: ProjectSection {
        let stored = store.lastSection[project.id] ?? .overview
        return project.shows(stored) ? stored : .overview
    }
    func select(_ section: ProjectSection) { store.lastSection[project.id] = section }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                switch section {
                case .overview: Page { ProjectOverview(project: project, previousVisit: previousVisit) }
                case .tasks: Page(maxWidth: 900) { ProjectTasks(project: project) }
                case .links: LinksSection(project: project)
                case .map: DiagramSection(project: project)
                case .files: FilesSection(project: project)
                case .notes: NotesSection(project: project)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            previousVisit = project.lastOpenedAt
            store.markOpened(project.id)
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                ProjectIcon(project: project, size: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(T.display(30)).foregroundStyle(Theme.ink).lineLimit(1)
                    HStack(spacing: 10) {
                        HStack(spacing: 5) {
                            Circle().fill(Theme.status(project.status)).frame(width: 7, height: 7)
                            Text(project.status.rawValue)
                        }
                        if let client = store.client(project.clientID) {
                            Button { navigate(.client(client.id)) } label: { Label(client.name, systemImage: "building.2") }
                                .buttonStyle(.plain).help("Open client overview")
                        }
                        if !project.summary.isEmpty { Text("·"); Text(project.summary).lineLimit(1) }
                    }
                    .font(T.small).foregroundStyle(Theme.ink2)
                }
                Spacer(minLength: 16)
                IconButton(icon: "slider.horizontal.3", help: "Project settings", size: 32) { present(.project(project)) }
                AddMenu(project: project)
            }
            tabs
        }
        .padding(.horizontal, 40).padding(.top, 36)
        .background(alignment: .top) {
            LinearGradient(colors: [tint.opacity(0.14), tint.opacity(0.0)], startPoint: .top, endPoint: .bottom)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    var tabs: some View {
        HStack(spacing: 26) {
            ForEach(project.visibleSections) { config in
                let selected = section == config.section
                Button { select(config.section) } label: {
                    VStack(spacing: 9) {
                        HStack(spacing: 6) {
                            Text(config.displayName).font(.system(size: 14, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                            if let count = badge(config.section), count > 0 {
                                Text("\(count)").font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(selected ? tint : Theme.ink3)
                            }
                        }
                        RoundedRectangle(cornerRadius: 1.5).fill(selected ? tint : .clear).frame(height: 3)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Spacer()
        }
    }

    func badge(_ section: ProjectSection) -> Int? {
        let entries = store.workspace.entries.filter { $0.projectID == project.id }
        switch section {
        case .tasks:
            return store.workspace.tasks.filter { $0.projectID == project.id && !$0.isComplete }.count
                + store.workspace.contentItems.filter { $0.projectID == project.id && !$0.isComplete && !$0.targets.isEmpty }.count
        case .links: return entries.filter { EntryKind.linkKinds.contains($0.kind) }.count
        case .notes: return entries.filter { EntryKind.noteKinds.contains($0.kind) }.count
        case .files: return store.workspace.folders.filter { $0.projectID == project.id }.count
        case .overview, .map: return nil
        }
    }
}

struct AddMenu: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    let project: Project
    var body: some View {
        Menu {
            Button { NotificationCenter.default.post(name: .contextNewNote, object: nil) } label: { Label("Note", systemImage: "note.text") }
            Button { present(.entry(Entry(projectID: project.id, kind: .prompt))) } label: { Label("Prompt", systemImage: "text.bubble") }
            Divider()
            Section("Links") {
                ForEach(EntryKind.linkKinds) { kind in
                    Button { present(.entry(Entry(projectID: project.id, kind: kind))) } label: { Label(kind.rawValue, systemImage: kind.icon) }
                }
            }
            Divider()
            Button { present(.task(WorkTask(projectID: project.id))) } label: { Label("Task", systemImage: "checkmark.circle") }
            Button { present(.content(ContentItem(projectID: project.id))) } label: { Label("Planned Post", systemImage: "paperplane") }
            Button { store.connectFolder(projectID: project.id) } label: { Label("Connect Folder…", systemImage: "folder.badge.plus") }
        } label: { MenuLabel(title: "Add", icon: "plus", primary: true) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

// MARK: - Overview

struct ProjectOverview: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    @Environment(\.pageTint) var tint
    let project: Project
    let previousVisit: Date?

    var entries: [Entry] { store.workspace.entries.filter { $0.projectID == project.id } }
    var links: [Entry] {
        entries.filter { EntryKind.linkKinds.contains($0.kind) }
            .sorted { a, b in (a.pinned ? 1 : 0, a.openCount, a.updatedAt) > (b.pinned ? 1 : 0, b.openCount, b.updatedAt) }
    }

    var body: some View {
        if let previousVisit, Calendar.current.dateComponents([.day], from: previousVisit, to: store.clock).day ?? 0 >= 7 {
            HStack(spacing: 10) {
                Image(systemName: "hand.wave.fill").foregroundStyle(tint)
                Text("Welcome back. You were last here \(DueText.ago(previousVisit, now: store.clock)) — this page is everything you need to pick it up again.")
                    .font(T.body).foregroundStyle(Theme.ink)
                Spacer()
            }
            .padding(14).background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        ContextNoteCard(project: project)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 26) {
                quickLinks.frame(minWidth: 420)
                VStack(alignment: .leading, spacing: 26) { recentNotes; folders }.frame(width: 380)
            }
            VStack(alignment: .leading, spacing: 26) { quickLinks; recentNotes; folders }
        }
        nextSteps
    }

    var quickLinks: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Quick links", count: links.count) {
                Button("All links") { store.lastSection[project.id] = .links }.buttonStyle(.softCompact)
            }
            Card(padding: 14) {
                if links.isEmpty {
                    EmptyState(icon: "link", title: "No links yet", message: "Add the dashboards, repos, and accounts this project uses. They open with one click.", compact: true,
                               actionTitle: "Add a Link") { present(.entry(Entry(projectID: project.id, kind: .link))) }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8, alignment: .top)], spacing: 10) {
                        ForEach(links.prefix(15)) { entry in LinkTile(entry: entry) }
                    }
                }
            }
        }
    }

    var recentNotes: some View {
        let notes = entries.filter { EntryKind.noteKinds.contains($0.kind) }.sorted { $0.updatedAt > $1.updatedAt }
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Notes", count: notes.count) {
                Button { NotificationCenter.default.post(name: .contextNewNote, object: nil) } label: { Label("New", systemImage: "plus") }.buttonStyle(.softCompact)
            }
            Card(padding: 6) {
                if notes.isEmpty {
                    EmptyState(icon: "note.text", title: "", message: "Write down decisions, steps, and details you'll want later.", compact: true)
                } else {
                    VStack(spacing: 0) { ForEach(notes.prefix(4)) { NoteSummaryRow(note: $0) } }
                }
            }
        }
    }

    @ViewBuilder var folders: some View {
        let folders = store.workspace.folders.filter { $0.projectID == project.id }
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Folders", count: folders.count) {
                Button { store.connectFolder(projectID: project.id) } label: { Label("Connect", systemImage: "plus") }.buttonStyle(.softCompact)
            }
            Card(padding: 6) {
                if folders.isEmpty {
                    EmptyState(icon: "folder", title: "", message: "Connect the folder with this project's working files.", compact: true)
                } else {
                    VStack(spacing: 0) { ForEach(folders) { FolderPointRow(folder: $0) } }
                }
            }
        }
    }

    @ViewBuilder var nextSteps: some View {
        let pending = store.workspace.tasks.filter { $0.projectID == project.id && !$0.isComplete && !$0.isSnoozed(at: store.clock) }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Next steps", count: pending.count)
            QuickCapture(fixedProject: project.id, placeholder: "What's the next step? Press Return to add it")
            if !pending.isEmpty {
                TaskListCard(tasks: pending, limit: 6, empty: EmptyState(icon: "checkmark", title: "", message: ""))
            }
        }
    }
}

/// A link as a tile: its logo and name. One click opens it.
struct LinkTile: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    let entry: Entry
    @State private var hovering = false
    var body: some View {
        Button {
            if webURL(entry.url) != nil { store.open(entry) } else { present(.entry(entry)) }
        } label: {
            VStack(spacing: 7) {
                EntryIcon(entry: entry, size: 44)
                Text(entry.title.isEmpty ? "Untitled" : entry.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
            .padding(.vertical, 10).padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .top)
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(entry.url.isEmpty ? entry.title : "Open \(entry.url)")
        .contextMenu {
            Button("Edit…") { present(.entry(entry)) }
            if let url = webURL(entry.url) { Button("Copy Link") { copyToClipboard(url.absoluteString) } }
            Button(entry.pinned ? "Unpin" : "Pin to Front") { store.togglePin(entry) }
        }
    }
}

/// An always-visible note answering "where does this stand?" — the first thing to read after time away.
struct ContextNoteCard: View {
    @EnvironmentObject var store: Store
    @Environment(\.pageTint) var tint
    let project: Project
    @State private var editing = false
    @State private var draft = ""
    @State private var saveTask: Task<Void, Never>?
    @StateObject private var controller = EditorController()

    var isEmpty: Bool { project.contextNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Where things stand", systemImage: "bookmark.fill").font(T.h3).foregroundStyle(tint)
                Spacer()
                if editing {
                    Text("Saves as you type").font(T.caption).foregroundStyle(Theme.ink3)
                    Button("Done") { commit(); editing = false }.buttonStyle(.primaryCompact).keyboardShortcut(.return, modifiers: .command)
                } else if !isEmpty {
                    Button { draft = project.contextNote; editing = true } label: { Label("Edit", systemImage: "pencil") }.buttonStyle(.softCompact)
                }
            }
            if editing {
                MarkdownEditor(text: $draft, controller: controller, size: 14.5, tint: tint)
                    .frame(minHeight: 170)
                    .padding(.horizontal, 10)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
                    .onChange(of: draft) { _, _ in scheduleSave() }
                    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { controller.focus() } }
            } else if isEmpty {
                Button { draft = ""; editing = true } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Write a few lines for your future self.").font(T.bodyMedium).foregroundStyle(Theme.ink)
                        Text("What's the current state? What were you about to do next? Where is the live version?")
                            .font(T.small).foregroundStyle(Theme.ink2)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            } else {
                MarkdownDocumentView(blocks: Markdown.parse(project.contextNote), baseSize: 14.5) { line in
                    guard var current = store.project(project.id) else { return }
                    current.contextNote = Markdown.toggleCheck(in: current.contextNote, line: line)
                    store.save(current)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.25)))
        .onDisappear { if editing { commit() } }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    func commit() {
        saveTask?.cancel()
        guard var current = store.project(project.id), current.contextNote != draft else { return }
        current.contextNote = draft
        store.save(current)
    }
}

struct FolderPointRow: View {
    @EnvironmentObject var store: Store
    let folder: FolderConnection
    @State private var status: FolderStatus?
    var available: Bool { if case .unavailable = status { return false }; return true }
    var body: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().frame(width: 30, height: 30).opacity(available ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name).font(T.bodyMedium).foregroundStyle(Theme.ink).lineLimit(1)
                Text(available ? (folder.purpose.isEmpty ? "Folder" : folder.purpose) : "Unavailable — reconnect").font(T.caption)
                    .foregroundStyle(available ? Theme.ink2 : Theme.overdue).lineLimit(1)
            }
            Spacer(minLength: 4)
            if available {
                IconButton(icon: "arrow.up.forward.square", help: "Open in Finder") {
                    do { NSWorkspace.shared.open(try store.resolve(folder)) } catch { store.error = error.localizedDescription }
                }
            } else {
                Button("Reconnect") { store.connectFolder(projectID: folder.projectID, replacing: folder.id) }.buttonStyle(.softCompact)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .hoverRow()
        .onTapGesture { store.lastSection[folder.projectID] = .files; store.selectedFolder[folder.projectID] = folder.id }
        .task(id: folder.bookmark) { status = store.status(of: folder) }
    }
}

// MARK: - Tasks

struct ProjectTasks: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    let project: Project
    @State private var showCompleted = false
    @State private var mode = 0

    var body: some View {
        let posts = store.workspace.contentItems.filter { $0.projectID == project.id && !$0.isComplete }.count
        let open = store.workspace.tasks.filter { $0.projectID == project.id && !$0.isComplete }.count
        HStack {
            Segmented(options: [(0, "To do\(open > 0 ? "  \(open)" : "")", "checkmark.circle"), (1, "Posts\(posts > 0 ? "  \(posts)" : "")", "paperplane")], selection: $mode)
            Spacer()
            if mode == 0 {
                Button { present(.task(WorkTask(projectID: project.id))) } label: { Label("New Task", systemImage: "plus") }.buttonStyle(.primary)
            }
        }
        if mode == 1 { PostsPanel(project: project) } else { taskList }
    }

    @ViewBuilder var taskList: some View {
        let now = store.clock
        let tasks = store.workspace.tasks.filter { $0.projectID == project.id }
        let overdue = Buckets.overdue(tasks, now: now)
        let today = Buckets.today(tasks, now: now)
        let upcoming = tasks.filter { !$0.isComplete && !$0.isSnoozed(at: now) && ($0.due.map { $0 >= Buckets.endOfToday(now) } ?? false) }.sorted { $0.due! < $1.due! }
        let undated = tasks.filter { !$0.isComplete && !$0.isSnoozed(at: now) && $0.due == nil }
        let snoozed = Buckets.snoozed(tasks, now: now)
        let done = tasks.filter(\.isComplete).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }

        QuickCapture(fixedProject: project.id)
        if overdue.isEmpty && today.isEmpty && upcoming.isEmpty && undated.isEmpty && snoozed.isEmpty {
            Card { EmptyState(icon: "checkmark.seal", title: "Nothing to do", message: "Type a task above and press Return. Add a date, a repeat, or a reminder by clicking the task.") }
        }
        group("Overdue", overdue, Theme.overdue)
        group("Today", today, Theme.today)
        group("Upcoming", upcoming, Theme.upcoming)
        group("No date", undated, Theme.ink2)
        group("Snoozed", snoozed, Theme.ink2)
        if !done.isEmpty {
            DisclosureGroup(isExpanded: $showCompleted) {
                TaskListCard(tasks: done, limit: 50, empty: EmptyState(icon: "checkmark", title: "", message: "")).padding(.top, 8)
            } label: {
                Text("Completed  \(done.count)").font(T.bodyMedium).foregroundStyle(Theme.ink2)
            }
        }
    }

    @ViewBuilder func group(_ title: String, _ tasks: [WorkTask], _ tint: Color) -> some View {
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: title, color: tint)
                TaskListCard(tasks: tasks, empty: EmptyState(icon: "checkmark", title: "", message: ""))
            }
        }
    }
}
