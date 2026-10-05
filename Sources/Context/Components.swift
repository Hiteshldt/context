import SwiftUI
import AppKit

// MARK: - Tasks

struct TaskRow: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    @Environment(\.navigate) var navigate
    @Environment(\.pageTint) var tint
    let task: WorkTask
    var showProject = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { withAnimation(.easeOut(duration: 0.2)) { store.toggle(task) } } label: {
                Image(systemName: task.isComplete ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(task.isComplete ? Theme.success : (hovering ? tint : Theme.ink3))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(task.isComplete ? "Reopen task" : (task.repeatRule.repeats ? "Complete this occurrence" : "Complete task"))
            .accessibilityLabel(task.isComplete ? "Reopen \(task.title)" : "Complete \(task.title)")

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(T.body)
                    .strikethrough(task.isComplete)
                    .foregroundStyle(task.isComplete ? Theme.ink3 : Theme.ink)
                    .lineLimit(2)
                meta
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { present(.task(task)) }

            if let due = task.due, !task.isComplete {
                let label = DueText.describe(due, now: store.clock)
                Text(label.text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(label.color).lineLimit(1)
            } else if let done = task.completedAt {
                Text("Done \(done.formatted(.dateTime.month(.abbreviated).day()))").font(T.caption).foregroundStyle(Theme.ink3)
            }
            Menu { TaskActions(task: task) } label: { Image(systemName: "ellipsis").foregroundStyle(Theme.ink2).frame(width: 20, height: 20) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .opacity(hovering ? 1 : 0)
                .help("More actions")
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
        .contextMenu { TaskActions(task: task) }
    }

    @ViewBuilder var meta: some View {
        let project = store.project(task.projectID)
        let showMeta = showProject || task.repeatRule.repeats || !task.platform.isEmpty || task.isSnoozed(at: store.clock) || task.reminderDate != nil || !task.relatedIDs.isEmpty
        if showMeta {
            HStack(spacing: 9) {
                if showProject, let project {
                    Button { navigate(.project(project.id)) } label: {
                        HStack(spacing: 5) {
                            Circle().fill(Theme.color(project.color)).frame(width: 7, height: 7)
                            Text(project.name)
                        }
                    }.buttonStyle(.plain).help("Open \(project.name)")
                }
                if task.repeatRule.repeats { Label(task.repeatRule.summary(), systemImage: "repeat") }
                if !task.platform.isEmpty { Label(task.platform, systemImage: "paperplane") }
                if task.isSnoozed(at: store.clock), let until = task.snoozedUntil {
                    Label("Snoozed · \(until.formatted(.dateTime.weekday(.abbreviated).hour().minute()))", systemImage: "moon.zzz")
                } else if task.reminderDate != nil {
                    Image(systemName: "bell").help("Notification scheduled")
                }
                if !task.relatedIDs.isEmpty { Label("\(task.relatedIDs.count)", systemImage: "link").help("Linked records") }
            }
            .font(T.caption).foregroundStyle(Theme.ink2).lineLimit(1)
        }
    }
}

struct TaskActions: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    let task: WorkTask
    var body: some View {
        Button("Edit…") { present(.task(task)) }
        Button(task.isComplete ? "Reopen" : (task.repeatRule.repeats ? "Complete This Occurrence" : "Complete")) { store.toggle(task) }
        if !task.isComplete {
            Menu("Snooze") {
                ForEach(SnoozeOption.options(), id: \.label) { option in
                    Button(option.label) { store.snooze(task, until: option.date) }
                }
                if task.snoozedUntil != nil { Divider(); Button("Clear Snooze") { var t = task; t.snoozedUntil = nil; store.save(t) } }
            }
            if !task.repeatRule.repeats {
                Menu("Defer") {
                    ForEach(SnoozeOption.deferrals(), id: \.label) { option in
                        Button(option.label) { store.postpone(task, to: option.date) }
                    }
                }
            }
        }
        Divider()
        Button("Delete Task", role: .destructive) { store.deleteTask(task.id) }
    }
}

struct SnoozeOption {
    let label: String
    let date: Date
    static func options(now: Date = Date(), calendar: Calendar = .current) -> [SnoozeOption] {
        var result = [SnoozeOption(label: "For 1 Hour", date: now.addingTimeInterval(3600))]
        if let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now), evening > now.addingTimeInterval(3600) {
            result.append(SnoozeOption(label: "Until This Evening", date: evening))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
            result.append(SnoozeOption(label: "Until Tomorrow Morning", date: morning))
        }
        if let week = calendar.nextDate(after: now, matching: DateComponents(hour: 9, weekday: 2), matchingPolicy: .nextTime) {
            result.append(SnoozeOption(label: "Until Next Monday", date: week))
        }
        return result
    }
    static func deferrals(now: Date = Date(), calendar: Calendar = .current) -> [SnoozeOption] {
        [(1, "To Tomorrow"), (3, "By 3 Days"), (7, "By a Week")].compactMap { days, label in
            calendar.date(byAdding: .day, value: days, to: now).map { SnoozeOption(label: label, date: $0) }
        }
    }
}

struct TaskListCard: View {
    let tasks: [WorkTask]
    var showProject = false
    var limit: Int? = nil
    var empty: EmptyState
    var body: some View {
        Card(padding: 6) {
            if tasks.isEmpty { empty }
            else {
                VStack(spacing: 0) {
                    let shown = limit.map { Array(tasks.prefix($0)) } ?? tasks
                    ForEach(shown) { task in
                        TaskRow(task: task, showProject: showProject)
                        if task.id != shown.last?.id { Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 44) }
                    }
                    if let limit, tasks.count > limit {
                        Text("+ \(tasks.count - limit) more").font(T.caption).foregroundStyle(Theme.ink2).padding(8)
                    }
                }
            }
        }
    }
}

