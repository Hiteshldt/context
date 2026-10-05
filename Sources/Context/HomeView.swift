import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    @Environment(\.navigate) var navigate
    let openLauncher: () -> Void

    var tasks: [WorkTask] { store.workspace.tasks }
    var now: Date { store.clock }

    /// Replaces the Mac account name in the greeting; the snapshot script sets a demo name.
    static var greetingName: String?

    var greeting: String {
        let hour = Calendar.current.component(.hour, from: now)
        let part = hour < 5 ? "Working late" : hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        var first = Self.greetingName ?? NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        // Account names are sometimes all capitals; show them the way a person would write them.
        if first == first.uppercased() { first = first.capitalized }
        return first.isEmpty ? "\(part)." : "\(part), \(first)."
    }

    var summary: String {
        let overdue = Buckets.overdue(tasks, now: now).count
        let today = Buckets.today(tasks, now: now).count
        if overdue + today > 0 {
            var parts: [String] = []
            if today > 0 { parts.append(today == 1 ? "1 thing due today" : "\(today) things due today") }
            if overdue > 0 { parts.append("\(overdue) overdue") }
            return parts.joined(separator: " · ")
        }
        if let last = store.workspace.projects.filter({ $0.lastOpenedAt != nil }).max(by: { $0.lastOpenedAt! < $1.lastOpenedAt! }), let date = last.lastOpenedAt {
            return "You were last in \(last.name) \(DueText.ago(date, now: now)). Everything is where you left it."
        }
        return "Everything is where you left it."
    }

    var body: some View {
        Page(maxWidth: 1180, spacing: 30) {
            if store.workspace.projects.isEmpty {
                WelcomeView()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: now.formatted(.dateTime.weekday(.wide).month(.wide).day()), color: Theme.accent)
                    Text(greeting).font(T.display(36)).foregroundStyle(Theme.ink)
                    Text(summary).font(.system(size: 15.5)).foregroundStyle(Theme.ink2)
                }
                launcherBar
                projects
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        recentNotes.frame(minWidth: 420)
                        today.frame(width: 360)
                    }
                    VStack(alignment: .leading, spacing: 30) { recentNotes; today }
                }
            }
        }
    }

    var launcherBar: some View {
        Button(action: openLauncher) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.accent)
                Text("Open a link, find a note, jump to a project…").font(.system(size: 15.5)).foregroundStyle(Theme.ink2)
                Spacer()
                KeyHint(keys: "⌘K")
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverLift()
        .help("Type a few letters of any link, note, or project and press Return")
    }

    var projects: some View {
        let sorted = store.workspace.projects.sorted { a, b in
            if (a.status == .done) != (b.status == .done) { return b.status == .done }
            return (a.lastOpenedAt ?? a.updatedAt) > (b.lastOpenedAt ?? b.updatedAt)
        }
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Jump back in") {
                Button { present(.project(Project(name: ""))) } label: { Label("New project", systemImage: "plus") }.buttonStyle(.softCompact)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 18, alignment: .top)], spacing: 18) {
                ForEach(sorted) { ProjectTile(project: $0) }
            }
        }
    }

    var recentNotes: some View {
        let notes = store.workspace.entries.filter { $0.kind == .note || $0.kind == .prompt }.sorted { $0.updatedAt > $1.updatedAt }.prefix(6)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Recent notes", icon: "note.text", tint: Theme.accent)
            if notes.isEmpty {
                Card { EmptyState(icon: "note.text", title: "", message: "Notes you write in a project show up here, newest first.", compact: true) }
            } else {
                Card(padding: 6) {
                    VStack(spacing: 0) {
                        ForEach(Array(notes)) { note in NoteSummaryRow(note: note, showProject: true) }
                    }
                }
            }
        }
    }

    var pendingPosts: [ContentItem] {
        let horizon = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        return store.workspace.contentItems.filter { !$0.isComplete && !$0.targets.isEmpty && ($0.due ?? .distantPast) <= horizon }
            .sorted { ($0.due ?? .distantPast) < ($1.due ?? .distantPast) }
    }

    var today: some View {
        let due = Buckets.needsAttention(tasks, now: now)
        let upcoming = Buckets.upcoming(tasks, now: now)
        let undated = tasks.filter { !$0.isComplete && $0.due == nil && !$0.isSnoozed(at: now) }
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Today", count: due.count, icon: "sun.max.fill", tint: Theme.today)
            QuickCapture()
            if !due.isEmpty {
                TaskListCard(tasks: due, showProject: true, limit: 8, empty: EmptyState(icon: "checkmark", title: "", message: ""))
            } else if upcoming.isEmpty && undated.isEmpty && pendingPosts.isEmpty {
                Text("Nothing due. Tasks you add with a date appear here when it's time, even if a reminder was missed.")
                    .font(T.small).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
            if !upcoming.isEmpty {
                Eyebrow(text: "Coming up").padding(.top, 6)
                TaskListCard(tasks: upcoming, showProject: true, limit: 5, empty: EmptyState(icon: "calendar", title: "", message: ""))
            }
            if !undated.isEmpty {
                Eyebrow(text: "No date").padding(.top, 6)
                TaskListCard(tasks: undated, showProject: true, limit: 5, empty: EmptyState(icon: "tray", title: "", message: ""))
            }
            if !pendingPosts.isEmpty {
                Eyebrow(text: "Posts to publish").padding(.top, 6)
                Card(padding: 12) { VStack(alignment: .leading, spacing: 12) { ForEach(pendingPosts.prefix(5)) { PostSummaryRow(item: $0) } } }
            }
        }
    }
}

