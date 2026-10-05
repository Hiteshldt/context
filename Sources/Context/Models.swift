import Foundation

// MARK: - Projects and clients

enum ProjectKind: String, Codable, CaseIterable {
    case personal = "Personal", product = "Product", brand = "Brand", work = "Work", client = "Client"
}

enum ProjectStatus: String, Codable, CaseIterable, Identifiable {
    case active = "Active", planning = "Planning", paused = "Paused", maintenance = "Maintenance", done = "Done"
    var id: String { rawValue }
}

enum ProjectSection: String, Codable, CaseIterable, Identifiable {
    case overview = "Overview", tasks = "Tasks", links = "Links", map = "Map", files = "Files", notes = "Notes"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .tasks: return "checkmark.circle"
        case .links: return "link"
        case .map: return "point.3.connected.trianglepath.dotted"
        case .files: return "folder"
        case .notes: return "note.text"
        }
    }
    var summary: String {
        switch self {
        case .overview: return "Where things stand, quick links, and recent work"
        case .tasks: return "Tasks, reminders, and planned posts"
        case .links: return "Services, social accounts, repos, websites, docs, and AI chats"
        case .map: return "A diagram of how the project's people, apps, and services connect"
        case .files: return "Connected folders with your working files"
        case .notes: return "Notes, documents, and reusable prompts"
        }
    }
    static let enabledByDefault: Set<ProjectSection> = Set(ProjectSection.allCases)

    /// Earlier versions had separate sections that are now combined.
    static func migrating(_ raw: String) -> ProjectSection? {
        if let section = ProjectSection(rawValue: raw) { return section }
        switch raw {
        case "Resources", "Services", "Social": return .links
        case "Prompts": return .notes
        case "Diagrams": return .map
        case "Files & Tools", "Image Tools": return .files
        default: return nil
        }
    }
}

/// An enabled area of a project with a customizable name and position. Array order is display order.
struct SectionConfig: Codable, Equatable, Hashable, Identifiable {
    var section: ProjectSection
    var title = ""
    var enabled = true
    var id: ProjectSection { section }
    var displayName: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? section.rawValue : trimmed
    }

    static func defaults(enabled: Set<ProjectSection> = ProjectSection.enabledByDefault) -> [SectionConfig] {
        ProjectSection.allCases.map { SectionConfig(section: $0, enabled: enabled.contains($0)) }
    }

    /// Overview always comes first and stays enabled. Duplicates (e.g. old sections that were merged) are combined:
    /// the first position wins and the section is shown if any of them was shown. Missing sections are appended hidden.
    static func normalized(_ configs: [SectionConfig]) -> [SectionConfig] {
        let configs = configs.contains { $0.section == .map } ? configs : addingMap(to: configs)
        var seen = Set<ProjectSection>()
        var result: [SectionConfig] = []
        let overview = configs.first { $0.section == .overview } ?? SectionConfig(section: .overview)
        result.append(SectionConfig(section: .overview, title: overview.title, enabled: true))
        seen.insert(.overview)
        for config in configs {
            if seen.contains(config.section) {
                if config.enabled, let index = result.firstIndex(where: { $0.section == config.section }) { result[index].enabled = true }
                continue
            }
            seen.insert(config.section)
            result.append(config)
        }
        for section in ProjectSection.allCases where !seen.contains(section) {
            result.append(SectionConfig(section: section, enabled: false))
        }
        return result
    }

    /// The map used to live inside Links. Data saved before it had its own tab gets Map right after Links,
    /// shown if Links was shown. Projects still in the old default order move to the new one (Files before Notes).
    private static func addingMap(to configs: [SectionConfig]) -> [SectionConfig] {
        guard let links = configs.firstIndex(where: { $0.section == .links }) else { return configs }
        let map = SectionConfig(section: .map, enabled: configs.contains { $0.section == .links && $0.enabled })
        if configs.map(\.section) == [.overview, .tasks, .links, .notes, .files] {
            return ProjectSection.allCases.map { section in configs.first { $0.section == section } ?? map }
        }
        var result = configs
        result.insert(map, at: links + 1)
        return result
    }
}