/// One line to capture a task without opening an editor.
struct QuickCapture: View {
    @EnvironmentObject var store: Store
    @Environment(\.pageTint) var tint
    var fixedProject: UUID? = nil
    var placeholder = "Add a task and press Return"
    @State private var title = ""
    @State private var projectID: UUID?
    @State private var when = 0
    @FocusState private var focused: Bool

    let options = [(0, "No date"), (1, "Today"), (2, "Tomorrow"), (3, "Next week")]

    var body: some View {
        let project = store.project(fixedProject ?? projectID ?? recentProject ?? UUID())
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill").foregroundStyle(tint).font(.system(size: 17))
            TextField(placeholder, text: $title)
                .textFieldStyle(.plain).font(T.body)
                .focused($focused)
                .onSubmit(add)
            if fixedProject == nil, store.workspace.projects.count > 1 {
                Menu {
                    ForEach(store.workspace.projects) { p in Button(p.name) { projectID = p.id } }
                } label: {
                    HStack(spacing: 5) {
                        if let project { Circle().fill(Theme.color(project.color)).frame(width: 7, height: 7) }
                        Text(project?.name ?? "Project").lineLimit(1)
                    }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            Menu { ForEach(options, id: \.0) { option in Button(option.1) { when = option.0 } } } label: {
                Label(options[when].1, systemImage: "calendar")
            }.menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? tint.opacity(0.7) : Theme.border, lineWidth: focused ? 1.5 : 1))
    }

    var recentProject: UUID? { store.workspace.projects.sorted { $0.updatedAt > $1.updatedAt }.first?.id }

    func add() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let id = fixedProject ?? projectID ?? recentProject else { return }
        var task = WorkTask(projectID: id, title: trimmed)
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        switch when {
        case 1: task.due = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: start)
        case 2: task.due = calendar.date(byAdding: .day, value: 1, to: start).flatMap { calendar.date(bySettingHour: 9, minute: 0, second: 0, of: $0) }
        case 3: task.due = calendar.date(byAdding: .day, value: 7, to: start).flatMap { calendar.date(bySettingHour: 9, minute: 0, second: 0, of: $0) }
        default: break
        }
        if store.save(task) { title = "" }
    }
}

// MARK: - Related records

/// Shows links to related records; removed records are flagged rather than silently hidden.
struct RelatedChips: View {
    @EnvironmentObject var store: Store
    @Environment(\.present) var present
    @Environment(\.pageTint) var tint
    let ids: [UUID]
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(ids, id: \.self) { id in
                if let record = store.recordTitle(id) {
                    Button {
                        if let entry = store.entry(id) { present(.entry(entry)) }
                        else if let task = store.workspace.tasks.first(where: { $0.id == id }) { present(.task(task)) }
                    } label: { Pill(text: record.title, icon: record.icon, color: tint) }.buttonStyle(.plain)
                } else {
                    Pill(text: "Removed record", icon: "exclamationmark.triangle", color: Theme.overdue)
                }
            }
        }
    }
}

/// A menu for choosing linked records within a project.
struct RecordLinker: View {
    @EnvironmentObject var store: Store
    let projectID: UUID
    var excluding: UUID? = nil
    @Binding var selection: [UUID]
    var body: some View {
        let entries = store.workspace.entries.filter { $0.projectID == projectID && $0.id != excluding }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let tasks = store.workspace.tasks.filter { $0.projectID == projectID && $0.id != excluding && !$0.isComplete }
        Menu {
            if entries.isEmpty && tasks.isEmpty { Text("Nothing to link yet") }
            ForEach(EntryKind.allCases) { kind in
                let group = entries.filter { $0.kind == kind }
                if !group.isEmpty {
                    Section(kind.rawValue) {
                        ForEach(group) { entry in toggle(entry.id, entry.title.isEmpty ? "Untitled" : entry.title) }
                    }
                }
            }
            if !tasks.isEmpty { Section("Tasks") { ForEach(tasks) { toggle($0.id, $0.title) } } }
        } label: { Label(selection.isEmpty ? "Link records" : "\(selection.count) linked", systemImage: "link") }
        .fixedSize()
    }
    func toggle(_ id: UUID, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { selection.contains(id) }, set: { on in
            if on { selection.append(id) } else { selection.removeAll { $0 == id } }
        }))
    }
}

// MARK: - Opening links elsewhere

/// Other browsers installed on this Mac.
enum InstalledBrowsers {
    static func all() -> [URL] {
        guard let probe = URL(string: "https://example.com") else { return [] }
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: probe).filter { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard name != "Context", !seen.contains(name) else { return false }
            seen.insert(name)
            return true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    static func name(_ app: URL) -> String { FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "") }
    static func open(_ url: URL, with app: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct OpenInBrowserMenu: View {
    let url: URL
    var body: some View {
        Menu("Open in") {
            ForEach(InstalledBrowsers.all(), id: \.self) { app in
                Button { InstalledBrowsers.open(url, with: app) } label: {
                    Label { Text(InstalledBrowsers.name(app)) } icon: { Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)) }
                }
            }
        }
    }
}

func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
