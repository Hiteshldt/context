import Foundation

enum LauncherAction: String, CaseIterable, Identifiable {
    case newNote, newLink, newTask, newProject, backupNow, backupSettings, goHome
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newNote: return "New note"
        case .newLink: return "New link"
        case .newTask: return "New task"
        case .newProject: return "New project"
        case .backupNow: return "Back up now"
        case .backupSettings: return "Backup settings"
        case .goHome: return "Go to Home"
        }
    }
    var icon: String {
        switch self {
        case .newNote: return "square.and.pencil"
        case .newLink: return "link.badge.plus"
        case .newTask: return "checkmark.circle"
        case .newProject: return "plus.square.on.square"
        case .backupNow: return "arrow.clockwise.icloud"
        case .backupSettings: return "icloud"
        case .goHome: return "house"
        }
    }
    var keywords: String {
        switch self {
        case .newNote: return "create add note document write"
        case .newLink: return "create add link service website bookmark"
        case .newTask: return "create add task todo reminder"
        case .newProject: return "create add project"
        case .backupNow: return "backup save cloud export"
        case .backupSettings: return "backup cloud google drive icloud restore import export settings"
        case .goHome: return "home today start"
        }
    }
}

enum LauncherTarget: Equatable, Hashable {
    case entry(UUID), project(UUID), client(UUID), task(UUID), action(LauncherAction)
}

struct LauncherResult: Identifiable, Equatable {
    let target: LauncherTarget
    let title: String
    let subtitle: String
    let score: Int
    var id: LauncherTarget { target }
}

/// Finds anything in the workspace from a few typed characters. Titles beat details; links you use often rank higher.
enum LauncherSearch {
    /// 0 means no match. Higher is better.
    static func score(_ query: String, in text: String) -> Int {
        let q = query.lowercased(), t = text.lowercased()
        guard !q.isEmpty, !t.isEmpty else { return 0 }
        if t == q { return 1000 }
        if t.hasPrefix(q) { return 800 }
        let words = t.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(q) }) { return 600 }
        if t.contains(q) { return 400 }
        // Initials: "gc" matches "Google Cloud".
        if q.count >= 2, String(words.compactMap(\.first)).hasPrefix(q) { return 300 }
        // In-order letters: "vrcl" matches "Vercel".
        if q.count >= 3 {
            var index = t.startIndex
            for character in q {
                guard let found = t[index...].firstIndex(of: character) else { return 0 }
                index = t.index(after: found)
            }
            return 120
        }
        return 0
    }

    /// Every word of the query must match somewhere in `fields`; earlier fields count for more.
    static func score(query: String, fields: [(text: String, weight: Double)]) -> Int {
        let tokens = query.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return 0 }
        var total = 0.0
        for token in tokens {
            let best = fields.map { Double(score(token, in: $0.text)) * $0.weight }.max() ?? 0
            if best == 0 { return 0 }
            total += best
        }
        return Int(total / Double(tokens.count))
    }

    static func results(for rawQuery: String, in workspace: Workspace, limit: Int = 12) -> [LauncherResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        let projects = Dictionary(uniqueKeysWithValues: workspace.projects.map { ($0.id, $0) })
        func subtitle(_ entry: Entry) -> String {
            var parts = [projects[entry.projectID]?.name ?? ""]
            if let host = BrandCatalog.host(of: entry.url) { parts.append(host) } else { parts.append(entry.kind.shortName) }
            return parts.filter { !$0.isEmpty }.joined(separator: " · ")
        }

        if query.isEmpty {
            // Nothing typed: the links used most recently and most often, then projects.
            let used = workspace.entries.filter { EntryKind.linkKinds.contains($0.kind) && webURL($0.url) != nil }
                .sorted { a, b in
                    let ka = (a.lastOpenedAt ?? .distantPast, a.pinned ? 1 : 0, a.openCount)
                    let kb = (b.lastOpenedAt ?? .distantPast, b.pinned ? 1 : 0, b.openCount)
                    return ka > kb
                }
            var results = used.prefix(6).map { LauncherResult(target: .entry($0.id), title: $0.title, subtitle: subtitle($0), score: 0) }
            results += workspace.projects.sorted { ($0.lastOpenedAt ?? $0.updatedAt) > ($1.lastOpenedAt ?? $1.updatedAt) }.prefix(4)
                .map { LauncherResult(target: .project($0.id), title: $0.name, subtitle: "Project", score: 0) }
            results += [LauncherAction.newNote, .newLink, .backupNow].map { LauncherResult(target: .action($0), title: $0.title, subtitle: "Action", score: 0) }
            return Array(results.prefix(limit + 2))
        }

        var results: [LauncherResult] = []
        for project in workspace.projects {
            let s = score(query: query, fields: [(project.name, 1.1), (project.summary, 0.4)])
            if s > 0 { results.append(LauncherResult(target: .project(project.id), title: project.name, subtitle: "Project", score: s)) }
        }
        for client in workspace.clients {
            let s = score(query: query, fields: [(client.name, 1.0), (client.contactName, 0.5)])
            if s > 0 { results.append(LauncherResult(target: .client(client.id), title: client.name, subtitle: "Client", score: s)) }
        }
        for entry in workspace.entries {
            let isNote = entry.kind == .note || entry.kind == .prompt
            var fields: [(String, Double)] = [(entry.title, 1.0), (BrandCatalog.host(of: entry.url) ?? "", 0.7), (entry.category, 0.6),
                                              (entry.tags.joined(separator: " "), 0.6), (entry.account, 0.5), (projects[entry.projectID]?.name ?? "", 0.35)]
            // Search inside notes too, but rank a body match below any title match.
            if isNote || query.count >= 4 { fields.append((String(entry.body.prefix(20_000)), 0.3)) }
            var s = score(query: query, fields: fields)
            guard s > 0 else { continue }
            s += min(60, entry.openCount * 6) + (entry.pinned ? 25 : 0)
            results.append(LauncherResult(target: .entry(entry.id), title: entry.title.isEmpty ? "Untitled" : entry.title,
                                          subtitle: isNote ? "\(projects[entry.projectID]?.name ?? "") · \(entry.kind.rawValue)" : subtitle(entry), score: s))
        }
        for task in workspace.tasks where !task.isComplete {
            let s = score(query: query, fields: [(task.title, 0.9), (task.details, 0.3)])
            if s > 0 { results.append(LauncherResult(target: .task(task.id), title: task.title, subtitle: "\(projects[task.projectID]?.name ?? "") · Task", score: s)) }
        }
        for action in LauncherAction.allCases {
            let s = score(query: query, fields: [(action.title, 0.9), (action.keywords, 0.5)])
            if s > 0 { results.append(LauncherResult(target: .action(action), title: action.title, subtitle: "Action", score: s)) }
        }
        return Array(results.sorted { ($0.score, $1.title) > ($1.score, $0.title) }.prefix(limit))
    }
}