extension SectionConfig {
    enum CodingKeys: String, CodingKey { case section, title, enabled }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .section)
        guard let section = ProjectSection.migrating(raw) else {
            throw DecodingError.dataCorruptedError(forKey: .section, in: c, debugDescription: "Unknown section \(raw)")
        }
        self.section = section
        // A custom name given to a section that has since been merged no longer describes the combined section.
        title = section.rawValue == raw ? try c.value(.title, "") : ""
        enabled = try c.value(.enabled, true)
    }
}

extension ProjectSection {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let section = ProjectSection.migrating(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown section \(raw)"))
        }
        self = section
    }
}

struct Project: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var summary = ""
    var kind: ProjectKind = .personal
    var status: ProjectStatus = .active
    var clientID: UUID?
    var color = "sage"
    var sections = SectionConfig.defaults()
    var contextNote = ""
    var createdAt = Date()
    var updatedAt = Date()
    var lastOpenedAt: Date?
    /// Version 1 stored the client as free text. Read during migration only; never written.
    var legacyClient: String?

    var visibleSections: [SectionConfig] { sections.filter(\.enabled) }
    func shows(_ section: ProjectSection) -> Bool { section == .overview || sections.contains { $0.section == section && $0.enabled } }
    func name(of section: ProjectSection) -> String { sections.first { $0.section == section }?.displayName ?? section.rawValue }

    enum CodingKeys: String, CodingKey {
        case id, name, summary, kind, status, clientID, color, sections, contextNote, createdAt, updatedAt, lastOpenedAt, client
    }
}

extension Project {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.value(.summary, "")
        kind = try c.value(.kind, .personal)
        status = try c.value(.status, .active)
        clientID = try c.decodeIfPresent(UUID.self, forKey: .clientID)
        color = try c.value(.color, "sage")
        if let configs = try? c.decode([SectionConfig].self, forKey: .sections) {
            sections = SectionConfig.normalized(configs)
        } else if let legacy = try c.decodeIfPresent([ProjectSection].self, forKey: .sections) {
            sections = SectionConfig.normalized(legacy.map { SectionConfig(section: $0) })
        } else {
            sections = SectionConfig.defaults()
        }
        contextNote = try c.value(.contextNote, "")
        createdAt = try c.value(.createdAt, Date())
        updatedAt = try c.value(.updatedAt, createdAt)
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        let legacy = try c.decodeIfPresent(String.self, forKey: .client)?.trimmingCharacters(in: .whitespacesAndNewlines)
        legacyClient = (legacy?.isEmpty ?? true) ? nil : legacy
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(summary, forKey: .summary)
        try c.encode(kind, forKey: .kind)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(clientID, forKey: .clientID)
        try c.encode(color, forKey: .color)
        try c.encode(sections, forKey: .sections)
        try c.encode(contextNote, forKey: .contextNote)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)
    }
}

struct Client: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var contactName = ""
    var email = ""
    var phone = ""
    var website = ""
    var notes = ""
    var createdAt = Date()
}

extension Client {
    enum CodingKeys: String, CodingKey { case id, name, contactName, email, phone, website, notes, createdAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        contactName = try c.value(.contactName, "")
        email = try c.value(.email, "")
        phone = try c.value(.phone, "")
        website = try c.value(.website, "")
        notes = try c.value(.notes, "")
        createdAt = try c.value(.createdAt, Date())
    }
}

// MARK: - Saved context

