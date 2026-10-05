import SwiftUI
import UniformTypeIdentifiers

/// Backup, export, and restore. Cloud backup works by saving dated copies into a folder that a cloud app
/// (Google Drive, iCloud Drive, OneDrive, Dropbox) already keeps in sync — Context never signs in to anything.
struct BackupView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var backup: BackupManager
    @Environment(\.dismiss) var dismiss
    @State private var clouds: [CloudFolder] = []
    @State private var files: [BackupFile] = []
    @State private var showGuide = false

    var hasGoogleDrive: Bool { clouds.contains { $0.name.hasPrefix("Google Drive") } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "icloud.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36).background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Backup & Restore").font(T.h2).foregroundStyle(Theme.ink)
                    Text("Keep a copy of everything in your own cloud").font(T.small).foregroundStyle(Theme.ink2)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.primaryCompact).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
            Rectangle().fill(Theme.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    status
                    destination
                    if showGuide || (!hasGoogleDrive && !backup.isConfigured) { googleGuide }
                    restore
                    manual
                    Text("A backup holds your projects, links, notes, prompts, tasks, and maps. It does not hold the files inside connected folders (they stay where they are) or passwords saved in the Mac's Keychain.")
                        .font(T.caption).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
            }
        }
        .frame(width: 640, height: 700)
        .background(Theme.background)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    func refresh() {
        clouds = CloudFolders.detect()
        files = backup.backups()
    }

    // MARK: Status

    var status: some View {
        let ok = backup.isConfigured && backup.settings.lastError == nil
        let color = !backup.isConfigured ? Theme.ink3 : (ok ? Theme.success : Theme.overdue)
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: !backup.isConfigured ? "icloud.slash" : (ok ? "checkmark.icloud.fill" : "exclamationmark.icloud.fill"))
                .font(.system(size: 26)).foregroundStyle(color).frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle).font(T.h3).foregroundStyle(Theme.ink)
                Text(statusDetail).font(T.small).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                if backup.isConfigured {
                    HStack(spacing: 8) {
                        Button { backup.backupNow(); refresh() } label: { Label("Back Up Now", systemImage: "arrow.clockwise") }.buttonStyle(.primaryCompact)
                        if let folder = backup.folder {
                            Button("Show Backups in Finder") { NSWorkspace.shared.open(BackupWriter.directory(in: folder)) }.buttonStyle(.softCompact)
                        }
                    }.padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(color.opacity(0.25)))
    }

    var statusTitle: String {
        if !backup.isConfigured { return "Automatic backup is off" }
        if backup.settings.lastError != nil { return "The last backup didn't work" }
        guard let last = backup.settings.lastBackupAt else { return "Backup is ready" }
        return "Backed up \(last.formatted(.relative(presentation: .named)))"
    }
    var statusDetail: String {
        if !backup.isConfigured { return "Choose a folder below. Context will save a dated copy there whenever something changes, and keep the last \(backup.settings.keep) days." }
        if let error = backup.settings.lastError { return error + " Check that the folder still exists and that its cloud app is running." }
        return "Saving to \(backup.destinationName ?? "your folder") › Context Backups. A new copy is written shortly after you change anything, one file per day, keeping the last \(backup.settings.keep)."
    }

    // MARK: Destination

    var destination: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where to keep backups").font(T.h3).foregroundStyle(Theme.ink)
            VStack(spacing: 0) {
                ForEach(clouds) { cloud in
                    destinationRow(icon: cloud.icon, title: cloud.name, detail: cloud.detail, selected: backup.settings.folderPath == cloud.url.path) {
                        backup.setFolder(cloud.url); refresh()
                    }
                    Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 50)
                }
                if let path = backup.settings.folderPath, !clouds.contains(where: { $0.url.path == path }) {
                    destinationRow(icon: "folder.fill", title: URL(fileURLWithPath: path).lastPathComponent, detail: abbreviate(path), selected: true) {}
                    Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 50)
                }
                destinationRow(icon: "folder.badge.plus", title: "Choose another folder…", detail: "Any folder, including an external drive or a synced folder", selected: false) { chooseFolder() }
                if !hasGoogleDrive {
                    Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 50)
                    destinationRow(icon: "questionmark.circle", title: "How do I back up to Google Drive?", detail: "A one-time setup, about two minutes", selected: false) { withAnimation { showGuide = true } }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
            if backup.isConfigured {
                HStack {
                    Toggle("Back up automatically", isOn: Binding(get: { backup.settings.automatic }, set: { backup.setAutomatic($0) })).font(T.small)
                    Spacer()
                    Button("Turn Off Backup") { backup.setFolder(nil); refresh() }.buttonStyle(.plain).font(T.small).foregroundStyle(Theme.overdue)
                }
            }
        }
    }

    func destinationRow(icon: String, title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(selected ? Theme.success : Theme.ink2).frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(T.bodyMedium).foregroundStyle(Theme.ink)
                    Text(detail).font(T.caption).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .hoverRow(radius: 12)
        }.buttonStyle(.plain)
    }

    func abbreviate(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Back Up Here"
        panel.message = "Choose where Context should keep its backups. Pick a folder inside Google Drive, iCloud Drive, OneDrive, or Dropbox to have them in the cloud."
        if panel.runModal() == .OK, let url = panel.url { backup.setFolder(url); refresh() }
    }

    // MARK: Google Drive guide

    var googleGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Back up to Google Drive", systemImage: "externaldrive.badge.icloud").font(T.h3).foregroundStyle(Theme.ink)
                Spacer()
                if hasGoogleDrive { Pill(text: "Detected", icon: "checkmark", color: Theme.success) }
            }
            Text("Context doesn't sign in to Google. Instead, Google's own Drive app keeps a folder on your Mac in sync, and Context saves its backups into that folder.")
                .font(T.small).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            guideStep(1, "Install Google Drive for desktop", "It's Google's free Mac app.")
            guideStep(2, "Open it and sign in with your Google account", "This happens in Google's app, once. A “Google Drive” location appears in Finder.")
            guideStep(3, "Come back here", "Google Drive shows up in the list above. Click it, and backups start.")
            HStack {
                Button { if let url = URL(string: "https://www.google.com/drive/download/") { NSWorkspace.shared.open(url) } } label: { Label("Get Google Drive for Desktop", systemImage: "arrow.down.circle") }
                    .buttonStyle(.primaryCompact)
                Button("Check Again") { refresh() }.buttonStyle(.softCompact)
            }
            Text("Don't want to install anything? iCloud Drive is already on this Mac — choose it above and you're done.")
                .font(T.caption).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }

    func guideStep(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text("\(number)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white).frame(width: 22, height: 22).background(Theme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(T.bodyMedium).foregroundStyle(Theme.ink)
                Text(detail).font(T.small).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Restore and manual copies

    @ViewBuilder var restore: some View {
        if backup.isConfigured {
            VStack(alignment: .leading, spacing: 10) {
                Text("Restore from a backup").font(T.h3).foregroundStyle(Theme.ink)
                if files.isEmpty {
                    Text("No backups in this folder yet.").font(T.small).foregroundStyle(Theme.ink2)
                } else {
                    VStack(spacing: 0) {
                        ForEach(files.prefix(8)) { file in
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.ink2).frame(width: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.date.formatted(date: .complete, time: .omitted)).font(T.bodyMedium).foregroundStyle(Theme.ink)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).font(T.caption).foregroundStyle(Theme.ink2)
                                }
                                Spacer()
                                Button("Restore…") { if store.restore(from: file.url) { dismiss() } }.buttonStyle(.softCompact)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            if file.id != files.prefix(8).last?.id { Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 50) }
                        }
                    }
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
                    if files.count > 8 { Text("\(files.count - 8) older backups are in the folder.").font(T.caption).foregroundStyle(Theme.ink3) }
                }
            }
        }
    }

    var manual: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export and import").font(T.h3).foregroundStyle(Theme.ink)
            Text("Save a single backup file anywhere — to email yourself, put on a USB drive, or move to another Mac — and load one back in.")
                .font(T.small).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { store.exportBackup() } label: { Label("Export a Backup File…", systemImage: "square.and.arrow.up") }.buttonStyle(.soft)
                Button { store.restoreBackup(); if !store.loadFailed { refresh() } } label: { Label("Import a Backup File…", systemImage: "square.and.arrow.down") }.buttonStyle(.soft)
            }
        }
    }
}