/// A project on Home: where you left it, plus one-click access to its most-used links.
struct ProjectTile: View {
    @EnvironmentObject var store: Store
    @Environment(\.navigate) var navigate
    let project: Project

    var links: [Entry] {
        store.workspace.entries.filter { $0.projectID == project.id && EntryKind.linkKinds.contains($0.kind) && webURL($0.url) != nil }
            .sorted { a, b in (a.pinned ? 1 : 0, a.openCount, a.lastOpenedAt ?? .distantPast) > (b.pinned ? 1 : 0, b.openCount, b.lastOpenedAt ?? .distantPast) }
    }

    var body: some View {
        let tint = Theme.color(project.color)
        let entries = store.workspace.entries.filter { $0.projectID == project.id }
        let notes = entries.filter { $0.kind == .note || $0.kind == .prompt }.count
        let folders = store.workspace.folders.filter { $0.projectID == project.id }.count
        let tasks = store.workspace.tasks.filter { $0.projectID == project.id }
        let attention = Buckets.needsAttention(tasks, now: store.clock).count
        let top = Array(links.prefix(6))

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 13) {
                ProjectIcon(project: project, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name).font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(subtitle).font(T.small).foregroundStyle(Theme.ink2).lineLimit(1)
                }
                Spacer(minLength: 6)
                if attention > 0 { Pill(text: "\(attention) due", icon: "exclamationmark.circle.fill", color: Theme.overdue) }
                else if project.status != .active { Pill(text: project.status.rawValue, color: Theme.status(project.status)) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))

            if !project.summary.isEmpty {
                Text(project.summary).font(T.small).foregroundStyle(Theme.ink2).lineLimit(2)
                    .padding(.horizontal, 16).padding(.top, 12)
            }

            HStack(spacing: 9) {
                if top.isEmpty {
                    Text("Add links to open them from here").font(T.small).foregroundStyle(Theme.ink3)
                }
                ForEach(top) { entry in
                    Button { store.open(entry) } label: { EntryIcon(entry: entry, size: 34) }
                        .buttonStyle(.plain).hoverLift().help("Open \(entry.title)")
                }
                if links.count > top.count {
                    Text("+\(links.count - top.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink2)
                        .frame(width: 34, height: 34).background(Theme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                Spacer(minLength: 0)
            }
            .frame(height: 36)
            .padding(.horizontal, 16).padding(.vertical, 13)

            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 12) {
                Label("\(links.count)", systemImage: "link").help("\(links.count) links")
                Label("\(notes)", systemImage: "note.text").help("\(notes) notes")
                if folders > 0 { Label("\(folders)", systemImage: "folder").help("\(folders) folders") }
                Spacer()
                HStack(spacing: 3) { Text("Open"); Image(systemName: "arrow.right") }.foregroundStyle(tint).fontWeight(.semibold)
            }
            .font(T.caption).foregroundStyle(Theme.ink2).lineLimit(1)
            .padding(.horizontal, 16).padding(.vertical, 11)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
        .contentShape(Rectangle())
        .onTapGesture { navigate(.project(project.id)) }
        .hoverLift()
    }

    var subtitle: String {
        var parts: [String] = []
        if let client = store.clientName(for: project) { parts.append(client) }
        if let opened = project.lastOpenedAt { parts.append("Opened \(DueText.ago(opened, now: store.clock))") }
        else { parts.append("Updated \(DueText.ago(project.updatedAt, now: store.clock))") }
        return parts.joined(separator: " · ")
    }
}