enum EntryKind: String, Codable, CaseIterable, Identifiable {
    case link = "Link", repository = "Repository", document = "Document", conversation = "AI conversation"
    case service = "Service", social = "Social account", note = "Note", prompt = "Prompt"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .link: return "link"
        case .repository: return "chevron.left.forwardslash.chevron.right"
        case .document: return "doc.text"
        case .conversation: return "bubble.left.and.bubble.right"
        case .service: return "server.rack"
        case .social: return "person.crop.square"
        case .note: return "note.text"
        case .prompt: return "text.bubble"
        }
    }
    var hasURL: Bool { ![.note, .prompt].contains(self) }
    var urlLabel: String {
        switch self {
        case .repository: return "Remote URL"
        case .service: return "Dashboard URL"
        case .social: return "Profile URL"
        case .conversation: return "Conversation URL"
        default: return "URL"
        }
    }
    var bodyLabel: String {
        switch self {
        case .conversation: return "Context summary"
        case .prompt: return "Prompt"
        case .note: return "Note"
        default: return "Notes"
        }
    }
    var section: ProjectSection { self == .note || self == .prompt ? .notes : .links }
    /// Plural label used for filters and list groups.
    var groupName: String {
        switch self {
        case .link: return "Websites & links"
        case .repository: return "Repositories"
        case .document: return "Documents"
        case .conversation: return "AI chats"
        case .service: return "Services"
        case .social: return "Social accounts"
        case .note: return "Notes"
        case .prompt: return "Prompts"
        }
    }
    /// Compact label for filter chips.
    var filterName: String {
        switch self {
        case .link: return "Websites"
        case .repository: return "Repos"
        case .document: return "Docs"
        case .conversation: return "AI chats"
        case .service: return "Services"
        case .social: return "Social"
        case .note: return "Notes"
        case .prompt: return "Prompts"
        }
    }
    var shortName: String {
        switch self {
        case .link: return "Link"
        case .conversation: return "AI chat"
        case .social: return "Social"
        default: return rawValue
        }
    }
    /// Display order for the combined Links section.
    static let linkKinds: [EntryKind] = [.service, .social, .repository, .link, .document, .conversation]
    static let noteKinds: [EntryKind] = [.note, .prompt]
}

/// Non-secret metadata for a credential. The secret itself lives only in the macOS Keychain.
struct CredentialRef: Identifiable, Codable, Equatable {
    var id = UUID()
    var label = ""
    var username = ""
}

struct Entry: Identifiable, Codable, Equatable {
    var id = UUID()
    var projectID: UUID
    var kind: EntryKind
    var title = ""
    var url = ""
    var body = ""
    /// Prompt usage notes, social management URL notes, or other secondary text.
    var details = ""
    var account = ""
    var category = ""
    var environment = ""
    var managementURL = ""
    var tags: [String] = []
    var pinned = false
    /// A connected folder holding a repository's local checkout.
    var folderID: UUID?
    var relatedIDs: [UUID] = []
    var credentials: [CredentialRef] = []
    var createdAt = Date()
    var updatedAt = Date()
    /// Used to surface the links you open most.
    var lastOpenedAt: Date?
    var openCount = 0
}

extension Entry {
    enum CodingKeys: String, CodingKey {
        case id, projectID, kind, title, url, body, details, account, category, environment, managementURL, tags, pinned, folderID, relatedIDs, credentials, createdAt, updatedAt, lastOpenedAt, openCount
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        kind = try c.decode(EntryKind.self, forKey: .kind)
        title = try c.value(.title, "")
        url = try c.value(.url, "")
        body = try c.value(.body, "")
        details = try c.value(.details, "")
        account = try c.value(.account, "")
        category = try c.value(.category, "")
        environment = try c.value(.environment, "")
        managementURL = try c.value(.managementURL, "")
        tags = try c.value(.tags, [])
        pinned = try c.value(.pinned, false)
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        relatedIDs = try c.value(.relatedIDs, [])
        credentials = try c.value(.credentials, [])
        updatedAt = try c.value(.updatedAt, Date())
        createdAt = try c.value(.createdAt, updatedAt)
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        openCount = try c.value(.openCount, 0)
    }
}

// MARK: - Tasks

