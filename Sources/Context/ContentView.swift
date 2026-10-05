import SwiftUI

/// Project links shown in the ⚙ menu. Each item is hidden while its URL is nil.
enum AppLinks {
    static let repository = URL(string: "https://github.com/Hiteshldt/context")
    static let donate = URL(string: "https://ko-fi.com/hiteshgupta")
}

extension Notification.Name {
    static let contextNewProject = Notification.Name("ContextNewProject")
    static let contextNewTask = Notification.Name("ContextNewTask")
    static let contextNewClient = Notification.Name("ContextNewClient")
    static let contextNewNote = Notification.Name("ContextNewNote")
    static let contextShowLauncher = Notification.Name("ContextShowLauncher")
    static let contextShowBackup = Notification.Name("ContextShowBackup")
    /// Carries a `LauncherTarget` chosen outside the main window (the menu bar).
    static let contextOpenTarget = Notification.Name("ContextOpenTarget")
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var backup: BackupManager
    @State private var route: Route
    @State private var sheet: SheetRoute?
    @State private var showLauncher: Bool

    init(initialRoute: Route = .home, showLauncher: Bool = false) {
        _route = State(initialValue: initialRoute)
        _showLauncher = State(initialValue: showLauncher)
    }

    var tint: Color {
        if case .project(let id) = route, let project = store.project(id) { return Theme.color(project.color) }
        return Theme.accent
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(route: $route, openLauncher: { showLauncher = true })
                .frame(width: 240)
            Rectangle().fill(Theme.border).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .top) { WindowDragArea().frame(height: 26).padding(.leading, 80) }
        .overlay {
            if showLauncher {
                LauncherOverlay(onActivate: { target, alternate in showLauncher = false; activate(target, alternate: alternate) },
                                onClose: { showLauncher = false })
            }
        }
        .animation(.easeOut(duration: 0.12), value: showLauncher)
        .environment(\.pageTint, tint)
        .tint(tint)
        .environment(\.present, PresentAction { sheet = $0 })
        .environment(\.navigate, NavigateAction { route = $0 })
        .sheet(item: $sheet) { item in
            sheetContent(item)
                .environmentObject(store)
                .environmentObject(backup)
                .environment(\.pageTint, sheetTint(item))
                .tint(sheetTint(item))
                .environment(\.present, PresentAction { next in sheet = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { sheet = next } })
                .environment(\.navigate, NavigateAction { route = $0; sheet = nil })
        }
        .alert("Context", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .contextShowHome)) { _ in route = .home }
        .onReceive(NotificationCenter.default.publisher(for: .contextNewProject)) { _ in sheet = .project(Project(name: "")) }
        .onReceive(NotificationCenter.default.publisher(for: .contextNewClient)) { _ in sheet = .client(Client(name: "")) }
        .onReceive(NotificationCenter.default.publisher(for: .contextNewTask)) { _ in activate(.action(.newTask), alternate: false) }
        .onReceive(NotificationCenter.default.publisher(for: .contextNewNote)) { _ in activate(.action(.newNote), alternate: false) }
        .onReceive(NotificationCenter.default.publisher(for: .contextShowLauncher)) { _ in sheet = nil; showLauncher = true }
        .onReceive(NotificationCenter.default.publisher(for: .contextShowBackup)) { _ in sheet = .backup }
        .onReceive(NotificationCenter.default.publisher(for: .contextOpenTarget)) { note in
            if let target = note.object as? LauncherTarget { activate(target, alternate: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshClock(); Task { await store.syncReminders() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            store.refreshClock(); Task { await store.syncReminders() }
        }
        .onChange(of: store.workspace.projects.map(\.id)) { _, ids in
            if case .project(let id) = route, !ids.contains(id) { route = .home }
        }
        .onChange(of: store.workspace.clients.map(\.id)) { _, ids in
            if case .client(let id) = route, !ids.contains(id) { route = .home }
        }
    }

    func sheetTint(_ item: SheetRoute) -> Color {
        let projectID: UUID?
        switch item {
        case .project(let p): return Theme.color(p.color)
        case .entry(let e): projectID = e.projectID
        case .task(let t): projectID = t.projectID
        case .content(let c): projectID = c.projectID
        default: projectID = nil
        }
        return projectID.flatMap(store.project).map { Theme.color($0.color) } ?? tint
    }

    /// The project new items should go to: the one on screen, else the most recently used.
    var currentProjectID: UUID? {
        if case .project(let id) = route { return id }
        if case .client(let id) = route, let first = store.projects(for: id).first { return first.id }
        return store.workspace.projects.sorted { ($0.lastOpenedAt ?? $0.updatedAt) > ($1.lastOpenedAt ?? $1.updatedAt) }.first?.id
    }

    func activate(_ target: LauncherTarget, alternate: Bool) {
        switch target {
        case .project(let id): route = .project(id)
        case .client(let id): route = .client(id)
        case .task(let id):
            if let task = store.workspace.tasks.first(where: { $0.id == id }) { sheet = .task(task) }
        case .entry(let id):
            guard let entry = store.entry(id) else { return }
            if entry.kind == .note || entry.kind == .prompt {
                store.selectedNote[entry.projectID] = entry.id
                store.lastSection[entry.projectID] = .notes
                route = .project(entry.projectID)
            } else if alternate || webURL(entry.url) == nil {
                store.lastSection[entry.projectID] = .links
                route = .project(entry.projectID)
                if webURL(entry.url) == nil { sheet = .entry(entry) }
            } else {
                store.open(entry)
            }
        case .action(let action):
            switch action {
            case .goHome: route = .home
            case .newProject: sheet = .project(Project(name: ""))
            case .backupSettings: sheet = .backup
            case .backupNow:
                if backup.isConfigured { if !backup.backupNow() { sheet = .backup } } else { sheet = .backup }
            case .newTask:
                if let id = currentProjectID { sheet = .task(WorkTask(projectID: id)) } else { sheet = .project(Project(name: "")) }
            case .newLink:
                if let id = currentProjectID { sheet = .entry(Entry(projectID: id, kind: .link)) } else { sheet = .project(Project(name: "")) }
            case .newNote:
                guard let id = currentProjectID else { sheet = .project(Project(name: "")); return }
                let note = Entry(projectID: id, kind: .note, title: "")
                if store.save(note) {
                    store.selectedNote[id] = note.id
                    store.lastSection[id] = .notes
                    route = .project(id)
                }
            }
        }
    }

    @ViewBuilder var detail: some View {
        if store.loadFailed {
            VStack(spacing: 14) {
                EmptyState(icon: "externaldrive.badge.exclamationmark", title: "Your data needs attention",
                           message: "The workspace file could not be read. It has been preserved, and editing is disabled so nothing overwrites it. Restore a backup, or inspect the local data folder.")
                HStack {
                    Button("Restore a Backup…") { sheet = .backup }.buttonStyle(.primary)
                    Button("Show Data in Finder") { NSWorkspace.shared.open(store.disk.directory) }.buttonStyle(.soft)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch route {
            case .home: HomeView(openLauncher: { showLauncher = true })
            case .tasks: TasksView()
            case .client(let id):
                if let client = store.client(id) { ClientView(client: client).id(id) } else { HomeView(openLauncher: { showLauncher = true }) }
            case .project(let id):
                if let project = store.project(id) { ProjectView(project: project).id(id) } else { HomeView(openLauncher: { showLauncher = true }) }
            }
        }
    }

    @ViewBuilder func sheetContent(_ route: SheetRoute) -> some View {
        switch route {
        case .project(let project): ProjectEditor(project: project, created: { self.route = .project($0) })
        case .client(let client): ClientEditor(client: client, created: { self.route = .client($0) })
        case .entry(let entry): EntryEditor(entry: entry)
        case .task(let task): TaskEditor(task: task)
        case .content(let item): ContentItemEditor(item: item)
        case .quickLook(let url): QuickLookSheet(url: url)
        case .backup: BackupView()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var backup: BackupManager
    @Environment(\.present) var present
    @Binding var route: Route
    let openLauncher: () -> Void
    @ObservedObject private var icons = SiteIconStore.shared
    @AppStorage("globalShortcut") private var globalShortcut = true

    var clients: [Client] { store.workspace.clients.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    var attention: Int { Buckets.needsAttention(store.workspace.tasks, now: store.clock).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window's traffic lights.
            Color.clear.frame(height: 46)

            Button(action: openLauncher) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                    Text("Search or jump to…").font(T.small)
                    Spacer()
                    KeyHint(keys: "⌘K")
                }
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 12)
            .help("Find and open any link, note, or project (⌘K)")

            VStack(spacing: 2) {
                SidebarRow(title: "Home", selected: route == .home, action: { route = .home }) {
                    Image(systemName: "house.fill").font(.system(size: 12.5)).foregroundStyle(route == .home ? Theme.accent : Theme.ink2)
                }
                SidebarRow(title: "Tasks", badge: attention, selected: route == .tasks, action: { route = .tasks }) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(route == .tasks ? Theme.accent : Theme.ink2)
                }
            }.padding(.horizontal, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Eyebrow(text: "Projects")
                        Spacer()
                        IconButton(icon: "plus", help: "New project (⌘N)", size: 22) { present(.project(Project(name: ""))) }
                    }.padding(.leading, 10).padding(.trailing, 4).padding(.top, 18).padding(.bottom, 4)

                    if store.workspace.projects.isEmpty {
                        Text("No projects yet").font(T.small).foregroundStyle(Theme.ink3).padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    ForEach(sorted(store.personalProjects)) { projectRow($0) }

                    ForEach(clients) { client in
                        SidebarRow(title: client.name, selected: route == .client(client.id), action: { route = .client(client.id) }) {
                            Image(systemName: "building.2.fill").font(.system(size: 11)).foregroundStyle(Theme.ink2)
                        }.padding(.top, 10)
                        ForEach(sorted(store.projects(for: client.id))) { projectRow($0).padding(.leading, 12) }
                    }
                }.padding(.horizontal, 8).padding(.bottom, 12)
            }

            Rectangle().fill(Theme.border).frame(height: 1)
            footer
        }
        .background(Theme.sidebar)
    }

    func sorted(_ projects: [Project]) -> [Project] {
        projects.sorted { a, b in
            if (a.status == .done) != (b.status == .done) { return b.status == .done }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func projectRow(_ project: Project) -> some View {
        let count = Buckets.needsAttention(store.workspace.tasks.filter { $0.projectID == project.id }, now: store.clock).count
        return SidebarRow(title: project.name, badge: count, selected: route == .project(project.id), dimmed: project.status == .done,
                          action: { route = .project(project.id) }) {
            ProjectIcon(project: project, size: 20)
        }
        .contextMenu {
            Button("Project Settings…") { present(.project(project)) }
            Button("New Note") { NotificationCenter.default.post(name: .contextNewNote, object: nil) }
            Button("New Task…") { present(.task(WorkTask(projectID: project.id))) }
        }
    }

    var footer: some View {
        HStack(spacing: 8) {
            Button { present(.backup) } label: {
                HStack(spacing: 9) {
                    Image(systemName: backupIcon).font(.system(size: 15)).foregroundStyle(backupColor).frame(width: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(backupTitle).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(backupDetail).font(.system(size: 11)).foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Backup, export, and restore")
            if let url = AppLinks.donate {
                IconButton(icon: "heart.fill", help: "Support Context on Ko-fi", size: 26, tint: Theme.color("rose")) { NSWorkspace.shared.open(url) }
            }
            Menu {
                Text(store.notificationStatus)
                if !store.notificationsAllowed { Button("Enable Notifications…") { Task { await store.enableNotifications() } } }
                Divider()
                Button("Backup & Restore…") { present(.backup) }
                Button("Show Local Data in Finder") { NSWorkspace.shared.open(store.disk.directory) }
                Divider()
                Toggle("Download Website Icons", isOn: Binding(get: { icons.enabled }, set: { icons.enabled = $0 }))
                Toggle("Global Shortcut ⌃⌥Space", isOn: $globalShortcut)
                if AppLinks.repository != nil || AppLinks.donate != nil { Divider() }
                if let url = AppLinks.repository { Button { NSWorkspace.shared.open(url) } label: { Label("Context on GitHub", systemImage: "chevron.left.forwardslash.chevron.right") } }
                if let url = AppLinks.donate { Button { NSWorkspace.shared.open(url) } label: { Label("Support Context on Ko-fi", systemImage: "heart.fill") } }
            } label: { Image(systemName: "gearshape").foregroundStyle(Theme.ink2) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Settings")
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    var backupIcon: String {
        if !backup.isConfigured { return "icloud.slash" }
        return backup.settings.lastError == nil ? "checkmark.icloud.fill" : "exclamationmark.icloud.fill"
    }
    var backupColor: Color {
        if !backup.isConfigured { return Theme.ink3 }
        return backup.settings.lastError == nil ? Theme.success : Theme.overdue
    }
    var backupTitle: String {
        if !backup.isConfigured { return "Set up backup" }
        if backup.settings.lastError != nil { return "Backup needs attention" }
        guard let last = backup.settings.lastBackupAt else { return "Backup ready" }
        let minutes = Int(store.clock.timeIntervalSince(last) / 60)
        if minutes < 2 { return "Backed up just now" }
        if minutes < 60 { return "Backed up \(minutes) min ago" }
        if minutes < 60 * 24 { return "Backed up \(minutes / 60) h ago" }
        return "Backed up \(DueText.ago(last, now: store.clock))"
    }
    var backupDetail: String {
        backup.isConfigured ? (backup.destinationName ?? "") : "Keep a copy in your cloud"
    }
}

struct SidebarRow<Icon: View>: View {
    let title: String
    var badge = 0
    let selected: Bool
    var dimmed = false
    let action: () -> Void
    @ViewBuilder var icon: Icon
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                icon.frame(width: 20, height: 20)
                Text(title).font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(dimmed ? Theme.ink3 : Theme.ink).lineLimit(1)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)").font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1.5).background(Theme.overdue, in: Capsule())
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6.5)
            .background(selected ? Theme.card : (hovering ? Theme.hover : .clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(selected ? 0.07 : 0), radius: 2.5, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
