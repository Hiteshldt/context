import SwiftUI

/// Project links shown in the ⚙ menu. Each item is hidden while its URL is nil.
enum AppLinks {
    static let repository = URL(string: "https://github.com/Hiteshldt/context")
    static let donate = URL(string: "https://ko-fi.com/hiteshgupta")
}

extension Notification.Name {
    static let contextNewProject = Notification.Name("ContextNewProject")
    static let contextNewLink = Notification.Name("ContextNewLink")
    static let contextShowLauncher = Notification.Name("ContextShowLauncher")
    static let contextShowBackup = Notification.Name("ContextShowBackup")
    /// Carries a `ProjectTab` to show in the current project.
    static let contextShowTab = Notification.Name("ContextShowTab")
    /// Carries a `LauncherTarget` chosen outside the main window (the menu bar).
    static let contextOpenTarget = Notification.Name("ContextOpenTarget")
    /// Carries a map box's UUID: show it on its map and select it.
    static let contextShowBox = Notification.Name("ContextShowBox")
    /// Carries a map box's UUID from outside the window (a link in Apple Reminders): open its project, then show it.
    static let contextOpenBox = Notification.Name("ContextOpenBox")
    static let contextGoBack = Notification.Name("ContextGoBack")
    static let contextGoForward = Notification.Name("ContextGoForward")
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var backup: BackupManager
    @ObservedObject private var reminders = RemindersService.shared
    @State private var route: Route
    @State private var sheet: SheetRoute?
    @State private var showLauncher: Bool
    @State private var history = NavigationHistory<Route>()
    /// Set while going back or forward, so that step isn't recorded as a new visit.
    @State private var traversing = false
    @State private var gestures = WindowGestures()

    init(initialRoute: Route = .home, showLauncher: Bool = false) {
        _route = State(initialValue: initialRoute)
        _showLauncher = State(initialValue: showLauncher)
    }

    var tint: Color {
        if case .project(let id) = route, let project = store.project(id) { return Theme.color(project.color) }
        return Theme.accent
    }

    var body: some View {
        withHistory(layout)
    }

