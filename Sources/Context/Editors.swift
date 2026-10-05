import SwiftUI
import UniformTypeIdentifiers

/// Shared sheet chrome: a title bar, scrollable content, and a footer with actions.
struct EditorSheet<Content: View, Footer: View>: View {
    @Environment(\.pageTint) var tint
    let icon: String
    let title: String
    var width: CGFloat = 600
    var height: CGFloat = 640
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 34, height: 34).background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title).font(T.h2).foregroundStyle(Theme.ink)
                Spacer()
            }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 6)
            content
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 8) { footer }.padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: width, height: height)
        .background(Theme.background)
    }
}

// MARK: - Project

struct ProjectEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State var project: Project
    var created: ((UUID) -> Void)? = nil
    @State private var deleteConfirm = false
    @State private var newClientName = ""
    @State private var addingClient = false
    var existing: Bool { store.project(project.id) != nil }
    var trimmedName: String { project.name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        EditorSheet(icon: existing ? "slider.horizontal.3" : "plus.square.on.square", title: existing ? "Project settings" : "New project", height: 700) {
            Form {
                Section {
                    TextField("Name", text: $project.name, prompt: Text("e.g. Ayuvam"))
                    TextField("Description", text: $project.summary, prompt: Text("What is this project?"), axis: .vertical).lineLimit(2...4)
                    Picker("Type", selection: $project.kind) { ForEach(ProjectKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Picker("Status", selection: $project.status) { ForEach(ProjectStatus.allCases) { Text($0.rawValue).tag($0) } }
                    if addingClient {
                        HStack {
                            TextField("New client name", text: $newClientName)
                            Button("Add") {
                                let name = newClientName.trimmingCharacters(in: .whitespaces)
                                guard !name.isEmpty else { return }
                                let client = Client(name: name)
                                if store.save(client) { project.clientID = client.id; addingClient = false; newClientName = "" }
                            }.disabled(newClientName.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button("Cancel") { addingClient = false }
                        }
                    } else {
                        Picker("Client", selection: $project.clientID) {
                            Text("None (personal)").tag(UUID?.none)
                            ForEach(store.workspace.clients) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Button("New client…") { addingClient = true }.buttonStyle(.link)
                    }
                    LabeledContent("Color") {
                        HStack(spacing: 8) {
                            ForEach(Theme.projectColors, id: \.id) { option in
                                Button { project.color = option.id } label: {
                                    Circle().fill(Theme.color(option.id)).frame(width: 18, height: 18)
                                        .overlay(Circle().strokeBorder(.primary.opacity(project.color == option.id ? 0.8 : 0), lineWidth: 2).padding(-3))
                                }.buttonStyle(.plain).help(option.name)
                            }
                        }
                    }
                }
                Section {
                    ForEach(Array(project.sections.enumerated()), id: \.element.section) { index, config in
                        HStack(spacing: 10) {
                            Toggle("", isOn: $project.sections[index].enabled).labelsHidden().disabled(config.section == .overview)
                            Image(systemName: config.section.icon).foregroundStyle(config.enabled ? Theme.accent : .secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                TextField("", text: $project.sections[index].title, prompt: Text(config.section.rawValue)).textFieldStyle(.plain)
                                Text(config.section.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(index <= 1)
                            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(index == 0 || index == project.sections.count - 1)
                        }
                    }
                } header: {
                    Text("Sections")
                } footer: {
                    Text("Turn sections on or off, rename them, and change their order. Hiding a section keeps its content.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        } footer: {
            if existing { Button("Delete Project…", role: .destructive) { deleteConfirm = true }.buttonStyle(.plain).font(T.small).foregroundStyle(Theme.overdue) }
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.soft).keyboardShortcut(.cancelAction)
            Button(existing ? "Save" : "Create Project") {
                project.name = trimmedName
                if store.save(project) { created?(project.id); dismiss() }
            }.keyboardShortcut(.defaultAction).buttonStyle(.primary).disabled(trimmedName.isEmpty)
        }
        .confirmationDialog("Delete \(project.name)?", isPresented: $deleteConfirm) {
            Button("Delete Project", role: .destructive) { store.deleteProject(project.id); dismiss() }
        } message: { Text(store.deletionSummary(for: project.id)) }
    }

    func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard target >= 1, target < project.sections.count else { return }
        project.sections.swapAt(index, target)
    }
}

// MARK: - Client

struct ClientEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State var client: Client
    var created: ((UUID) -> Void)? = nil
    @State private var deleteConfirm = false
    var existing: Bool { store.client(client.id) != nil }

    var body: some View {
        EditorSheet(icon: "building.2", title: existing ? "Client" : "New client", height: 600) {
            Form {
                Section {
                    TextField("Name", text: $client.name, prompt: Text("Company or person"))
                    TextField("Contact", text: $client.contactName, prompt: Text("Main contact"))
                    TextField("Email", text: $client.email)
                    TextField("Phone", text: $client.phone)
                    TextField("Website", text: $client.website, prompt: Text("https://…"))
                    if !client.website.isEmpty && webURL(client.website) == nil {
                        Text("Use a complete https:// address.").font(.caption).foregroundStyle(Theme.today)
                    }
                }
                Section("Shared context") {
                    TextEditor(text: $client.notes).font(.system(size: 13)).frame(minHeight: 140)
                    Text("Preferences, billing notes, key people — anything that applies across this client's projects. Markdown supported.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        } footer: {
            if existing { Button("Delete Client…", role: .destructive) { deleteConfirm = true }.buttonStyle(.plain).font(T.small).foregroundStyle(Theme.overdue) }
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.soft).keyboardShortcut(.cancelAction)
            Button(existing ? "Save" : "Create Client") {
                client.name = client.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if store.save(client) { created?(client.id); dismiss() }
            }.keyboardShortcut(.defaultAction).buttonStyle(.primary)
                .disabled(client.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .confirmationDialog("Delete \(client.name)?", isPresented: $deleteConfirm) {
            Button("Delete Client", role: .destructive) { store.deleteClient(client.id); dismiss() }
        } message: { Text("Its \(store.projects(for: client.id).count) projects are kept and become personal projects.") }
    }
}

// MARK: - Saved records

struct EntryEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State var entry: Entry
    @State private var preview = false
    @State private var deleteConfirm = false
    @State private var tagText = ""
    @State private var pendingSecrets: [UUID: String] = [:]
    @State private var newCredential = CredentialRef()
    @State private var newSecret = ""
    @State private var addingCredential = false

    var existing: Bool { store.entry(entry.id) != nil }
    var urlValid: Bool { entry.url.isEmpty || webURL(entry.url) != nil }
    var manageValid: Bool { entry.managementURL.isEmpty || webURL(entry.managementURL) != nil }
    var valid: Bool { !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && urlValid && manageValid }
    /// Any link can hold Keychain credentials (a "link" to a mail admin console needs a login too).
    var supportsCredentials: Bool { EntryKind.linkKinds.contains(entry.kind) || !entry.credentials.isEmpty }

    var categorySuggestions: [String] {
        switch entry.kind {
        case .service: return ["Hosting", "Database", "Domain & DNS", "Payments", "Email", "Analytics", "SEO", "Storage", "Auth", "CI/CD", "Monitoring", "Other"]
        case .social: return BrandCatalog.socialPlatforms.map(\.name)
        case .conversation: return ["ChatGPT", "Claude", "Gemini", "Perplexity", "Other"]
        case .repository: return ["GitHub", "GitLab", "Bitbucket"]
        case .document: return ["Google Docs", "Notion", "Figma", "PDF", "Spreadsheet"]
        default: return ["Website", "Reference", "Tool", "Inspiration", "Docs"]
        }
    }
    var categoryLabel: String {
        switch entry.kind {
        case .service: return "Type"
        case .social: return "Platform"
        case .conversation: return "Assistant"
        case .repository: return "Host"
        default: return "Type"
        }
    }

    var body: some View {
        EditorSheet(icon: entry.kind.icon, title: existing ? entry.kind.rawValue : "New \(entry.kind.rawValue.lowercased())", width: 660, height: 720) {
            Form {
                Section {
                    Picker("Type", selection: $entry.kind) {
                        ForEach(EntryKind.noteKinds.contains(entry.kind) ? EntryKind.noteKinds : EntryKind.linkKinds) { kind in
                            Label(kind.rawValue, systemImage: kind.icon).tag(kind)
                        }
                    }
                    TextField("Title", text: $entry.title, prompt: Text(titlePrompt))
                    if entry.kind.hasURL {
                        TextField(entry.kind.urlLabel, text: $entry.url, prompt: Text("https://…"))
                        if !urlValid { Text("Use a complete http:// or https:// URL without embedded credentials.").font(.caption).foregroundStyle(Theme.today) }
                    }
                    if entry.kind == .social {
                        TextField("Management URL", text: $entry.managementURL, prompt: Text("e.g. Business Suite or Creator Studio"))
                        if !manageValid { Text("Use a complete https:// URL.").font(.caption).foregroundStyle(Theme.today) }
                    }
                    if entry.kind != .note && entry.kind != .prompt {
                        HStack {
                            TextField(categoryLabel, text: $entry.category, prompt: Text(entry.kind == .social ? "Pick one or type any platform" : "optional"))
                            Menu {
                                ForEach(categorySuggestions, id: \.self) { suggestion in
                                    Button { entry.category = suggestion } label: {
                                        if let brand = BrandCatalog.named(suggestion) {
                                            Label { Text(suggestion) } icon: { Image(nsImage: BrandImages.image(brand)) }
                                        } else { Text(suggestion) }
                                    }
                                }
                            } label: { Image(systemName: "chevron.down") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                    }
                    if let brand = BrandCatalog.brand(for: entry) {
                        LabeledContent("Icon") {
                            HStack(spacing: 8) { BrandBadge(brand: brand, size: 22); Text(brand.name).foregroundStyle(.secondary) }
                        }
                    }
                    if [.service, .social, .repository, .link].contains(entry.kind) {
                        TextField("Account label", text: $entry.account, prompt: Text("e.g. studio@… or team account — not a password"))
                    }
                    if entry.kind == .service || entry.kind == .link {
                        Picker("Environment", selection: $entry.environment) {
                            Text("Not specified").tag("")
                            ForEach(["Production", "Staging", "Development", "Shared"], id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if entry.kind == .repository {
                        let folders = store.workspace.folders.filter { $0.projectID == entry.projectID }
                        Picker("Local checkout", selection: $entry.folderID) {
                            Text("None").tag(UUID?.none)
                            ForEach(folders) { Text($0.name).tag(Optional($0.id)) }
                        }
                        if folders.isEmpty { Text("Connect the checkout folder in Files to link it here. Context does not run Git commands.").font(.caption).foregroundStyle(.secondary) }
                    }
                    Toggle("Pin to project overview", isOn: $entry.pinned)
                }
                Section {
                    HStack {
                        Text(entry.kind.bodyLabel).font(.callout.weight(.medium))
                        Spacer()
                        if entry.kind != .prompt {
                            Picker("", selection: $preview) { Text("Write").tag(false); Text("Preview").tag(true) }.pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                    }
                    if preview && entry.kind != .prompt {
                        MarkdownDocumentView(source: entry.body.isEmpty ? "_Nothing yet._" : entry.body, baseSize: 14).frame(minHeight: 140, alignment: .topLeading)
                    } else {
                        TextEditor(text: $entry.body)
                            .font(.system(size: 13, design: entry.kind == .prompt ? .monospaced : .default))
                            .frame(minHeight: entry.kind == .note || entry.kind == .prompt ? 220 : 110)
                    }
                    if entry.kind == .conversation {
                        Text("Summarise what the conversation decided. The summary stays here even if the link stops working. Context never imports chat history.").font(.caption).foregroundStyle(.secondary)
                    }
                    if entry.kind == .prompt {
                        TextField("Usage notes", text: $entry.details, prompt: Text("When to use it, which model, what to paste in"), axis: .vertical).lineLimit(2...4)
                    }
                }
                Section("Tags & links") {
                    FlowLayout(spacing: 6) {
                        ForEach(entry.tags, id: \.self) { tag in
                            Button { entry.tags.removeAll { $0 == tag } } label: { Pill(text: tag + "  ×", icon: "tag", color: Theme.accent) }.buttonStyle(.plain).help("Remove tag")
                        }
                        TextField("Add tag", text: $tagText).textFieldStyle(.plain).frame(width: 110).onSubmit(addTag)
                    }
                    HStack {
                        RecordLinker(projectID: entry.projectID, excluding: entry.id, selection: $entry.relatedIDs)
                        Spacer()
                    }
                    if !entry.relatedIDs.isEmpty { RelatedChips(ids: entry.relatedIDs) }
                }
                if supportsCredentials { credentialsSection }
            }
            .formStyle(.grouped)
        } footer: {
            if existing { Button("Delete…", role: .destructive) { deleteConfirm = true }.buttonStyle(.plain).font(T.small).foregroundStyle(Theme.overdue) }
            if entry.kind == .prompt {
                Button("Copy Prompt") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.body, forType: .string) }.buttonStyle(.soft)
            }
            if let url = webURL(entry.url) {
                Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.soft).help("Open in your default browser")
            }
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.soft).keyboardShortcut(.cancelAction)
            Button("Save") { save() }.keyboardShortcut("s", modifiers: .command).buttonStyle(.primary).disabled(!valid)
        }
        .confirmationDialog("Delete \(entry.title.isEmpty ? "this record" : entry.title)?", isPresented: $deleteConfirm) {
            Button("Delete", role: .destructive) { store.deleteEntry(entry.id); dismiss() }
        } message: {
            Text(entry.credentials.isEmpty ? "This removes it from Context. Linked tasks and diagram nodes will show it as removed." : "This also deletes \(entry.credentials.count) stored secret(s) from the Keychain.")
        }
    }

    var titlePrompt: String {
        switch entry.kind {
        case .service: return "e.g. Vercel — production"
        case .repository: return "e.g. ayuvam-web"
        case .conversation: return "e.g. Pricing page copy"
        case .social: return "e.g. Ayuvam Instagram"
        case .prompt: return "e.g. Product description writer"
        default: return "Title"
        }
    }

    var credentialsSection: some View {
        Section {
            ForEach($entry.credentials) { $credential in
                CredentialRow(credential: $credential, pending: pendingSecrets[credential.id] != nil) {
                    entry.credentials.removeAll { $0.id == credential.id }
                    pendingSecrets[credential.id] = nil
                }
            }
            if addingCredential {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Label", text: $newCredential.label, prompt: Text("e.g. API key, Admin login"))
                        TextField("Username", text: $newCredential.username, prompt: Text("optional"))
                    }
                    SecureField("Secret", text: $newSecret, prompt: Text("Password, token, or key"))
                    HStack {
                        Spacer()
                        Button("Cancel") { addingCredential = false; newSecret = ""; newCredential = CredentialRef() }
                        Button("Add to Keychain on Save") {
                            pendingSecrets[newCredential.id] = newSecret
                            entry.credentials.append(newCredential)
                            newCredential = CredentialRef(); newSecret = ""; addingCredential = false
                        }.disabled(newCredential.label.trimmingCharacters(in: .whitespaces).isEmpty || newSecret.isEmpty)
                    }
                }
            } else {
                Button { addingCredential = true } label: { Label("Add credential", systemImage: "key") }
            }
        } header: {
            Label("Credentials", systemImage: "lock.shield")
        } footer: {
            Text("Secrets are stored in your macOS login Keychain, not in Context's data file. They are masked, excluded from search and backups, and revealing or copying one requires your Mac password or Touch ID. Copied secrets clear from the clipboard after 45 seconds.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    func addTag() {
        let tag = tagText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !tag.isEmpty && !entry.tags.contains(tag) { entry.tags.append(tag) }
        tagText = ""
    }

    func save() {
        addTag()
        entry.title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.url = entry.url.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.managementURL = entry.managementURL.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            for (id, secret) in pendingSecrets where entry.credentials.contains(where: { $0.id == id }) {
                try CredentialVault.store(secret, for: id)
            }
        } catch {
            store.error = "The secret could not be saved to the Keychain, so nothing was changed. \(error.localizedDescription)"
            return
        }
        pendingSecrets = [:]
        if store.save(entry) { dismiss() }
    }
}

struct CredentialRow: View {
    @EnvironmentObject var store: Store
    @Binding var credential: CredentialRef
    let pending: Bool
    let remove: () -> Void
    @State private var revealed: String?
    @State private var stored = true
    @State private var replacing = false
    @State private var replacement = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(credential.label).font(.callout.weight(.medium))
                    if !credential.username.isEmpty { Text(credential.username).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                Spacer()
                if pending {
                    Text("Saved to Keychain on Save").font(.caption).foregroundStyle(.secondary)
                } else if !stored {
                    Text("Not on this Mac").font(.caption).foregroundStyle(Theme.overdue).help("This secret isn't in this Mac's Keychain — for example after restoring a backup on another Mac. Replace it to store it again.")
                } else {
                    Text(revealed ?? "••••••••••").font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                        .frame(maxWidth: 180, alignment: .trailing)
                    Button(revealed == nil ? "Reveal" : "Hide") { revealed == nil ? reveal() : (revealed = nil) }.controlSize(.small)
                    Button("Copy") { copy() }.controlSize(.small)
                }
                Menu {
                    Button("Replace Secret…") { replacing = true }
                    Button("Remove", role: .destructive, action: remove)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if replacing {
                HStack {
                    SecureField("New secret", text: $replacement)
                    Button("Cancel") { replacing = false; replacement = "" }
                    Button("Store") {
                        do { try CredentialVault.store(replacement, for: credential.id); stored = true; revealed = nil }
                        catch { store.error = error.localizedDescription }
                        replacing = false; replacement = ""
                    }.disabled(replacement.isEmpty)
                }
            }
        }
        .task { if !pending { stored = CredentialVault.exists(credential.id) } }
        .onDisappear { revealed = nil }
    }

    func reveal() {
        Task {
            guard await CredentialVault.authenticate(reason: "reveal “\(credential.label)”") else { return }
            do {
                revealed = try CredentialVault.read(credential.id)
                // Re-mask automatically.
                try? await Task.sleep(for: .seconds(20))
                revealed = nil
            } catch { store.error = error.localizedDescription }
        }
    }

    func copy() {
        Task {
            guard await CredentialVault.authenticate(reason: "copy “\(credential.label)”") else { return }
            do { CredentialVault.copyTemporarily(try CredentialVault.read(credential.id)) }
            catch { store.error = error.localizedDescription }
        }
    }
}

// MARK: - Task

struct TaskEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State var task: WorkTask
    @State private var hasDue = false
    @State private var due = Date()
    @State private var reminderChoice = -1
    @State private var customNotify = Date()
    @State private var deleteConfirm = false

    static let leadOptions: [(Int, String)] = [(-1, "None"), (0, "At due time"), (10, "10 minutes before"), (30, "30 minutes before"), (60, "1 hour before"), (1440, "1 day before"), (-2, "At a specific time…")]
    var existing: Bool { store.workspace.tasks.contains { $0.id == task.id } }

    var body: some View {
        EditorSheet(icon: "checkmark.circle", title: existing ? "Task" : "New task", width: 620, height: 720) {
            Form {
                Section {
                    TextField("Title", text: $task.title, prompt: Text("What needs doing?"))
                    Picker("Project", selection: $task.projectID) { ForEach(store.workspace.projects) { Text($0.name).tag($0.id) } }
                    TextField("Details", text: $task.details, axis: .vertical).lineLimit(2...6)
                }
                Section("Schedule") {
                    Toggle("Due date", isOn: $hasDue.animation())
                    if hasDue {
                        DatePicker("Due", selection: $due)
                        Picker("Repeat", selection: $task.repeatRule.kind) { ForEach(RepeatRule.Kind.allCases) { Text($0.rawValue).tag($0) } }
                        repeatOptions
                    }
                }
                Section {
                    Picker("Notify me", selection: $reminderChoice) {
                        ForEach(Self.leadOptions.filter { hasDue || $0.0 < 0 }, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    if reminderChoice == -2 { DatePicker("Notification time", selection: $customNotify) }
                    if task.snoozedUntil != nil {
                        HStack {
                            Label("Snoozed until \(task.snoozedUntil!.formatted(date: .abbreviated, time: .shortened))", systemImage: "moon.zzz")
                            Spacer()
                            Button("Clear") { task.snoozedUntil = nil }
                        }
                    }
                } header: { Text("Reminder") } footer: {
                    Text(store.notificationsAllowed ? "Notifications use generic text, so task details never appear on the lock screen." : "Saving a reminder asks macOS for notification permission. Tasks stay visible in Context either way.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("More") {
                    TextField("Platform / destination", text: $task.platform, prompt: Text("optional, e.g. Instagram"))
                    HStack { RecordLinker(projectID: task.projectID, excluding: task.id, selection: $task.relatedIDs); Spacer() }
                    if !task.relatedIDs.isEmpty { RelatedChips(ids: task.relatedIDs) }
                    if !task.completionHistory.isEmpty {
                        LabeledContent("Completed") {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(task.completionHistory.count) time\(task.completionHistory.count == 1 ? "" : "s")")
                                ForEach(task.completionHistory.suffix(3).reversed(), id: \.self) { date in
                                    Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }.formStyle(.grouped)
        } footer: {
            if existing { Button("Delete…", role: .destructive) { deleteConfirm = true }.buttonStyle(.plain).font(T.small).foregroundStyle(Theme.overdue) }
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.soft).keyboardShortcut(.cancelAction)
            Button(existing ? "Save" : "Add Task") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.primary)
                .disabled(task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.project(task.projectID) == nil)
        }
        .onAppear(perform: load)
        .onChange(of: hasDue) { _, on in if !on && reminderChoice >= 0 { reminderChoice = -1 } }
        .onChange(of: task.repeatRule.kind) { _, kind in
            // Give each rule a sensible starting interval.
            switch kind {
            case .everyNDays: if task.repeatRule.interval < 2 { task.repeatRule.interval = 3 }
            case .afterCompletion: if task.repeatRule.interval < 1 { task.repeatRule.interval = 7 }
            case .daily, .weekly: task.repeatRule.interval = 1
            case .none: break
            }
        }
        .confirmationDialog("Delete this task?", isPresented: $deleteConfirm) {
            Button("Delete Task", role: .destructive) { store.deleteTask(task.id); dismiss() }
        } message: { Text(task.repeatRule.repeats ? "This deletes the whole recurring series and its history." : "This cannot be undone.") }
    }

    @ViewBuilder var repeatOptions: some View {
        switch task.repeatRule.kind {
        case .none: EmptyView()
        case .daily: extraTimes
        case .everyNDays:
            Stepper("Every \(task.repeatRule.interval) days", value: $task.repeatRule.interval, in: 2...365)
            extraTimes
        case .weekly:
            Stepper(task.repeatRule.interval == 1 ? "Every week" : "Every \(task.repeatRule.interval) weeks", value: $task.repeatRule.interval, in: 1...12)
            LabeledContent("On") {
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { day in
                        let on = weekdays.contains(day)
                        Button { toggleWeekday(day) } label: {
                            Text(Calendar.current.veryShortWeekdaySymbols[day - 1]).font(.system(size: 11, weight: .semibold))
                                .frame(width: 24, height: 24)
                                .foregroundStyle(on ? .white : .secondary)
                                .background(on ? Theme.accent : Color.primary.opacity(0.06), in: Circle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            extraTimes
        case .afterCompletion:
            Stepper("\(task.repeatRule.interval) day\(task.repeatRule.interval == 1 ? "" : "s") after I complete it", value: $task.repeatRule.interval, in: 1...365)
            Text("The next occurrence is scheduled from when you actually finish, at the same time of day.").font(.caption).foregroundStyle(.secondary)
        }
        if task.repeatRule.repeats && task.repeatRule.kind != .afterCompletion {
            let next = previewRule.upcoming(from: due, limit: 4)
            LabeledContent("Next") {
                Text(next.map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()) }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            Text("Completing marks only the current occurrence. Missed occurrences collapse into one pending item — no flood of reminders.").font(.caption).foregroundStyle(.secondary)
        }
    }

    var previewRule: RepeatRule {
        var rule = task.repeatRule
        if rule.kind == .weekly && rule.weekdays.isEmpty { rule.weekdays = [Calendar.current.component(.weekday, from: due)] }
        return rule
    }
    var weekdays: [Int] { task.repeatRule.weekdays.isEmpty ? [Calendar.current.component(.weekday, from: due)] : task.repeatRule.weekdays }
    func toggleWeekday(_ day: Int) {
        var days = weekdays
        if days.contains(day) { if days.count > 1 { days.removeAll { $0 == day } } } else { days.append(day) }
        task.repeatRule.weekdays = days.sorted()
    }

    @ViewBuilder var extraTimes: some View {
        ForEach(Array(task.repeatRule.extraTimes.enumerated()), id: \.offset) { index, minutes in
            HStack {
                DatePicker("Also at", selection: Binding(get: { time(minutes) }, set: { task.repeatRule.extraTimes[index] = self.minutes($0) }), displayedComponents: .hourAndMinute)
                Button { task.repeatRule.extraTimes.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
            }
        }
        Button { task.repeatRule.extraTimes.append(min(23 * 60, minutes(due) + 4 * 60)) } label: { Label("Add another time of day", systemImage: "plus") }
            .buttonStyle(.link)
    }

    func time(_ minutes: Int) -> Date { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date() }
    func minutes(_ date: Date) -> Int { let c = Calendar.current.dateComponents([.hour, .minute], from: date); return (c.hour ?? 0) * 60 + (c.minute ?? 0) }

    func load() {
        hasDue = task.due != nil
        let calendar = Calendar.current
        due = task.due ?? calendar.date(bySettingHour: 9, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: 1, to: Date())!)!
        if let lead = task.reminderLead { reminderChoice = Self.leadOptions.contains { $0.0 == lead } ? lead : 0 }
        else if let at = task.notifyAt { reminderChoice = -2; customNotify = at }
        else { reminderChoice = -1; customNotify = due }
    }

    func save() {
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        task.due = hasDue ? due : nil
        if !hasDue { task.repeatRule = RepeatRule() }
        if task.repeatRule.kind == .weekly && task.repeatRule.weekdays.isEmpty { task.repeatRule.weekdays = weekdays }
        if task.repeatRule.kind == .none || task.repeatRule.kind == .afterCompletion { task.repeatRule.extraTimes = [] }
        if task.repeatRule.kind == .daily { task.repeatRule.interval = 1 }
        switch reminderChoice {
        case -1: task.reminderLead = nil; task.notifyAt = nil
        case -2: task.reminderLead = nil; task.notifyAt = customNotify
        default: task.reminderLead = reminderChoice; task.notifyAt = nil
        }
        if store.save(task) {
            if task.reminderDate != nil && !store.notificationsAllowed { Task { await store.enableNotifications() } }
            dismiss()
        }
    }
}

// MARK: - Planned post

struct ContentItemEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @Environment(\.present) var present
    @State var item: ContentItem
    @State private var hasDue = false
    @State private var due = Date()
    @State private var customPlatform = ""
    @State private var deleteConfirm = false
    var existing: Bool { store.workspace.contentItems.contains { $0.id == item.id } }

    var platforms: [String] {
        let accounts = store.workspace.entries.filter { $0.projectID == item.projectID && $0.kind == .social }.map { $0.category.isEmpty ? $0.title : $0.category }
        var result: [String] = []
        for p in accounts + ContentItem.platforms + item.targets.map(\.platform) where !p.isEmpty && !result.contains(where: { $0.caseInsensitiveCompare(p) == .orderedSame }) { result.append(p) }
        return result
    }

    var body: some View {
        EditorSheet(icon: "paperplane", title: existing ? "Planned post" : "Plan a post", width: 620, height: 680) {
            Form {
                Section {
                    TextField("Title", text: $item.title, prompt: Text("e.g. Monsoon launch carousel"))
                    Toggle("Publish by", isOn: $hasDue)
                    if hasDue { DatePicker("Date", selection: $due) }
                }
                Section("Caption & notes") {
                    TextEditor(text: $item.caption).font(.system(size: 13)).frame(minHeight: 110)
                }
                Section {
                    FlowLayout(spacing: 6) {
                        ForEach(platforms, id: \.self) { platform in
                            let target = item.targets.first { $0.platform == platform }
                            Button { togglePlatform(platform) } label: {
                                HStack(spacing: 6) {
                                    PlatformIcon(platform: platform, size: 16).opacity(target == nil ? 0.55 : 1)
                                    Text(platform)
                                    if target != nil { Image(systemName: target!.isDone ? "checkmark.circle.fill" : "checkmark").font(.caption) }
                                }
                                .font(.callout)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .foregroundStyle(target == nil ? .secondary : Theme.accent)
                                .background(target == nil ? Color.primary.opacity(0.05) : Theme.accent.opacity(0.13), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "plus").font(.caption).foregroundStyle(.secondary)
                            TextField("", text: $customPlatform, prompt: Text("Custom platform")).labelsHidden().textFieldStyle(.plain).lineLimit(1).frame(width: 130)
                                .onSubmit(addCustom)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .overlay(Capsule().strokeBorder(Theme.border))
                    }
                    ForEach($item.targets) { $target in
                        HStack {
                            PlatformIcon(platform: target.platform, size: 18)
                            Toggle(target.platform, isOn: Binding(get: { target.isDone }, set: { target.completedAt = $0 ? Date() : nil }))
                            Spacer()
                            if let done = target.completedAt { Text("Posted \(done.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                } header: { Text("Destinations") } footer: {
                    Text("Tap a platform to include it, or type any custom destination (a newsletter, a community, a client's page). Each one is completed separately.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Source assets") {
                    ForEach(item.assets, id: \.self) { path in
                        let url = URL(fileURLWithPath: path)
                        let exists = FileManager.default.fileExists(atPath: path)
                        HStack {
                            Image(systemName: exists ? "photo" : "photo.badge.exclamationmark").foregroundStyle(exists ? Theme.accent : Theme.overdue)
                            Text(url.lastPathComponent).lineLimit(1)
                            if !exists { Text("missing").font(.caption).foregroundStyle(Theme.overdue) }
                            Spacer()
                            if exists { Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain).help("Show in Finder") }
                            Button { item.assets.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        }
                    }
                    Button { addAssets() } label: { Label("Add files…", systemImage: "plus") }
                    Text("Files are referenced in place, never copied.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        } footer: {
            if existing { Button("Delete…", role: .destructive) { deleteConfirm = true }.buttonStyle(.plain).font(T.small).foregroundStyle(Theme.overdue) }
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.soft).keyboardShortcut(.cancelAction)
            Button(existing ? "Save" : "Add to Queue") {
                addCustom()
                item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                item.due = hasDue ? due : nil
                item.updatedAt = Date()
                if store.upsert(item, in: \.contentItems) { dismiss() }
            }.keyboardShortcut(.defaultAction).buttonStyle(.primary)
                .disabled(item.title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear {
            hasDue = item.due != nil
            due = item.due ?? Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)!
        }
        .confirmationDialog("Delete this planned post?", isPresented: $deleteConfirm) {
            Button("Delete", role: .destructive) { store.remove(item.id, in: \.contentItems); dismiss() }
        } message: { Text("Referenced asset files are not affected.") }
    }

    func addCustom() {
        let platform = customPlatform.trimmingCharacters(in: .whitespaces)
        customPlatform = ""
        guard !platform.isEmpty, !item.targets.contains(where: { $0.platform.caseInsensitiveCompare(platform) == .orderedSame }) else { return }
        item.targets.append(PostTarget(platform: platform))
    }

    func togglePlatform(_ platform: String) {
        if item.targets.contains(where: { $0.platform == platform }) { item.targets.removeAll { $0.platform == platform } }
        else { item.targets.append(PostTarget(platform: platform)) }
    }

    func addAssets() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie, .pdf]
        if let folder = store.workspace.folders.first(where: { $0.projectID == item.projectID }), case .available(let url) = store.status(of: folder) {
            panel.directoryURL = url
        }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !item.assets.contains(url.path) { item.assets.append(url.path) }
    }
}