struct WorkTask: Identifiable, Codable, Equatable {
    var id = UUID()
    var projectID: UUID
    var title = ""
    var details = ""
    var due: Date?
    var repeatRule = RepeatRule()
    /// Minutes before each due occurrence to notify. `nil` means no due-relative reminder.
    var reminderLead: Int?
    /// A notification time independent of the due date.
    var notifyAt: Date?
    var snoozedUntil: Date?
    var completedAt: Date?
    var completionHistory: [Date] = []
    var platform = ""
    var relatedIDs: [UUID] = []
    var createdAt = Date()

    var isComplete: Bool { completedAt != nil }
    func isSnoozed(at now: Date = Date()) -> Bool { !isComplete && (snoozedUntil ?? .distantPast) > now }
    func isOverdue(at now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard !isComplete, let due else { return false }
        return due < now
    }

    /// When this task's next notification should fire, if any.
    var reminderDate: Date? {
        guard !isComplete else { return nil }
        if let snoozedUntil { return snoozedUntil }
        if let due, let reminderLead { return due.addingTimeInterval(-Double(reminderLead) * 60) }
        return notifyAt
    }

    /// Records completion of the current occurrence. Recurring tasks advance to their next future occurrence;
    /// missed occurrences collapse into one and are never auto-completed. The recurrence rule itself never changes.
    mutating func complete(at now: Date = Date(), calendar: Calendar = .current) {
        completionHistory.append(now)
        snoozedUntil = nil
        guard repeatRule.repeats, let due else { completedAt = now; return }
        if !repeatRule.extraTimes.isEmpty {
            // Keep every daily slot explicit so advancing to a later slot does not drop the original time of day.
            repeatRule.extraTimes = repeatRule.timeSlots(anchor: due, calendar: calendar)
        }
        let next: Date?
        if repeatRule.kind == .afterCompletion {
            next = repeatRule.followUp(completedAt: now, dueTime: due, calendar: calendar)
        } else {
            next = repeatRule.occurrence(after: max(now, due), anchor: due, calendar: calendar)
        }
        guard let next else { completedAt = now; return }
        self.due = next
        if notifyAt != nil && reminderLead == nil { notifyAt = nil }
        completedAt = nil
    }

    mutating func reopen() {
        completedAt = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, projectID, title, details, due, repeatRule, reminderLead, notifyAt, snoozedUntil, completedAt, completionHistory, platform, relatedIDs, createdAt
        case recurrence, remind
    }
}

extension WorkTask {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        title = try c.value(.title, "")
        details = try c.value(.details, "")
        due = try c.decodeIfPresent(Date.self, forKey: .due)
        if let rule = try c.decodeIfPresent(RepeatRule.self, forKey: .repeatRule) {
            repeatRule = rule
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .recurrence) {
            repeatRule = RepeatRule(legacy: legacy, due: due)
        }
        if c.contains(.reminderLead) {
            reminderLead = try c.decodeIfPresent(Int.self, forKey: .reminderLead)
        } else if try c.value(.remind, false) {
            reminderLead = 0
        }
        notifyAt = try c.decodeIfPresent(Date.self, forKey: .notifyAt)
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        completionHistory = try c.value(.completionHistory, [])
        platform = try c.value(.platform, "")
        relatedIDs = try c.value(.relatedIDs, [])
        createdAt = try c.value(.createdAt, Date())
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(projectID, forKey: .projectID)
        try c.encode(title, forKey: .title)
        try c.encode(details, forKey: .details)
        try c.encodeIfPresent(due, forKey: .due)
        try c.encode(repeatRule, forKey: .repeatRule)
        try c.encode(reminderLead, forKey: .reminderLead)
        try c.encodeIfPresent(notifyAt, forKey: .notifyAt)
        try c.encodeIfPresent(snoozedUntil, forKey: .snoozedUntil)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encode(completionHistory, forKey: .completionHistory)
        try c.encode(platform, forKey: .platform)
        try c.encode(relatedIDs, forKey: .relatedIDs)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

// MARK: - Folders, social, diagrams, images

struct FolderConnection: Identifiable, Codable, Equatable {
    var id = UUID()
    var projectID: UUID
    var name: String
    var path: String
    var bookmark: Data
    var purpose = ""
    static let purposes = ["Source code", "Design assets", "Generated assets", "Exports", "Documents", "Other"]
}

extension FolderConnection {
    enum CodingKeys: String, CodingKey { case id, projectID, name, path, bookmark, purpose }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        bookmark = try c.decode(Data.self, forKey: .bookmark)
        purpose = try c.value(.purpose, "")
    }
}

