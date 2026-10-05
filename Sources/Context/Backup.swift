import Foundation

struct BackupFile: Identifiable, Equatable {
    let url: URL
    let date: Date
    let size: Int
    var id: String { url.path }
}

/// Writes one dated backup file per day into a "Context Backups" folder and prunes old ones.
/// Pointing this at a folder synced by Google Drive, iCloud Drive, OneDrive, or Dropbox gives cloud backup
/// without Context ever signing in to anything.
enum BackupWriter {
    static let folderName = "Context Backups"

    static func fileName(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "Context-%04d-%02d-%02d.json", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func directory(in folder: URL) -> URL { folder.appendingPathComponent(folderName, isDirectory: true) }

    /// Writes (or replaces) the backup for `date`'s day. Keeps the newest `keep` files.
    @discardableResult
    static func write(_ data: Data, into folder: URL, date: Date = Date(), keep: Int = 30, calendar: Calendar = .current) throws -> URL {
        let directory = directory(in: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(fileName(for: date, calendar: calendar))
        try data.write(to: file, options: .atomic)
        let files = list(in: folder)
        for old in files.dropFirst(max(1, keep)) { try? FileManager.default.removeItem(at: old.url) }
        return file
    }

    /// Backups found in `folder`, newest first.
    static func list(in folder: URL) -> [BackupFile] {
        let directory = directory(in: folder)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap { name -> BackupFile? in
            guard name.hasPrefix("Context-"), name.hasSuffix(".json") else { return nil }
            let stamp = name.dropFirst("Context-".count).dropLast(".json".count).split(separator: "-").compactMap { Int($0) }
            guard stamp.count == 3, let date = Calendar.current.date(from: DateComponents(year: stamp[0], month: stamp[1], day: stamp[2], hour: 12)) else { return nil }
            let url = directory.appendingPathComponent(name)
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
            return BackupFile(url: url, date: date, size: size)
        }.sorted { $0.date > $1.date }
    }
}

struct CloudFolder: Identifiable, Equatable {
    let name: String
    let icon: String
    let url: URL
    var id: String { url.path }
    var detail: String {
        if name.hasPrefix("Google Drive") { return "My Drive › Context Backups — synced by Google Drive for desktop" }
        if name == "iCloud Drive" { return "iCloud Drive › Context Backups — synced with your Apple account" }
        if name.hasPrefix("OneDrive") { return "OneDrive › Context Backups — synced by OneDrive" }
        if name == "Dropbox" { return "Dropbox › Context Backups — synced by Dropbox" }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }
}

enum CloudFolders {
    /// Folders on this Mac that a cloud service keeps in sync.
    static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [CloudFolder] {
        let fm = FileManager.default
        var found: [CloudFolder] = []
        let storage = home.appendingPathComponent("Library/CloudStorage")
        for name in ((try? fm.contentsOfDirectory(atPath: storage.path)) ?? []).sorted() where !name.hasPrefix(".") {
            let url = storage.appendingPathComponent(name)
            if name.hasPrefix("GoogleDrive") {
                let account = name.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init)
                let drive = url.appendingPathComponent("My Drive")
                found.append(CloudFolder(name: account.map { "Google Drive (\($0))" } ?? "Google Drive", icon: "externaldrive.badge.icloud",
                                         url: fm.fileExists(atPath: drive.path) ? drive : url))
            } else if name.hasPrefix("OneDrive") {
                found.append(CloudFolder(name: name.replacingOccurrences(of: "-", with: " · "), icon: "cloud", url: url))
            } else if name.hasPrefix("Dropbox") {
                found.append(CloudFolder(name: "Dropbox", icon: "shippingbox", url: url))
            } else {
                found.append(CloudFolder(name: name.replacingOccurrences(of: "-", with: " · "), icon: "cloud", url: url))
            }
        }
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: icloud.path) { found.append(CloudFolder(name: "iCloud Drive", icon: "icloud", url: icloud)) }
        let dropbox = home.appendingPathComponent("Dropbox")
        if fm.fileExists(atPath: dropbox.path), !found.contains(where: { $0.name == "Dropbox" }) {
            found.append(CloudFolder(name: "Dropbox", icon: "shippingbox", url: dropbox))
        }
        return found
    }

    static func name(for path: String) -> String {
        if path.contains("/CloudStorage/GoogleDrive") { return "Google Drive" }
        if path.contains("com~apple~CloudDocs") { return "iCloud Drive" }
        if path.contains("/CloudStorage/OneDrive") { return "OneDrive" }
        if path.contains("Dropbox") { return "Dropbox" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

struct BackupSettings: Codable, Equatable {
    var folderPath: String?
    var automatic = true
    var keep = 30
    var lastBackupAt: Date?
    var lastError: String?
}

/// Schedules and performs backups. Settings live next to the workspace file so test data never touches real backups.
@MainActor
final class BackupManager: ObservableObject {
    @Published private(set) var settings = BackupSettings()
    @Published private(set) var isWorking = false
    /// Supplies the encoded workspace when a backup runs.
    var provider: (() -> Data?)?
    private let file: URL
    private var pending: DispatchWorkItem?

    init(directory: URL) {
        file = directory.appendingPathComponent("backup-settings.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(BackupSettings.self, from: data) { settings = saved }
    }

    var folder: URL? { settings.folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var destinationName: String? { settings.folderPath.map(CloudFolders.name) }
    var isConfigured: Bool { settings.folderPath != nil }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    func setFolder(_ url: URL?) {
        settings.folderPath = url?.path
        settings.lastError = nil
        if url == nil { settings.lastBackupAt = nil }
        persist()
        if url != nil { backupNow() }
    }

    func setAutomatic(_ on: Bool) { settings.automatic = on; persist() }

    /// Called after every saved change. Changes are coalesced so a burst of edits makes one backup.
    func noteChange() {
        guard settings.automatic, isConfigured else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.backupNow() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    /// Runs any scheduled backup immediately (used when quitting).
    func flush() {
        guard let pending, !pending.isCancelled else { return }
        pending.cancel()
        self.pending = nil
        backupNow()
    }

    @discardableResult
    func backupNow() -> Bool {
        pending?.cancel(); pending = nil
        guard let folder else { return false }
        guard let data = provider?() else { settings.lastError = "The workspace could not be read."; persist(); return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try BackupWriter.write(data, into: folder, keep: settings.keep)
            settings.lastBackupAt = Date()
            settings.lastError = nil
            persist()
            return true
        } catch {
            settings.lastError = "Couldn't write to \(CloudFolders.name(for: folder.path)): \(error.localizedDescription)"
            persist()
            return false
        }
    }

    func backups() -> [BackupFile] { folder.map(BackupWriter.list) ?? [] }
}
