import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers

extension Notification.Name { static let contextShowHome = Notification.Name("ContextShowHome") }

protocol ProjectOwned: Identifiable where ID == UUID { var projectID: UUID { get } }
extension Entry: ProjectOwned {}
extension WorkTask: ProjectOwned {}
extension FolderConnection: ProjectOwned {}
extension ContentItem: ProjectOwned {}
extension Diagram: ProjectOwned {}
extension ImageRecipe: ProjectOwned {}
extension ImageExport: ProjectOwned {}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var workspace = Workspace()
    @Published var error: String?
    @Published var loadFailed = false
    @Published var notificationStatus = "Reminders are off"
    @Published var notificationsAllowed = false
    /// Remembers the last open section per project for this session.
    @Published var lastSection: [UUID: ProjectSection] = [:]
    /// The folder shown in each project's Files section.
    @Published var selectedFolder: [UUID: UUID] = [:]
    /// The note open in each project's Notes section.
    @Published var selectedNote: [UUID: UUID] = [:]
    /// Called after every successful save (used to schedule backups).
    var onChange: (() -> Void)?
    /// Bumped on wake and activation so time-based views re-evaluate "overdue" and "today".
    @Published var clock = Date()
    let disk: WorkspaceDisk
    private var syncingReminders = false
    private var resyncRequested = false

    init(directory: URL? = nil) {
        let base = directory ?? ProcessInfo.processInfo.environment["CONTEXT_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Context", isDirectory: true)
        disk = WorkspaceDisk(directory: base)
        SiteIconStore.shared.directory = base.appendingPathComponent("SiteIcons", isDirectory: true)
        do { workspace = try disk.load() }
        catch { loadFailed = true; self.error = "Your workspace could not be loaded. The original file has been preserved. \(error.localizedDescription)" }
    }

    // MARK: Persistence

    @discardableResult
    func change(_ edit: (inout Workspace) -> Void) -> Bool {
        guard !loadFailed else { error = "Restore a valid backup before making changes. Your unreadable workspace has been preserved."; return false }
        var next = workspace
        edit(&next)
        do { try disk.save(next); workspace = next; onChange?(); return true }
        catch { self.error = "Could not save your change: \(error.localizedDescription)"; return false }
    }

    private func touch(_ projectID: UUID, in state: inout Workspace) {
        if let index = state.projects.firstIndex(where: { $0.id == projectID }) { state.projects[index].updatedAt = Date() }
    }

    @discardableResult
    func upsert<T: ProjectOwned & Equatable>(_ item: T, in keyPath: WritableKeyPath<Workspace, [T]>) -> Bool {
        let saved = change { state in
            if let index = state[keyPath: keyPath].firstIndex(where: { $0.id == item.id }) { state[keyPath: keyPath][index] = item }
            else { state[keyPath: keyPath].append(item) }
            touch(item.projectID, in: &state)
        }
        if saved && T.self == WorkTask.self { Task { await syncReminders() } }
        return saved
    }

    func remove<T: ProjectOwned>(_ id: UUID, in keyPath: WritableKeyPath<Workspace, [T]>) {
        let saved = change { $0[keyPath: keyPath].removeAll { $0.id == id } }
        if saved && T.self == WorkTask.self { Task { await syncReminders() } }
    }

    // MARK: Lookups

    func project(_ id: UUID) -> Project? { workspace.projects.first { $0.id == id } }
    func client(_ id: UUID?) -> Client? { id.flatMap { id in workspace.clients.first { $0.id == id } } }
    func entry(_ id: UUID) -> Entry? { workspace.entries.first { $0.id == id } }
    func folder(_ id: UUID?) -> FolderConnection? { id.flatMap { id in workspace.folders.first { $0.id == id } } }
    func clientName(for project: Project) -> String? { client(project.clientID)?.name }
    func projects(for clientID: UUID) -> [Project] { workspace.projects.filter { $0.clientID == clientID } }
    var personalProjects: [Project] { workspace.projects.filter { $0.clientID == nil } }

    /// Resolves a related record id to a display title, or nil if the record was removed.
    func recordTitle(_ id: UUID) -> (title: String, icon: String)? {
        if let entry = entry(id) { return (entry.title, entry.kind.icon) }
        if let task = workspace.tasks.first(where: { $0.id == id }) { return (task.title, "checkmark.circle") }
        if let folder = folder(id) { return (folder.name, "folder") }
        return nil
    }

    // MARK: Projects and clients

    @discardableResult
    func save(_ project: Project) -> Bool {
        change { state in
            var updated = project
            updated.updatedAt = Date()
            if let i = state.projects.firstIndex(where: { $0.id == project.id }) { state.projects[i] = updated }
            else { state.projects.append(updated) }
        }
    }

    /// Updates a project without changing its "recently updated" time (e.g. section reordering is not content work).
    @discardableResult
    func saveQuietly(_ project: Project) -> Bool {
        change { state in
            if let i = state.projects.firstIndex(where: { $0.id == project.id }) { state.projects[i] = project }
        }
    }

    func deleteProject(_ id: UUID) {
        let credentialIDs = workspace.credentialIDs { $0.projectID == id }
        if change({ state in
            state.projects.removeAll { $0.id == id }
            state.entries.removeAll { $0.projectID == id }
            state.tasks.removeAll { $0.projectID == id }
            state.folders.removeAll { $0.projectID == id }
            state.contentItems.removeAll { $0.projectID == id }
            state.diagrams.removeAll { $0.projectID == id }
            state.recipes.removeAll { $0.projectID == id }
            state.exports.removeAll { $0.projectID == id }
        }) {
            CredentialVault.delete(credentialIDs)
            Task { await syncReminders() }
        }
    }

    /// Summarises what deleting a project removes. External files are never touched.
    func deletionSummary(for id: UUID) -> String {
        let w = workspace
        let parts: [(Int, String)] = [
            (w.entries.filter { $0.projectID == id }.count, "saved records"),
            (w.tasks.filter { $0.projectID == id }.count, "tasks"),
            (w.folders.filter { $0.projectID == id }.count, "folder connections"),
            (w.contentItems.filter { $0.projectID == id }.count, "planned posts"),
            (w.diagrams.filter { $0.projectID == id }.count, "diagrams"),
            (w.recipes.filter { $0.projectID == id }.count, "image recipes"),
        ]
        let listed = parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        let credentials = w.credentialIDs { $0.projectID == id }.count
        var text = listed.isEmpty ? "This project has no saved records." : "This removes \(listed.joined(separator: ", ")) from Context."
        if credentials > 0 { text += " \(credentials) stored secrets will be deleted from the Keychain." }
        return text + " Connected folders, exported images, and all files on disk stay untouched."
    }

    @discardableResult
    func save(_ client: Client) -> Bool {
        change { state in
            if let i = state.clients.firstIndex(where: { $0.id == client.id }) { state.clients[i] = client }
            else { state.clients.append(client) }
        }
    }

    func deleteClient(_ id: UUID) {
        change { state in
            state.clients.removeAll { $0.id == id }
            for i in state.projects.indices where state.projects[i].clientID == id { state.projects[i].clientID = nil }
        }
    }

    // MARK: Entries and credentials

    @discardableResult
    func save(_ entry: Entry) -> Bool {
        var updated = entry
        updated.updatedAt = Date()
        let removed = (self.entry(entry.id)?.credentials.map(\.id) ?? []).filter { id in !entry.credentials.contains { $0.id == id } }
        let saved = upsert(updated, in: \.entries)
        if saved { CredentialVault.delete(removed) }
        return saved
    }

    func deleteEntry(_ id: UUID) {
        let credentialIDs = entry(id)?.credentials.map(\.id) ?? []
        if change({ $0.entries.removeAll { $0.id == id } }) { CredentialVault.delete(credentialIDs) }
    }

    func togglePin(_ entry: Entry) {
        var updated = entry
        updated.pinned.toggle()
        change { state in
            if let i = state.entries.firstIndex(where: { $0.id == entry.id }) { state.entries[i] = updated }
        }
    }

    /// Opens a saved link in the default browser and remembers that it was used, so frequent links surface first.
    func open(_ entry: Entry) {
        guard let url = webURL(entry.url) else { return }
        NSWorkspace.shared.open(url)
        change { state in
            if let i = state.entries.firstIndex(where: { $0.id == entry.id }) {
                state.entries[i].lastOpenedAt = Date()
                state.entries[i].openCount += 1
            }
        }
    }

    /// Records a visit to a project (at most once an hour) so Home can say how long it has been.
    func markOpened(_ projectID: UUID) {
        guard let project = project(projectID), (project.lastOpenedAt ?? .distantPast) < Date().addingTimeInterval(-3600) else { return }
        change { state in
            if let i = state.projects.firstIndex(where: { $0.id == projectID }) { state.projects[i].lastOpenedAt = Date() }
        }
    }

    // MARK: Tasks

    @discardableResult
    func save(_ task: WorkTask) -> Bool { upsert(task, in: \.tasks) }

    func toggle(_ task: WorkTask) {
        var updated = task
        if updated.isComplete { updated.reopen() } else { updated.complete() }
        save(updated)
    }

    func snooze(_ task: WorkTask, until date: Date) {
        var updated = task
        updated.snoozedUntil = date
        save(updated)
    }

    /// Moves a one-off task's due date. For recurring work this snoozes the occurrence instead, keeping the schedule intact.
    func postpone(_ task: WorkTask, to date: Date) {
        var updated = task
        if task.repeatRule.repeats { updated.snoozedUntil = date }
        else {
            if let due = task.due {
                // Keep the original time of day when deferring by whole days.
                let time = Calendar.current.dateComponents([.hour, .minute], from: due)
                updated.due = Calendar.current.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: date) ?? date
            } else { updated.due = date }
            updated.snoozedUntil = nil
        }
        save(updated)
    }

    func deleteTask(_ id: UUID) { remove(id, in: \.tasks) }

    // MARK: Social

    func togglePlatform(_ item: ContentItem, target: UUID) {
        var updated = item
        guard let index = updated.targets.firstIndex(where: { $0.id == target }) else { return }
        updated.targets[index].completedAt = updated.targets[index].isDone ? nil : Date()
        updated.updatedAt = Date()
        upsert(updated, in: \.contentItems)
    }

    // MARK: Folders

    func connectFolder(projectID: UUID, replacing: UUID? = nil, purpose: String = "") {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = replacing == nil ? "Connect Folder" : "Reconnect"
        panel.message = "The folder stays where it is. Context saves a reference only and never copies, moves, or deletes files."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let previous = folder(replacing)
            var connection = FolderConnection(id: replacing ?? UUID(), projectID: projectID, name: url.lastPathComponent, path: url.path, bookmark: bookmark)
            connection.purpose = previous?.purpose ?? purpose
            if workspace.folders.contains(where: { $0.projectID == projectID && $0.path == url.path && $0.id != connection.id }) {
                error = "\(url.lastPathComponent) is already connected to this project."
                return
            }
            upsert(connection, in: \.folders)
        } catch { self.error = error.localizedDescription }
    }

    func status(of folder: FolderConnection) -> FolderStatus {
        let result = resolveFolder(folder)
        if let refreshed = result.refreshed {
            // Persist a moved folder's new location after the current view update.
            DispatchQueue.main.async { [weak self] in
                self?.change { state in
                    if let i = state.folders.firstIndex(where: { $0.id == refreshed.id }) { state.folders[i] = refreshed }
                }
            }
        }
        return result.status
    }

    func resolve(_ folder: FolderConnection) throws -> URL {
        switch status(of: folder) {
        case .available(let url): return url
        case .unavailable(let message): throw WorkspaceError.invalid(message)
        }
    }

    func disconnectFolder(_ id: UUID) {
        change { state in
            state.folders.removeAll { $0.id == id }
            for i in state.entries.indices where state.entries[i].folderID == id { state.entries[i].folderID = nil }
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    // MARK: Backup

    func exportBackup() {
        guard !loadFailed else { error = "Restore a valid workspace before exporting. Your original data is preserved in the local data folder."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let stamp = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "Context-backup-\(stamp).json"
        panel.message = "A backup contains your projects, links, notes, tasks, and maps. It does not contain files in connected folders or passwords stored in the Keychain."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try disk.encode(workspace).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { self.error = error.localizedDescription }
    }

    func restoreBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a Context backup. This replaces the app's records, not connected files."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        restore(from: url)
    }

    /// Replaces the workspace with a backup after confirmation. The current data is copied aside first.
    @discardableResult
    func restore(from url: URL) -> Bool {
        do {
            let restored = try disk.decode(Data(contentsOf: url))
            let alert = NSAlert()
            alert.messageText = "Restore this backup?"
            let unavailable = restored.folders.filter { if case .unavailable = resolveFolder($0).status { return true }; return false }.count
            let notes = restored.entries.filter { $0.kind == .note || $0.kind == .prompt }.count
            var info = "This replaces what's in Context now with \(restored.projects.count) projects, \(restored.entries.count - notes) links, and \(notes) notes from the backup. Your files on disk are not touched, and a copy of the current data is kept."
            if unavailable > 0 { info += "\n\n\(unavailable) connected folders aren't reachable on this Mac. You can reconnect them from each project's Files." }
            alert.informativeText = info
            alert.addButton(withTitle: "Restore"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if FileManager.default.fileExists(atPath: disk.file.path) {
                let label = loadFailed ? "unreadable" : "before-restore"
                let preserved = disk.directory.appendingPathComponent("workspace-\(label)-\(Int(Date().timeIntervalSince1970)).json")
                try FileManager.default.copyItem(at: disk.file, to: preserved)
                if loadFailed { try FileManager.default.removeItem(at: disk.file) }
            }
            try disk.save(restored)
            workspace = restored; loadFailed = false
            onChange?()
            Task { await syncReminders() }
            return true
        } catch { self.error = "Could not restore: \(error.localizedDescription)"; return false }
    }

    // MARK: Notifications

    func refreshClock() { clock = Date() }

    /// UserNotifications requires running from the .app bundle; `swift run` and tools have no bundle identifier.
    var canUseNotifications: Bool { Bundle.main.bundleIdentifier != nil }

    func enableNotifications() async {
        guard canUseNotifications else { error = "Notifications need the Context.app bundle. Build it with scripts/build-app.sh."; return }
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            if !allowed { error = "Notifications are disabled. Enable Context in System Settings → Notifications. Tasks remain visible in the app." }
            await syncReminders()
        } catch { self.error = error.localizedDescription }
    }

    func syncReminders() async {
        // Coalesce overlapping saves/activation events so an older pass cannot leave stale requests behind.
        if syncingReminders { resyncRequested = true; return }
        syncingReminders = true
        defer { syncingReminders = false }
        repeat {
            resyncRequested = false
            await scheduleReminders()
        } while resyncRequested
    }

    private func scheduleReminders() async {
        guard canUseNotifications else { notificationStatus = "Notifications unavailable outside the app bundle"; return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        notificationsAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        guard notificationsAllowed else {
            notificationStatus = settings.authorizationStatus == .denied ? "Notifications are blocked in System Settings" : "Reminders are off"
            return
        }
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier))
        let now = Date()
        let candidates = workspace.tasks.compactMap { task -> (WorkTask, Date)? in
            guard let date = task.reminderDate, date > now else { return nil }
            return (task, date)
        }.sorted { $0.1 < $1.1 }
        // Keep a bounded set of upcoming notifications. All tasks remain in the attention views regardless.
        var failures = 0
        for (task, date) in candidates.prefix(60) {
            let content = UNMutableNotificationContent()
            // Generic text keeps project and task details off the lock screen.
            content.title = "A task needs your attention"
            content.body = "Open Context to review your pending work."
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date), repeats: false)
            do { try await center.add(UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: trigger)) }
            catch { failures += 1 }
        }
        let count = min(candidates.count, 60)
        notificationStatus = failures > 0 ? "Some reminders could not be scheduled" : (count == 1 ? "1 reminder scheduled" : "\(count) reminders scheduled")
    }
}