    /// Back and forward: remembers each page left, and follows the Go menu, trackpad swipes, and mouse side buttons.
    func withHistory<V: View>(_ content: V) -> some View {
        content
            .onChange(of: route) { old, _ in
                if traversing { traversing = false } else { history.leave(old) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .contextGoBack)) { _ in goBack() }
            .onReceive(NotificationCenter.default.publisher(for: .contextGoForward)) { _ in goForward() }
            .onReceive(NotificationCenter.default.publisher(for: .contextOpenBox)) { note in
                guard let box = note.object as? UUID,
                      let map = store.workspace.diagrams.first(where: { $0.nodes.contains { $0.id == box } }) else { return }
                sheet = nil; showLauncher = false
                route = .project(map.projectID)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NotificationCenter.default.post(name: .contextShowBox, object: box) }
            }
            .onAppear {
                gestures.back = goBack
                gestures.forward = goForward
                gestures.install()
            }
            .onDisappear { gestures.remove() }
    }

    var layout: some View {
        HStack(spacing: 0) {
            SidebarView(route: $route, openLauncher: { showLauncher = true })
                .frame(width: 250)
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
        .alert("Context", isPresented: Binding(get: { store.error != nil || reminders.error != nil },
                                               set: { if !$0 { store.error = nil; reminders.error = nil } })) {
            Button("OK") { store.error = nil; reminders.error = nil }
        } message: { Text(store.error ?? reminders.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .contextShowHome)) { _ in route = .home }
        .onReceive(NotificationCenter.default.publisher(for: .contextNewProject)) { _ in sheet = .project(Project(name: "")) }
        .onReceive(NotificationCenter.default.publisher(for: .contextNewLink)) { _ in activate(.action(.newLink), alternate: false) }
        .onReceive(NotificationCenter.default.publisher(for: .contextShowLauncher)) { _ in sheet = nil; showLauncher = true }
        .onReceive(NotificationCenter.default.publisher(for: .contextShowBackup)) { _ in sheet = .backup }
        .onReceive(NotificationCenter.default.publisher(for: .contextShowTab)) { note in
            guard let tab = note.object as? ProjectTab, let id = currentProjectID else { return }
            store.lastSection[id] = tab
            route = .project(id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .contextOpenTarget)) { note in
            if let target = note.object as? LauncherTarget { activate(target, alternate: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshClock(); reminders.reload()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            store.refreshClock(); reminders.reload()
        }
        .onAppear { reminders.track(store.workspace.projects.compactMap(\.remindersListID)) }
        .onChange(of: store.workspace.projects.compactMap(\.remindersListID)) { _, ids in reminders.track(ids) }
        .onChange(of: store.workspace.projects.map(\.id)) { _, ids in
            if case .project(let id) = route, !ids.contains(id) { route = .home }
        }
    }

    func sheetTint(_ item: SheetRoute) -> Color {
        switch item {
        case .project(let p): return Theme.color(p.color)
        case .entry(let e): return store.project(e.projectID).map { Theme.color($0.color) } ?? tint
        case .backup, .agents: return tint
        }
    }

    func goBack() {
        guard sheet == nil, !showLauncher, let page = history.goBack(from: route, exists: exists) else { return }
        traversing = true
        route = page
    }

    func goForward() {
        guard sheet == nil, !showLauncher, let page = history.goForward(from: route, exists: exists) else { return }
        traversing = true
        route = page
    }

    func exists(_ page: Route) -> Bool {
        if case .project(let id) = page { return store.project(id) != nil }
        return true
    }

    /// The project new items should go to: the one on screen, else the most recently used.
    var currentProjectID: UUID? {
        if case .project(let id) = route { return id }
        return store.workspace.projects.sorted { ($0.lastOpenedAt ?? $0.updatedAt) > ($1.lastOpenedAt ?? $1.updatedAt) }.first?.id
    }

    func activate(_ target: LauncherTarget, alternate: Bool) {
        switch target {
        case .project(let id): route = .project(id)
        case .entry(let id):
            guard let entry = store.entry(id) else { return }
            if alternate || webURL(entry.url) == nil {
                store.lastSection[entry.projectID] = .map
                route = .project(entry.projectID)
                sheet = .entry(entry)
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
            case .newLink:
                if let id = currentProjectID { sheet = .entry(Entry(projectID: id, kind: .link)) } else { sheet = .project(Project(name: "")) }
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
            case .project(let id):
                if let project = store.project(id) { ProjectView(project: project).id(id) } else { HomeView(openLauncher: { showLauncher = true }) }
            }
        }
    }

    @ViewBuilder func sheetContent(_ route: SheetRoute) -> some View {
        switch route {
        case .project(let project): ProjectEditor(project: project, created: { self.route = .project($0) })
        case .entry(let entry): EntryEditor(entry: entry)
        case .backup: BackupView()
        case .agents: AgentAccessView()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var backup: BackupManager
    @Environment(\.present) var present
    @ObservedObject private var reminders = RemindersService.shared
    @Binding var route: Route
    let openLauncher: () -> Void

    var projects: [Project] {
        store.workspace.projects.sorted { a, b in
            if (a.status == .done) != (b.status == .done) { return b.status == .done }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window's traffic lights.
            Color.clear.frame(height: 46)

            Button(action: openLauncher) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                    Text("Search").font(T.small)
                    Spacer()
                    KeyHint(keys: "⌘K")
                }
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 10)
            .help("Find and open any link or project (⌘K)")

            SidebarRow(title: "Home", selected: route == .home, action: { route = .home }) {
                Image(systemName: "house.fill").font(.system(size: 12.5)).foregroundStyle(route == .home ? Theme.accent : Theme.ink2)
            }.padding(.horizontal, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Eyebrow(text: "Projects")
                        Spacer()
                        IconButton(icon: "plus", help: "New project (⇧⌘N)", size: 22) { present(.project(Project(name: ""))) }
                    }.padding(.leading, 10).padding(.trailing, 4).padding(.top, 16).padding(.bottom, 4)

                    if projects.isEmpty {
                        Text("No projects yet").font(T.small).foregroundStyle(Theme.ink3).padding(.horizontal, 10).padding(.vertical, 6)
                    }
                    ForEach(projects) { projectRow($0) }
                }.padding(.horizontal, 8).padding(.bottom, 12)
            }

            Rectangle().fill(Theme.border).frame(height: 1)
            SidebarFooter()
        }
        .background(Theme.sidebar)
    }

    func projectRow(_ project: Project) -> some View {
        SidebarRow(title: project.name, badge: reminders.attentionCount(for: project, now: store.clock), selected: route == .project(project.id),
                   dimmed: project.status == .done, action: { route = .project(project.id) }) {
            ProjectIcon(project: project, size: 20)
        }
        .contextMenu {
            Button("Project Settings…") { present(.project(project)) }
            Button("Change Picture…") {
                if let data = ProjectImage.choose() { var updated = project; updated.image = data; store.saveQuietly(updated) }
            }
        }
    }
}

