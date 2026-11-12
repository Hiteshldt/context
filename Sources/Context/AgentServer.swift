import Foundation
import AppKit

/// Lets AI agents on this Mac (Claude Code, Cursor, and others that speak MCP) read and edit maps and links.
/// Off until turned on. Only programs on this Mac can connect, they need the access key, browsers are refused,
/// nothing works while Context is locked, and saved passwords are never available.
@MainActor
final class AgentAccess: ObservableObject {
    static let shared = AgentAccess()

    struct Activity: Identifiable {
        let id = UUID()
        let date: Date
        let client: String
        let summary: String
        let failed: Bool
    }

    @Published private(set) var settings = AgentSettings.load()
    @Published private(set) var running = false
    @Published private(set) var problem: String?
    @Published private(set) var activity: [Activity] = []

    private weak var store: Store?
    private var server: AgentHTTPServer?
    /// Session id → the agent's name from `initialize`, for the activity list.
    private var sessions: [String: String] = [:]

    var endpoint: String { "http://127.0.0.1:\(settings.port)/mcp" }
    /// The command line agents run to connect through this app.
    /// Outside an app bundle (a development build or the screenshot tool), show where the app normally lives.
    var command: String {
        guard Bundle.main.bundleURL.pathExtension == "app", let path = Bundle.main.executablePath else { return "/Applications/Context.app/Contents/MacOS/Context" }
        return path
    }

    func attach(_ store: Store) {
        self.store = store
        if settings.enabled { start() }
    }

    func setEnabled(_ on: Bool) {
        settings.enabled = on
        settings.save()
        on ? start() : stop()
    }

    /// Makes a new access key. Agents connected over HTTP need the new one; the `--mcp` bridge picks it up by itself.
    func resetKey() {
        settings.token = AgentSettings.newToken()
        settings.save()
        sessions = [:]
    }

