import SwiftUI

// MARK: - Tasks

struct TasksView: View {
    @EnvironmentObject var store: Store
    @State private var filter = 0
    @State private var projectFilter: UUID?

    var scoped: [WorkTask] { store.workspace.tasks.filter { projectFilter == nil || $0.projectID == projectFilter } }

    var body: some View {
        let now = store.clock
        Page(maxWidth: 900, spacing: 22) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "Across every project", color: Theme.accent)
                    Text("Tasks").font(T.display(34)).foregroundStyle(Theme.ink)
                }
                Spacer()
                if store.workspace.projects.count > 1 {
                    Menu {
                        Button("All projects") { projectFilter = nil }
                        Divider()
                        ForEach(store.workspace.projects) { p in Button(p.name) { projectFilter = p.id } }
                    } label: { MenuLabel(title: projectFilter.flatMap { store.project($0)?.name } ?? "All projects", icon: "line.3.horizontal.decrease") }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                }
            }
            if store.workspace.projects.isEmpty {
                Card { EmptyState(icon: "square.stack", title: "Create a project first", message: "Tasks belong to a project.") }
            } else {
                QuickCapture(fixedProject: projectFilter)
                Segmented(options: [(0, "To do", nil), (1, "Snoozed", nil), (2, "Done", nil)], selection: $filter)
                switch filter {
                case 1:
                    TaskListCard(tasks: Buckets.snoozed(scoped, now: now), showProject: true,
                                 empty: EmptyState(icon: "moon.zzz", title: "Nothing snoozed", message: "Snoozing hides a task until the time you pick. Its schedule stays the same.", compact: true))
                case 2:
                    let done = scoped.filter(\.isComplete).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
                    TaskListCard(tasks: done, showProject: true, limit: 100,
                                 empty: EmptyState(icon: "checkmark.circle", title: "Nothing completed yet", message: "Finished tasks appear here.", compact: true))
                default:
                    pending(now: now)
                }
            }
        }
    }

    @ViewBuilder func pending(now: Date) -> some View {
        let overdue = Buckets.overdue(scoped, now: now)
        let today = Buckets.today(scoped, now: now)
        let week = Buckets.upcoming(scoped, now: now)
        let weekEnd = Calendar.current.date(byAdding: .day, value: 7, to: Buckets.endOfToday(now))!
        let later = scoped.filter { !$0.isComplete && !$0.isSnoozed(at: now) && ($0.due.map { $0 >= weekEnd } ?? false) }.sorted { $0.due! < $1.due! }
        let undated = scoped.filter { !$0.isComplete && !$0.isSnoozed(at: now) && $0.due == nil }
        if overdue.isEmpty && today.isEmpty && week.isEmpty && later.isEmpty && undated.isEmpty {
            Card { EmptyState(icon: "checkmark.seal", title: "All clear", message: "Type a task above and press Return. Overdue work stays here until it's done, even if a reminder was missed.") }
        }
        group("Overdue", overdue, Theme.overdue)
        group("Today", today, Theme.today)
        group("Next 7 days", week, Theme.upcoming)
        group("Later", later, Theme.ink2)
        group("No date", undated, Theme.ink2)
    }

    @ViewBuilder func group(_ title: String, _ tasks: [WorkTask], _ tint: Color) -> some View {
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "\(title)  \(tasks.count)", color: tint)
                TaskListCard(tasks: tasks, showProject: projectFilter == nil, empty: EmptyState(icon: "checkmark", title: "", message: ""))
            }
        }
    }
}

// MARK: - Client overview

struct ClientView: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    let client: Client

    var body: some View {
        let projects = store.projects(for: client.id)
        let ids = Set(projects.map(\.id))
        let pending = store.workspace.tasks.filter { ids.contains($0.projectID) && !$0.isComplete }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        Page(spacing: 26) {
            HStack(alignment: .center, spacing: 16) {
                ClientIcon(name: client.name, size: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: "Client", color: Theme.accent)
                    Text(client.name).font(T.display(30)).foregroundStyle(Theme.ink)
                }
                Spacer()
                Button { present(.client(client)) } label: { Label("Edit", systemImage: "pencil") }.buttonStyle(.soft)
                Button { var p = Project(name: ""); p.clientID = client.id; p.kind = .client; present(.project(p)) } label: { Label("New Project", systemImage: "plus") }
                    .buttonStyle(.primary)
            }
            HStack(alignment: .top, spacing: 18) {
                Card {
                    VStack(alignment: .leading, spacing: 11) {
                        Text("Contact").font(T.h3).foregroundStyle(Theme.ink)
                        contact("person", client.contactName)
                        contact("envelope", client.email)
                        contact("phone", client.phone)
                        if let url = webURL(client.website) {
                            Button { NSWorkspace.shared.open(url) } label: { Label(url.host() ?? client.website, systemImage: "globe") }
                                .buttonStyle(.plain).foregroundStyle(Theme.accent).font(T.body)
                        }
                        if client.contactName.isEmpty && client.email.isEmpty && client.phone.isEmpty && client.website.isEmpty {
                            Text("No contact details yet.").font(T.small).foregroundStyle(Theme.ink3)
                        }
                    }
                }.frame(width: 300)
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Shared context").font(T.h3).foregroundStyle(Theme.ink)
                        if client.notes.isEmpty { Text("Notes that apply across this client's projects: preferences, billing, key people.").font(T.small).foregroundStyle(Theme.ink3) }
                        else { MarkdownDocumentView(source: client.notes, baseSize: 14.5) }
                    }
                }
            }
            if !pending.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Pending work", count: pending.count)
                    TaskListCard(tasks: pending, showProject: true, limit: 15, empty: EmptyState(icon: "checkmark", title: "", message: ""))
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Projects", count: projects.count)
                if projects.isEmpty {
                    Card { EmptyState(icon: "square.stack", title: "No projects yet", message: "Projects for this client work the same as your own.", compact: true) }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 18, alignment: .top)], spacing: 18) {
                        ForEach(projects) { ProjectTile(project: $0) }
                    }
                }
            }
        }
    }

    @ViewBuilder func contact(_ icon: String, _ value: String) -> some View {
        if !value.isEmpty { Label(value, systemImage: icon).font(T.body).foregroundStyle(Theme.ink).textSelection(.enabled) }
    }
}
