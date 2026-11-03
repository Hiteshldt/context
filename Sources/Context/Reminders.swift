import Foundation
import EventKit
import AppKit

/// Keeps each project's reminders in its own Apple Reminders list, so they sync to iPhone and notify everywhere.
/// Apple Reminders is the only copy: Context reads and writes it directly and never stores reminders itself.
@MainActor
final class RemindersService: ObservableObject {
    static let shared = RemindersService()

    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access
    /// Open reminders, and those completed in the last 30 days, keyed by list.
    @Published private(set) var items: [String: [ReminderItem]] = [:]
    @Published private(set) var lists: [ReminderList] = []
    @Published var error: String?

    private let store = EKEventStore()
    private var tracked: Set<String> = []
    private var reloadTask: Task<Void, Never>?
    private var demo = false

    private init() {
        access = Self.currentAccess()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .granted
        case .notDetermined: return .unknown
        default: return .denied
        }
    }

    // MARK: Access

    /// Asks macOS for access. Returns true when Context can use Apple Reminders.
    @discardableResult
    func connect() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToReminders()
            access = granted ? .granted : .denied
            if granted { store.reset(); reload() }
            return granted
        } catch {
            access = Self.currentAccess()
            self.error = "Context couldn't connect to Apple Reminders. \(error.localizedDescription)"
            return false
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") { NSWorkspace.shared.open(url) }
    }

    func openRemindersApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app"))
    }

    // MARK: Reading

    /// Which lists to keep loaded: those linked to projects.
    func track(_ listIDs: [String]) {
        let next = Set(listIDs)
        guard next != tracked else { return }
        tracked = next
        reload()
    }

    func reload() {
        if !demo { access = Self.currentAccess() }
        guard access == .granted, !demo else { return }
        reloadTask?.cancel()
        reloadTask = Task {
            lists = store.calendars(for: .reminder).map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            let calendars = tracked.compactMap { store.calendar(withIdentifier: $0) }
            guard !calendars.isEmpty else { items = [:]; return }
            let open = await fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars))
            let done = await fetch(store.predicateForCompletedReminders(withCompletionDateStarting: Date().addingTimeInterval(-30 * 86_400),
                                                                         ending: nil, calendars: calendars))
            guard !Task.isCancelled else { return }
            items = Dictionary(grouping: open + done, by: \.listID)
        }
    }

    private func fetch(_ predicate: NSPredicate) async -> [ReminderItem] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(ReminderItem.init))
            }
        }
    }

    func items(for project: Project) -> [ReminderItem] {
        guard let id = project.remindersListID else { return [] }
        return items[id] ?? []
    }

    /// Overdue and due-today reminders across the given projects.
    func attentionCount(for project: Project, now: Date = Date()) -> Int {
        items(for: project).filter { $0.needsAttention(now: now) }.count
    }

    func listName(for project: Project) -> String? {
        guard let id = project.remindersListID else { return nil }
        return lists.first { $0.id == id }?.title ?? (demo ? project.name : store.calendar(withIdentifier: id)?.title)
    }

    // MARK: Lists

    /// The project's list, adopting a list with the same name or creating one the first time it's needed.
    func ensureList(for projectID: UUID, in workspace: Store) throws -> String {
        guard let project = workspace.project(projectID) else { throw WorkspaceError.invalid("The project no longer exists.") }
        if demo { return project.remindersListID ?? "demo-\(projectID)" }
        if let id = project.remindersListID, store.calendar(withIdentifier: id) != nil { return id }
        let calendar: EKCalendar
        if let existing = store.calendars(for: .reminder).first(where: { $0.title.caseInsensitiveCompare(project.name) == .orderedSame }) {
            calendar = existing
        } else {
            calendar = EKCalendar(for: .reminder, eventStore: store)
            calendar.title = project.name
            calendar.cgColor = Theme.base(project.color).cgColor
            guard let source = store.defaultCalendarForNewReminders()?.source
                    ?? store.sources.first(where: { !$0.calendars(for: .reminder).isEmpty }) else {
                throw WorkspaceError.invalid("Apple Reminders has no account to add a list to. Open Reminders once, then try again.")
            }
            calendar.source = source
            try store.saveCalendar(calendar, commit: true)
        }
        link(projectID, to: calendar.calendarIdentifier, in: workspace)
        return calendar.calendarIdentifier
    }

    /// Points a project at an existing list.
    func link(_ projectID: UUID, to listID: String, in workspace: Store) {
        guard var project = workspace.project(projectID), project.remindersListID != listID else { return }
        project.remindersListID = listID
        workspace.saveQuietly(project)
        track(workspace.workspace.projects.compactMap(\.remindersListID))
        reload()
    }

    /// Keeps a project's list name in step with the project, if the list still has the old name.
    func renameList(of project: Project, from oldName: String) {
        guard !demo, let id = project.remindersListID, let calendar = store.calendar(withIdentifier: id),
              calendar.title == oldName, oldName != project.name, calendar.allowsContentModifications else { return }
        calendar.title = project.name
        try? store.saveCalendar(calendar, commit: true)
    }

    // MARK: Writing

    func add(_ title: String, notes: String = "", due: Date?, hasTime: Bool, repeats: RepeatOption = .never, to projectID: UUID, in workspace: Store) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            let listID = try ensureList(for: projectID, in: workspace)
            if demo {
                items[listID, default: []].append(ReminderItem(listID: listID, title: title, notes: notes, due: due, hasTime: hasTime, repeats: repeats, createdAt: Date()))
                return
            }
            guard let calendar = store.calendar(withIdentifier: listID) else { return }
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = calendar
            reminder.title = title
            reminder.notes = notes.isEmpty ? nil : notes
            apply(due: due, hasTime: hasTime, repeats: repeats, to: reminder)
            try store.save(reminder, commit: true)
            reload()
        } catch { self.error = "The reminder couldn't be saved to Apple Reminders. \(error.localizedDescription)" }
    }

    /// Saves edits to a reminder. The repeat rule is only rewritten when it changed.
    func update(_ item: ReminderItem) {
        if demo { replaceDemo(item); return }
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { reload(); return }
        let previous = ReminderItem(reminder)
        reminder.title = item.title
        reminder.notes = item.notes.isEmpty ? nil : item.notes
        apply(due: item.due, hasTime: item.hasTime, repeats: item.repeats == previous.repeats ? nil : item.repeats, to: reminder)
        save(reminder)
    }

    func setCompleted(_ item: ReminderItem, _ completed: Bool) {
        if demo { var copy = item; copy.isCompleted = completed; copy.completedAt = completed ? Date() : nil; replaceDemo(copy); return }
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { reload(); return }
        reminder.isCompleted = completed
        save(reminder)
    }

    func delete(_ item: ReminderItem) {
        if demo { items[item.listID]?.removeAll { $0.id == item.id }; return }
        guard let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else { reload(); return }
        do { try store.remove(reminder, commit: true); reload() }
        catch { self.error = "The reminder couldn't be deleted. \(error.localizedDescription)" }
    }

    private func save(_ reminder: EKReminder) {
        do { try store.save(reminder, commit: true); reload() }
        catch { self.error = "The change couldn't be saved to Apple Reminders. \(error.localizedDescription)"; reload() }
    }

    /// Sets the due date, its alert, and (when `repeats` isn't nil) the repeat rule.
    private func apply(due: Date?, hasTime: Bool, repeats: RepeatOption?, to reminder: EKReminder) {
        reminder.dueDateComponents = due.map { DateComponents.reminderDue($0, hasTime: hasTime) }
        // Replace only time-based alerts; location alerts made in Apple Reminders stay.
        for alarm in reminder.alarms ?? [] where alarm.absoluteDate != nil || (alarm.structuredLocation == nil && alarm.relativeOffset == 0) {
            reminder.removeAlarm(alarm)
        }
        if let due, hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        if due == nil {
            for rule in reminder.recurrenceRules ?? [] { reminder.removeRecurrenceRule(rule) }
        } else if let repeats, repeats != .custom {
            for rule in reminder.recurrenceRules ?? [] { reminder.removeRecurrenceRule(rule) }
            if let rule = repeats.rule { reminder.addRecurrenceRule(rule) }
        }
    }

    // MARK: Earlier versions

    /// Moves open tasks from earlier versions of Context into each project's Apple Reminders list.
    /// A task is removed from Context only after Apple Reminders has saved it.
    func importLocalTasks(from workspace: Store) -> Int {
        guard access == .granted, !demo else { return 0 }
        var moved = 0
        for task in workspace.workspace.tasks where !task.isComplete {
            do {
                let listID = try ensureList(for: task.projectID, in: workspace)
                guard let calendar = store.calendar(withIdentifier: listID) else { continue }
                let reminder = EKReminder(eventStore: store)
                reminder.calendar = calendar
                reminder.title = task.title.isEmpty ? "Untitled" : task.title
                var notes = task.details
                if task.repeatRule.kind == .afterCompletion {
                    notes += (notes.isEmpty ? "" : "\n\n") + "Repeated \(task.repeatRule.interval) days after completion in Context."
                }
                reminder.notes = notes.isEmpty ? nil : notes
                if let due = task.due {
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: due)
                    let hasTime = (parts.hour ?? 0) != 0 || (parts.minute ?? 0) != 0
                    reminder.dueDateComponents = .reminderDue(due, hasTime: hasTime)
                    if hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
                    if let rule = RepeatOption.rule(for: task.repeatRule) { reminder.addRecurrenceRule(rule) }
                }
                try store.save(reminder, commit: true)
                workspace.deleteTask(task.id)
                moved += 1
            } catch {
                self.error = "Some reminders from earlier versions couldn't be moved. \(error.localizedDescription)"
            }
        }
        reload()
        return moved
    }

    // MARK: Demo data (screenshots)

    /// Shows the given reminders without touching Apple Reminders. Used only by the snapshot script.
    func useDemo(_ demoItems: [ReminderItem], lists demoLists: [ReminderList]) {
        demo = true
        access = .granted
        items = Dictionary(grouping: demoItems, by: \.listID)
        lists = demoLists
    }

    private func replaceDemo(_ item: ReminderItem) {
        guard let index = items[item.listID]?.firstIndex(where: { $0.id == item.id }) else { return }
        items[item.listID]?[index] = item
    }
}