/// A note in a list: title, a line of its content, and when it changed.
struct NoteSummaryRow: View {
    @EnvironmentObject var store: Store
    @Environment(\.navigate) var navigate
    let note: Entry
    var showProject = false

    var body: some View {
        let project = store.project(note.projectID)
        let tint = Theme.color(project?.color ?? "sage")
        Button {
            store.selectedNote[note.projectID] = note.id
            store.lastSection[note.projectID] = .notes
            navigate(.project(note.projectID))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: note.kind.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 34, height: 34).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title.isEmpty ? "Untitled" : note.title).font(T.bodyMedium).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(Markdown.plain(note.body, limit: 120).ifEmpty("Empty")).font(T.small).foregroundStyle(Theme.ink2).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if showProject, let project { Text(project.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(tint).lineLimit(1) }
                    Text(DueText.ago(note.updatedAt, now: store.clock)).font(T.caption).foregroundStyle(Theme.ink3)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .hoverRow()
        }
        .buttonStyle(.plain)
    }
}

struct PostSummaryRow: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    let item: ContentItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.title.isEmpty ? "Untitled post" : item.title).font(T.bodyMedium).lineLimit(1)
                Spacer()
                if let due = item.due {
                    let label = DueText.describe(due, now: store.clock)
                    Text(label.text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(label.color).lineLimit(1)
                }
            }
            HStack(spacing: 5) {
                if let project = store.project(item.projectID) {
                    Circle().fill(Theme.color(project.color)).frame(width: 6, height: 6)
                    Text(project.name).font(T.caption).foregroundStyle(Theme.ink2).lineLimit(1)
                }
                Spacer()
                ForEach(item.targets) { target in
                    Button { store.togglePlatform(item, target: target.id) } label: {
                        PlatformIcon(platform: target.platform, size: 20)
                            .saturation(target.isDone ? 1 : 0).opacity(target.isDone ? 1 : 0.45)
                            .overlay(alignment: .bottomTrailing) {
                                if target.isDone {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.white, Theme.success)
                                        .background(Circle().fill(Theme.card)).offset(x: 4, y: 4)
                                }
                            }
                    }.buttonStyle(.plain).help("\(target.platform): \(target.isDone ? "posted — click to undo" : "not posted yet — click when done")")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { present(.content(item)) }
    }
}

struct WelcomeView: View {
    @Environment(\.present) var present
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: "Welcome", color: Theme.accent)
                Text("Remember the context\naround your work.").font(T.display(38)).foregroundStyle(Theme.ink)
                Text("Reopen a project after weeks away and know exactly where things live and what comes next.")
                    .font(.system(size: 16)).foregroundStyle(Theme.ink2)
            }
            HStack(alignment: .top, spacing: 16) {
                step("link", "Every link in one place", "Dashboards, repos, social accounts, and docs, each with its real logo. Open any of them with ⌘K.")
                step("note.text", "Notes that read well", "Paste or write Markdown: tables, code, and checklists render properly, with an outline for long documents.")
                step("icloud", "Backed up for you", "Point Context at a Google Drive, iCloud, or OneDrive folder and it keeps a dated copy there automatically.")
            }
            Card {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Start with one thing you're working on").font(T.h2).foregroundStyle(Theme.ink)
                        Text("A brand, a product, a client, or a small idea.").font(T.body).foregroundStyle(Theme.ink2)
                    }
                    Spacer()
                    Button("New Client…") { present(.client(Client(name: ""))) }.buttonStyle(.soft)
                    Button("Create a Project") { present(.project(Project(name: ""))) }.buttonStyle(.primary)
                }
            }
        }
    }
    func step(_ icon: String, _ title: String, _ text: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40).background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(title).font(T.h3).foregroundStyle(Theme.ink)
                Text(text).font(T.small).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        }
    }
}