struct PostTarget: Identifiable, Codable, Equatable {
    var id = UUID()
    var platform: String
    var completedAt: Date?
    var postURL = ""
    var isDone: Bool { completedAt != nil }
}

/// A planned post. Each destination platform tracks its own completion.
struct ContentItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var projectID: UUID
    var title = ""
    var caption = ""
    var assets: [String] = []
    var due: Date?
    var targets: [PostTarget] = []
    var createdAt = Date()
    var updatedAt = Date()
    var isComplete: Bool { !targets.isEmpty && targets.allSatisfy(\.isDone) }
    var remaining: [PostTarget] { targets.filter { !$0.isDone } }
    static let platforms = ["Instagram", "Facebook", "LinkedIn", "X", "Threads", "TikTok", "YouTube", "Pinterest", "WhatsApp", "Reddit"]
}

/// The visual type of a freeform map node. Linked nodes show their record's brand icon instead.
enum NodeKind: String, Codable, CaseIterable, Identifiable {
    case step, person, app, api, database, storage, cloud, email, payment, note
    var id: String { rawValue }
    var name: String {
        switch self {
        case .step: return "Step"
        case .person: return "Person"
        case .app: return "App / Site"
        case .api: return "API / Server"
        case .database: return "Database"
        case .storage: return "Storage"
        case .cloud: return "Cloud / External"
        case .email: return "Email"
        case .payment: return "Payment"
        case .note: return "Sticky note"
        }
    }
    var icon: String {
        switch self {
        case .step: return "square.dashed"
        case .person: return "person.fill"
        case .app: return "macwindow"
        case .api: return "server.rack"
        case .database: return "cylinder.split.1x2.fill"
        case .storage: return "externaldrive.fill"
        case .cloud: return "cloud.fill"
        case .email: return "envelope.fill"
        case .payment: return "creditcard.fill"
        case .note: return "note.text"
        }
    }
    /// Default tint, as a `Theme.color` name.
    var tint: String {
        switch self {
        case .step: return "slate"
        case .person: return "purple"
        case .app: return "blue"
        case .api: return "teal"
        case .database: return "sage"
        case .storage: return "orange"
        case .cloud: return "blue"
        case .email: return "rose"
        case .payment: return "gold"
        case .note: return "gold"
        }
    }
}

struct DiagramNode: Identifiable, Codable, Equatable {
    var id = UUID()
    var label = ""
    /// When set, this node represents a project record and displays that record's current title.
    var entryID: UUID?
    var x: Double
    var y: Double
    var kind: NodeKind = .step
    /// Optional tint override (a `Theme.color` name); empty uses the kind's default.
    var color = ""
    /// Free text about this box, shown when it's selected.
    var notes = ""
}

extension DiagramNode {
    enum CodingKeys: String, CodingKey { case id, label, entryID, x, y, kind, color, notes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.value(.label, "")
        entryID = try c.decodeIfPresent(UUID.self, forKey: .entryID)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        kind = (try? c.decode(NodeKind.self, forKey: .kind)) ?? .step
        color = try c.value(.color, "")
        notes = try c.value(.notes, "")
    }
}

