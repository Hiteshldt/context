import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    @ObservedObject private var reminders = RemindersService.shared
    let openLauncher: () -> Void

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

    /// Open reminders due within the week (including anything overdue), across all projects.
    var dueSoon: [(ReminderItem, Project)] {
        let horizon = Calendar.current.date(byAdding: .day, value: 8, to: Calendar.current.startOfDay(for: now))!
        return store.workspace.projects.flatMap { project in
            reminders.items(for: project).filter { !$0.isCompleted && ($0.due ?? .distantFuture) < horizon }.map { ($0, project) }
        }.sorted { ReminderItem.order($0.0, $1.0) }
    }

    var summary: String {
        let attention = dueSoon.filter { $0.0.needsAttention(now: now) }.count
        if attention > 0 { return attention == 1 ? "1 reminder is due." : "\(attention) reminders are due." }
        if let last = store.workspace.projects.filter({ $0.lastOpenedAt != nil }).max(by: { $0.lastOpenedAt! < $1.lastOpenedAt! }), let date = last.lastOpenedAt {
            return "You were last in \(last.name) \(DueText.ago(date, now: now))."
        }
        return "Everything is where you left it."
    }

    var body: some View {
        Page(maxWidth: 1120, spacing: 28) {
            if store.workspace.projects.isEmpty {
                WelcomeView()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: now.formatted(.dateTime.weekday(.wide).month(.wide).day()), color: Theme.accent)
                    Text(greeting).font(T.display(34)).foregroundStyle(Theme.ink)
                    Text(summary).font(.system(size: 15)).foregroundStyle(Theme.ink2)
                }
                launcherBar
                projects
            }
        }
    }

    var launcherBar: some View {
        Button(action: openLauncher) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.accent)
                Text("Open a link or jump to a project…").font(.system(size: 15)).foregroundStyle(Theme.ink2)
                Spacer()
                KeyHint(keys: "⌘K")
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverLift()
        .help("Type a few letters of any link or project and press Return")
    }

    var projects: some View {
        let sorted = store.workspace.projects.sorted { a, b in
            if (a.status == .done) != (b.status == .done) { return b.status == .done }
            return (a.lastOpenedAt ?? a.updatedAt) > (b.lastOpenedAt ?? b.updatedAt)
        }
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Projects") {
                Button { present(.project(Project(name: ""))) } label: { Label("New project", systemImage: "plus") }.buttonStyle(.softCompact)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 16) {
                ForEach(sorted) { ProjectTile(project: $0) }
            }
        }
    }
}

/// A project on Home: its picture, what it is, and one-click logos for its most-used links.
struct ProjectTile: View {
    @EnvironmentObject var store: Store
    @Environment(\.navigate) var navigate
    @ObservedObject private var reminders = RemindersService.shared
    let project: Project

    var links: [Entry] {
        store.workspace.entries.filter { $0.projectID == project.id && EntryKind.linkKinds.contains($0.kind) && webURL($0.url) != nil }
            .sorted { a, b in (a.pinned ? 1 : 0, a.openCount, a.lastOpenedAt ?? .distantPast) > (b.pinned ? 1 : 0, b.openCount, b.lastOpenedAt ?? .distantPast) }
    }

    var body: some View {
        let tint = Theme.color(project.color)
        let attention = reminders.attentionCount(for: project, now: store.clock)
        let top = Array(links.prefix(links.count > 6 ? 5 : 6))

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 13) {
                ProjectIcon(project: project, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(project.summary.ifEmpty(opened)).font(T.small).foregroundStyle(Theme.ink2).lineLimit(1)
                }
                Spacer(minLength: 6)
                if attention > 0 { Pill(text: "\(attention) due", icon: "exclamationmark.circle.fill", color: Theme.overdue) }
                else if project.status != .active { Pill(text: project.status.rawValue, color: Theme.status(project.status)) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [tint.opacity(0.15), tint.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing))

            HStack(spacing: 8) {
                if top.isEmpty { Text("No links yet").font(T.small).foregroundStyle(Theme.ink3) }
                ForEach(top) { entry in
                    Button { store.open(entry) } label: { EntryIcon(entry: entry, size: 32) }
                        .buttonStyle(.plain).hoverLift().help("Open \(entry.title)")
                }
                if links.count > top.count {
                    Text("+\(links.count - top.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink2)
                        .frame(width: 32, height: 32).background(Theme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                Spacer(minLength: 0)
            }
            .frame(height: 34)
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
        .contentShape(Rectangle())
        .onTapGesture { navigate(.project(project.id)) }
        .hoverLift()
    }

    var opened: String {
        if let opened = project.lastOpenedAt { return "Opened \(DueText.ago(opened, now: store.clock))" }
        return "Updated \(DueText.ago(project.updatedAt, now: store.clock))"
    }
}

struct WelcomeView: View {
    @Environment(\.present) var present
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: "Welcome", color: Theme.accent)
                Text("Every project,\nat a glance.").font(T.display(38)).foregroundStyle(Theme.ink)
                Text("Map how each project fits together, keep its links one click away, and never miss what's next.")
                    .font(.system(size: 16)).foregroundStyle(Theme.ink2)
            }
            HStack(alignment: .top, spacing: 16) {
                step("point.3.connected.trianglepath.dotted", "Map", "Draw the people, apps, and services behind a project, group them, and keep notes on each box.")
                step("link", "Links", "Dashboards, repos, social accounts, and docs, each with its real logo. Open any of them with ⌘K.")
                step("bell", "Reminders", "Set them on any box on the map. They're kept in Apple Reminders, so they reach your iPhone too.")
            }
            Card {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Start with one thing you're working on").font(T.h2).foregroundStyle(Theme.ink)
                        Text("A brand, a product, a client, or a small idea.").font(T.body).foregroundStyle(Theme.ink2)
                    }
                    Spacer()
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
