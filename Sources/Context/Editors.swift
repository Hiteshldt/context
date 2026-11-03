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
    @State private var dropTargeted = false
    var existing: Bool { store.project(project.id) != nil }
    var trimmedName: String { project.name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        EditorSheet(icon: existing ? "slider.horizontal.3" : "plus.square.on.square", title: existing ? "Project settings" : "New project", width: 540, height: 440) {
            Form {
                Section {
                    TextField("Name", text: $project.name, prompt: Text("e.g. Ayuvam"))
                    LabeledContent("Picture") {
                        HStack(spacing: 12) {
                            ProjectIcon(project: project, size: 46)
                                .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.color(project.color), lineWidth: 2.5) } }
                                .dropDestination(for: URL.self) { urls, _ in
                                    guard let url = urls.first, let data = ProjectImage.prepare(contentsOf: url) else { return false }
                                    project.image = data
                                    return true
                                } isTargeted: { dropTargeted = $0 }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Button(project.image == nil ? "Choose…" : "Change…") { if let data = ProjectImage.choose() { project.image = data } }
                                    if project.image != nil { Button("Remove") { project.image = nil } }
                                }
                                Text("A logo or photo. You can also drop an image here.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    TextField("Description", text: $project.summary, prompt: Text("What is this project?"), axis: .vertical).lineLimit(2...4)
                    LabeledContent("Colour") {
                        HStack(spacing: 8) {
                            ForEach(Theme.projectColors, id: \.id) { option in
                                Button { project.color = option.id } label: {
                                    Circle().fill(Theme.color(option.id)).frame(width: 18, height: 18)
                                        .overlay(Circle().strokeBorder(.primary.opacity(project.color == option.id ? 0.8 : 0), lineWidth: 2).padding(-3))
                                }.buttonStyle(.plain).help(option.name)
                            }
                        }
                    }
                    Picker("Status", selection: $project.status) { ForEach(ProjectStatus.allCases) { Text($0.rawValue).tag($0) } }
                }
            }
            .formStyle(.grouped)
        } footer: {
            if existing { Button("Delete Project…", role: .destructive) { deleteConfirm = true }.buttonStyle(.plain).font(T.small).foregroundStyle(Theme.overdue) }
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(.soft).keyboardShortcut(.cancelAction)
            Button(existing ? "Save" : "Create Project") {
                let oldName = store.project(project.id)?.name
                project.name = trimmedName
                if store.save(project) {
                    if let oldName { RemindersService.shared.renameList(of: project, from: oldName) }
                    created?(project.id); dismiss()
                }
            }.keyboardShortcut(.defaultAction).buttonStyle(.primary).disabled(trimmedName.isEmpty)
        }
        .confirmationDialog("Delete \(project.name)?", isPresented: $deleteConfirm) {
            Button("Delete Project", role: .destructive) { store.deleteProject(project.id); dismiss() }
        } message: { Text(store.deletionSummary(for: project.id)) }
    }
}

// MARK: - Links

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
                    Toggle("Pin to the top", isOn: $entry.pinned)
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
                Section("Tags") {
                    FlowLayout(spacing: 6) {
                        ForEach(entry.tags, id: \.self) { tag in
                            Button { entry.tags.removeAll { $0 == tag } } label: { Pill(text: tag + "  ×", icon: "tag", color: Theme.accent) }.buttonStyle(.plain).help("Remove tag")
                        }
                        TextField("Add tag", text: $tagText).textFieldStyle(.plain).frame(width: 110).onSubmit(addTag)
                    }
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
            Text(entry.credentials.isEmpty ? "This removes it from Context. Map boxes linked to it will show it as removed." : "This also deletes \(entry.credentials.count) stored secret(s) from the Keychain.")
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