/// A labelled frame on a map. Boxes whose centre sits inside it belong to it and move with it.
struct DiagramGroup: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = ""
    /// A `Theme.color` name.
    var color = "slate"
    /// Top-left corner and size, in canvas points.
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct DiagramEdge: Identifiable, Codable, Equatable {
    var id = UUID()
    var from: UUID
    var to: UUID
    var label = ""
    var dashed = false
}

extension DiagramEdge {
    enum CodingKeys: String, CodingKey { case id, from, to, label, dashed }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        from = try c.decode(UUID.self, forKey: .from)
        to = try c.decode(UUID.self, forKey: .to)
        label = try c.value(.label, "")
        dashed = try c.value(.dashed, false)
    }
}

struct Diagram: Identifiable, Codable, Equatable {
    var id = UUID()
    var projectID: UUID
    var title = "Untitled diagram"
    var nodes: [DiagramNode] = []
    var edges: [DiagramEdge] = []
    var groups: [DiagramGroup] = []
    var updatedAt = Date()
}

extension Diagram {
    enum CodingKeys: String, CodingKey { case id, projectID, title, nodes, edges, groups, updatedAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        title = try c.value(.title, "Untitled diagram")
        nodes = try c.value(.nodes, [])
        edges = try c.value(.edges, [])
        groups = try c.value(.groups, [])
        updatedAt = try c.value(.updatedAt, Date())
    }
}

struct ImageVariant: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var ratioW: Int
    var ratioH: Int
    var zoom = 1.0
    var offsetX = 0.0
    var offsetY = 0.0
    static let presets: [ImageVariant] = [
        ImageVariant(name: "Square", ratioW: 1, ratioH: 1),
        ImageVariant(name: "Portrait", ratioW: 4, ratioH: 5),
        ImageVariant(name: "Story", ratioW: 9, ratioH: 16),
        ImageVariant(name: "Landscape", ratioW: 16, ratioH: 9),
    ]
}

enum TextPlacement: String, Codable, CaseIterable, Identifiable {
    case top = "Top", center = "Center", bottom = "Bottom"
    var id: String { rawValue }
}

enum ImageFormat: String, Codable, CaseIterable, Identifiable {
    case png = "PNG", jpeg = "JPEG"
    var id: String { rawValue }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

/// Reusable crop, resize, effect, and text settings.
struct ImageRecipe: Identifiable, Codable, Equatable {
    var id = UUID()
    var projectID: UUID
    var name = "New recipe"
    var variants: [ImageVariant] = [ImageVariant.presets[0]]
    var outputWidth = 1080
    var blur = 0.0
    var noise = 0.0
    var text = ""
    var textSize = 64.0
    var textColor = "#FFFFFF"
    var textPlacement: TextPlacement = .bottom
    var boldText = true
    var format: ImageFormat = .png
}

struct ImageExport: Identifiable, Codable, Equatable {
    var id = UUID()
    var projectID: UUID
    var sourcePath: String
    var outputPath: String
    var variant = ""
    var createdAt = Date()
}

// MARK: - Workspace

struct Workspace: Codable, Equatable {
    static let currentVersion = 2
    var version = Workspace.currentVersion
    var projects: [Project] = []
    var clients: [Client] = []
    var entries: [Entry] = []
    var tasks: [WorkTask] = []
    var folders: [FolderConnection] = []
    var contentItems: [ContentItem] = []
    var diagrams: [Diagram] = []
    var recipes: [ImageRecipe] = []
    var exports: [ImageExport] = []

    enum CodingKeys: String, CodingKey { case version, projects, clients, entries, tasks, folders, contentItems, diagrams, recipes, exports }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard (1...Workspace.currentVersion).contains(version) else {
            throw WorkspaceError.invalid("This workspace uses an unsupported data version (\(version)). Update Context to open it.")
        }
        projects = try c.value(.projects, [])
        clients = try c.value(.clients, [])
        entries = try c.value(.entries, [])
        tasks = try c.value(.tasks, [])
        folders = try c.value(.folders, [])
        contentItems = try c.value(.contentItems, [])
        diagrams = try c.value(.diagrams, [])
        recipes = try c.value(.recipes, [])
        exports = try c.value(.exports, [])
        migrate()
    }