    private func start(attempt: Int = 0) {
        stop()
        problem = nil
        let server = AgentHTTPServer { request in
            DispatchQueue.main.sync { MainActor.assumeIsolated { AgentAccess.shared.handle(request) } }
        }
        self.server = server
        server.start(port: settings.port) { [weak self] failure in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.server === server else { return }
                    if let failure {
                        // The port is taken by something else: try the next few.
                        if attempt < 10 {
                            self.settings.port += 1
                            self.settings.save()
                            self.start(attempt: attempt + 1)
                        } else {
                            self.running = false
                            self.problem = "Couldn't start: \(failure)"
                        }
                    } else {
                        self.running = true
                    }
                }
            }
        }
        settings.save()
    }

    private func stop() {
        server?.stop()
        server = nil
        running = false
        sessions = [:]
    }

    // MARK: Requests

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        guard settings.enabled else { return .text(403, "AI agent access is turned off in Context.") }
        if let refusal = refuse(request, port: settings.port, token: settings.token) { return refusal }
        switch request.method {
        case "POST": break
        case "DELETE":
            if let session = request.headers["mcp-session-id"] { sessions[session] = nil }
            return HTTPResponse(status: 200)
        default:
            return HTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"])
        }

        var responseHeaders: [String: String] = [:]
        var client = request.headers["mcp-session-id"].flatMap { sessions[$0] } ?? "An AI agent"
        if let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any], message["method"] as? String == "initialize" {
            let session = UUID().uuidString
            let info = (message["params"] as? [String: Any])?["clientInfo"] as? [String: Any]
            client = Self.friendlyName(info?["name"] as? String)
            sessions[session] = client
            responseHeaders["Mcp-Session-Id"] = session
        }
        let dispatcher = MCPDispatcher(serverName: "context", serverVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                                       instructions: AgentTools.instructions, tools: AgentTools.specs + Self.reminderSpecs) { name, arguments in
            MainActor.assumeIsolated { self.run(name, arguments, client: client) }
        }
        guard let reply = dispatcher.handle(request.body) else { return HTTPResponse(status: 202, headers: responseHeaders) }
        responseHeaders["Content-Type"] = "application/json"
        return HTTPResponse(status: 200, headers: responseHeaders, body: reply)
    }

    static func friendlyName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "An AI agent" }
        let known = ["claude-code": "Claude Code", "claude-ai": "Claude", "cursor-vscode": "Cursor", "cursor": "Cursor", "windsurf": "Windsurf",
                     "codex-mcp-client": "Codex", "vscode": "VS Code", "zed": "Zed", "context-bridge": "An AI agent"]
        return known[raw.lowercased()] ?? raw
    }

    // MARK: Tools

    func run(_ name: String, _ arguments: [String: Any], client: String) -> ToolOutcome {
        guard !AppLock.shared.isLocked else { return .failure("Context is locked. Unlock it on this Mac, then try again.") }
        guard let store, !store.loadFailed else { return .failure("Context's data couldn't be loaded, so changes are paused. Open Context to fix it.") }
        if name == "list_reminders" || name == "add_reminder" { return runReminderTool(name, arguments, client: client, store: store) }
        var copy = store.workspace
        do {
            let result = try AgentTools.run(name, arguments, in: &copy)
            if copy != store.workspace {
                let before = store.workspace
                guard store.change({ $0 = copy }) else {
                    let message = store.error ?? "The change couldn't be saved."
                    store.error = nil
                    record(client, "\(name) failed: \(message)", failed: true)
                    return .failure(message)
                }
                registerUndo(from: before, to: copy, store: store)
            }
            if !name.hasPrefix("list_") && !name.hasPrefix("get_") { record(client, result.summary, failed: false) }
            return .success(result.value)
        } catch let failure as AgentTools.Failure {
            record(client, "\(name): \(failure.message)", failed: true)
            return .failure(failure.message)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Map changes made by an agent can be undone with ⌘Z, like your own.
    private func registerUndo(from before: Workspace, to after: Workspace, store: Store) {
        guard let undo = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true })?.undoManager else { return }
        for old in before.diagrams {
            guard let new = after.diagrams.first(where: { $0.id == old.id }) else {
                // A deleted map comes back on undo.
                undo.registerUndo(withTarget: store) { store in MainActor.assumeIsolated { store.upsert(old, in: \.diagrams) } }
                continue
            }
            if !DiagramEditor.sameContent(old, new) { DiagramEditor.registerRestore(old, in: store, undoManager: undo) }
        }
        undo.setActionName("AI Agent Change")
    }

    private func record(_ client: String, _ summary: String, failed: Bool) {
        activity.insert(Activity(date: Date(), client: client, summary: summary, failed: failed), at: 0)
        if activity.count > 30 { activity.removeLast(activity.count - 30) }
    }

    // MARK: Reminders (Apple Reminders, through the app)

    static var reminderSpecs: [AgentToolSpec] {
        [
            AgentToolSpec(name: "list_reminders", description: "Lists a project's reminders (from Apple Reminders) and the map box each belongs to.",
                          inputSchema: ["type": "object", "properties": ["project": ["type": "string", "description": "The project's id or name."]], "required": ["project"]]),
            AgentToolSpec(name: "add_reminder",
                          description: "Adds a reminder to a project in Apple Reminders, optionally on a map box. `due` is a date (2026-11-14), a date and time (2026-11-14T17:00), or words like \"friday 5pm\".",
                          inputSchema: ["type": "object", "properties": [
                            "project": ["type": "string"], "title": ["type": "string"], "due": ["type": "string"], "notes": ["type": "string"],
                            "box": ["type": "string", "description": "A box id or exact label to attach the reminder to."],
                            "map_id": ["type": "string", "description": "The map the box is on, if the project has several."],
                          ], "required": ["project", "title"]]),
        ]
    }

    private func runReminderTool(_ name: String, _ arguments: [String: Any], client: String, store: Store) -> ToolOutcome {
        let reminders = RemindersService.shared
        guard reminders.access == .granted else {
            return .failure("Apple Reminders isn't connected in Context. Ask the person to open a box's details in Context and click Connect Apple Reminders.")
        }
        do {
            let project = try AgentTools.findProject(arguments["project"], in: store.workspace)
            let boxTitles = Dictionary(store.workspace.diagrams.filter { $0.projectID == project.id }.flatMap { map in
                map.nodes.map { node in (node.id, node.entryID.flatMap { id in store.entry(id)?.title } ?? node.label) }
            }, uniquingKeysWith: { a, _ in a })
            if name == "list_reminders" {
                let items = reminders.items(for: project).sorted(by: ReminderItem.order).map { item -> [String: Any] in
                    var value: [String: Any] = ["title": item.title, "done": item.isCompleted]
                    if let due = item.due { value["due"] = item.hasTime ? ISO8601DateFormatter().string(from: due) : Self.day.string(from: due) }
                    if !item.notes.isEmpty { value["notes"] = item.notes }
                    if let box = item.boxID, let title = boxTitles[box] { value["box"] = title; value["box_id"] = box.uuidString }
                    if item.repeats != .never { value["repeats"] = item.repeats.rawValue }
                    return value
                }
                return .success(["reminders": items])
            }
            let title = try AgentTools.text(arguments, "title", required: true)!
            var box: UUID?
            if let reference = try AgentTools.text(arguments, "box") {
                var target = arguments
                target["project"] = project.id.uuidString
                let mapIndex = try AgentTools.mapIndex(target, in: store.workspace)
                let map = store.workspace.diagrams[mapIndex]
                box = map.nodes[try AgentTools.findBox(reference, in: map, workspace: store.workspace)].id
            }
            var due: (Date, Bool)?
            if let text = try AgentTools.text(arguments, "due") {
                guard let parsed = Self.parseDue(text) else { throw AgentTools.Failure("Couldn't read the date \(text). Use 2026-11-14 or 2026-11-14T17:00.") }
                due = parsed
            }
            reminders.add(title, notes: try AgentTools.text(arguments, "notes") ?? "", due: due?.0, hasTime: due?.1 ?? false,
                          to: project.id, box: box, in: store)
            if let error = reminders.error { reminders.error = nil; throw AgentTools.Failure(error) }
            record(client, "Added the reminder “\(title)” to \(project.name)", failed: false)
            return .success(["added": title, "project": project.name])
        } catch let failure as AgentTools.Failure {
            record(client, "\(name): \(failure.message)", failed: true)
            return .failure(failure.message)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// A due date from "2026-11-14", "2026-11-14T17:00", a full ISO 8601 time, or words like "friday 5pm".
    static func parseDue(_ text: String) -> (Date, Bool)? {
        if let date = day.date(from: text) { return (date, false) }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return (date, true) }
        }
        if let date = ISO8601DateFormatter().date(from: text) { return (date, true) }
        let parsed = QuickReminderParser.parse("Reminder \(text)")
        return parsed.due.map { ($0, parsed.hasTime) }
    }
}