/// Backup status, the light/dark switch, support, and settings.
struct SidebarFooter: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var backup: BackupManager
    @Environment(\.present) var present
    @ObservedObject private var icons = SiteIconStore.shared
    @ObservedObject private var lock = AppLock.shared
    @ObservedObject private var reminders = RemindersService.shared
    @ObservedObject private var agents = AgentAccess.shared
    @AppStorage("globalShortcut") private var globalShortcut = true
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
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
            IconButton(icon: colorScheme == .dark ? "sun.max" : "moon", help: colorScheme == .dark ? "Switch to light mode" : "Switch to dark mode", size: 24) {
                appearance = (colorScheme == .dark ? AppAppearance.light : .dark).rawValue
            }
            if let url = AppLinks.donate {
                IconButton(icon: "heart.fill", help: "Support Context on Ko-fi", size: 24, tint: Theme.color("rose")) { NSWorkspace.shared.open(url) }
            }
            IconMenu(icon: "gearshape", help: "Settings", size: 26) {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.name).tag($0.rawValue) }
                }
                Divider()
                switch reminders.access {
                case .granted: Button("Open Apple Reminders") { reminders.openRemindersApp() }
                case .unknown: Button("Connect Apple Reminders…") { Task { await connectReminders() } }
                case .denied: Button("Allow Apple Reminders in System Settings…") { reminders.openPrivacySettings() }
                }
                Divider()
                Button("Backup & Restore…") { present(.backup) }
                Button("Show Local Data in Finder") { NSWorkspace.shared.open(store.disk.directory) }
                Divider()
                Toggle("AI Agent Access (MCP)", isOn: Binding(get: { agents.settings.enabled }, set: { agents.setEnabled($0) }))
                Button("AI Agents…") { present(.agents) }
                Divider()
                Toggle("Download Website Icons", isOn: Binding(get: { icons.enabled }, set: { icons.enabled = $0 }))
                Toggle("Global Shortcut ⌃⌥Space", isOn: $globalShortcut)
                Divider()
                Toggle("Require \(lock.method) to Open", isOn: Binding(get: { lock.enabled }, set: { on in Task { await lock.setEnabled(on) } }))
                if lock.enabled {
                    Picker("Lock When Away", selection: $lock.autoLock) {
                        ForEach(AppLock.AutoLock.allCases) { Text($0.name).tag($0) }
                    }
                    Button("Lock Now") { lock.lock() }
                }
                if AppLinks.repository != nil || AppLinks.donate != nil { Divider() }
                if let url = AppLinks.repository { Button { NSWorkspace.shared.open(url) } label: { Label("Context on GitHub", systemImage: "chevron.left.forwardslash.chevron.right") } }
                if let url = AppLinks.donate { Button { NSWorkspace.shared.open(url) } label: { Label("Support Context on Ko-fi", systemImage: "heart.fill") } }
            }
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 9)
    }

    func connectReminders() async {
        if await reminders.connect() { _ = reminders.importLocalTasks(from: store) }
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