    /// Upgrades older data in memory. Version 1 kept clients as free-text names on projects.
    mutating func migrate() {
        for index in projects.indices {
            guard let name = projects[index].legacyClient else { continue }
            projects[index].legacyClient = nil
            guard projects[index].clientID == nil else { continue }
            if let existing = clients.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                projects[index].clientID = existing.id
            } else {
                let client = Client(name: name)
                clients.append(client)
                projects[index].clientID = client.id
            }
        }
        version = Workspace.currentVersion
    }

    func validated() throws -> Workspace {
        guard version == Workspace.currentVersion else { throw WorkspaceError.invalid("This backup uses an unsupported data version.") }
        func unique<T: Identifiable>(_ items: [T]) -> Bool where T.ID == UUID { Set(items.map(\.id)).count == items.count }
        guard unique(projects), unique(clients), unique(entries), unique(tasks), unique(folders),
              unique(contentItems), unique(diagrams), unique(recipes), unique(exports) else {
            throw WorkspaceError.invalid("The workspace contains duplicate identifiers.")
        }
        let projectIDs = Set(projects.map(\.id))
        let owned = entries.map(\.projectID) + tasks.map(\.projectID) + folders.map(\.projectID)
            + contentItems.map(\.projectID) + diagrams.map(\.projectID) + recipes.map(\.projectID) + exports.map(\.projectID)
        guard owned.allSatisfy({ projectIDs.contains($0) }) else {
            throw WorkspaceError.invalid("Some records refer to missing projects.")
        }
        let clientIDs = Set(clients.map(\.id))
        guard projects.allSatisfy({ $0.clientID.map(clientIDs.contains) ?? true }) else {
            throw WorkspaceError.invalid("Some projects refer to missing clients.")
        }
        guard tasks.allSatisfy({ !$0.repeatRule.repeats || $0.due != nil }) else {
            throw WorkspaceError.invalid("Recurring tasks must have a due date.")
        }
        for diagram in diagrams {
            let nodeIDs = Set(diagram.nodes.map(\.id))
            guard nodeIDs.count == diagram.nodes.count, diagram.edges.allSatisfy({ nodeIDs.contains($0.from) && nodeIDs.contains($0.to) }) else {
                throw WorkspaceError.invalid("A diagram contains connections to missing nodes.")
            }
        }
        return self
    }

    /// All credential identifiers referenced by records, used to clean up Keychain items.
    func credentialIDs(where include: (Entry) -> Bool) -> [UUID] {
        entries.filter(include).flatMap { $0.credentials.map(\.id) }
    }
}

enum WorkspaceError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct WorkspaceDisk {
    let directory: URL
    var file: URL { directory.appendingPathComponent("workspace.json") }
    var backup: URL { directory.appendingPathComponent("workspace.previous.json") }

    func load() throws -> Workspace {
        guard FileManager.default.fileExists(atPath: file.path) else { return Workspace() }
        return try decode(Data(contentsOf: file))
    }

    func decode(_ data: Data) throws -> Workspace {
        let decoder = JSONDecoder()
        return try decoder.decode(Workspace.self, from: data).validated()
    }

    func encode(_ workspace: Workspace) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(workspace.validated())
    }

    func save(_ workspace: Workspace) throws {
        let data = try encode(workspace)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if FileManager.default.fileExists(atPath: file.path) {
            let previous = try Data(contentsOf: file)
            _ = try decode(previous) // Never rotate corrupt data over a good backup.
            try previous.write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

func webURL(_ input: String) -> URL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let url = URL(string: trimmed),
          ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
    return url
}

extension KeyedDecodingContainer {
    /// Decodes an optional field, falling back to a default when absent. Type mismatches still throw.
    func value<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}
