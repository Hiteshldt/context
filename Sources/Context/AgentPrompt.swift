import Foundation

/// Ready-made instructions to paste into an AI agent (Claude Code, Codex, Cursor, …) so it can work on one project.
/// They work with or without MCP set up: the agent uses Context's MCP tools if it has them, or `Context --call` otherwise.
enum AgentPrompt {
    enum Task: String, CaseIterable, Identifiable {
        case mapCode, fillGaps, tidy, explain, custom
        var id: String { rawValue }

        var title: String {
            switch self {
            case .mapCode: return "Map this codebase"
            case .fillGaps: return "Fill in what's missing"
            case .tidy: return "Tidy and group the map"
            case .explain: return "Explain this map"
            case .custom: return "Something else"
            }
        }

        var detail: String {
            switch self {
            case .mapCode: return "Paste it into an agent running in the project's code folder. It maps the apps, services, and how they connect."
            case .fillGaps: return "Adds missing services and connections, and puts saved links on the map."
            case .tidy: return "Groups related boxes, labels connections, and arranges the layout."
            case .explain: return "Reads the map and explains how the project fits together. Changes nothing."
            case .custom: return "Describe what you'd like done."
            }
        }

        var icon: String {
            switch self {
            case .mapCode: return "chevron.left.forwardslash.chevron.right"
            case .fillGaps: return "plus.square.on.square"
            case .tidy: return "rectangle.3.group"
            case .explain: return "text.bubble"
            case .custom: return "pencil"
            }
        }

        var instruction: String {
            switch self {
            case .mapCode:
                return "Look at the code in the current folder and map how this project is built and runs: its apps and APIs, databases and storage, "
                    + "hosting and deployment, and third-party services (payments, email, auth, analytics, …), and how they connect. Add boxes for "
                    + "what isn't on the map yet (give services with a dashboard a \"url\"), connect them with short labels like \"deploys to\" or "
                    + "\"reads & writes\", group them (for example Frontend, Backend, Data, Third-party), and arrange the map."
            case .fillGaps:
                return "Review this project's map and saved links. Add the services, accounts, and connections that are clearly missing, and put "
                    + "saved links that aren't on the map yet where they belong. Don't remove anything."
            case .tidy:
                return "Tidy this project's map: group related boxes (for example Frontend, Backend, Data, Third-party), give unlabelled "
                    + "connections short labels where the meaning is clear, then arrange the map. Don't delete boxes."
            case .explain:
                return "Read this project's map and links and explain in plain language how the project fits together. Point out anything that "
                    + "looks incomplete or inconsistent. Don't change anything."
            case .custom:
                return ""
            }
        }
    }

    /// The full prompt for `task` (or the person's own words for `.custom`) on `project`.
    static func make(_ task: Task, custom: String = "", project: Project, in workspace: Workspace, executable: String) -> String {
        let instruction = task == .custom ? custom.trimmingCharacters(in: .whitespacesAndNewlines) : task.instruction
        let maps = workspace.diagrams.filter { $0.projectID == project.id }
        let links = workspace.entries.filter { $0.projectID == project.id && EntryKind.linkKinds.contains($0.kind) }.count
        let mapLines = maps.isEmpty ? "  (none yet: create one with create_map)"
            : maps.map { "  \($0.title) (map_id \($0.id.uuidString), \($0.nodes.count) boxes, \($0.edges.count) connections)" }.joined(separator: "\n")
        let exe = "\"\(executable)\""
        let id = project.id.uuidString
        return """
        I use Context, a Mac app where each project has a map: boxes for apps, services, people, and databases, joined by labelled arrows, \
        plus saved links. Please work on my project "\(project.name)".

        Task: \(instruction.isEmpty ? "(describe the task here)" : instruction)

        How to reach Context
        - If you have tools from the "context" MCP server, use them.
        - Otherwise, run Context's command line on this Mac. Each call prints JSON:
          \(exe) --call get_map '{"project": "\(id)"}'
          \(exe) --call list_tools
          Pass the arguments as one JSON object in single quotes, or pass - and send the JSON on standard input (a heredoc) when it's long \
        or contains quotes. If the command can't reach Context, it may need permission to use the network on this Mac (127.0.0.1 only).

        This project
        - Name: \(project.name) (project id \(id))
        - Maps:
        \(mapLines)
        - Saved links: \(links)

        How to work
        - Start with get_map (and list_links if useful) to see what's already there. Don't add a box that already exists; update it instead.\(maps.count > 1 ? " Pass map_id to choose the map." : "")
        - Add several boxes and their connections in one add_boxes call: give new boxes a "ref" to connect them, and pass "arrange": true for a clean layout.
        - Give a box a "url" when it's a website or dashboard; it's saved as a link with its logo.
        - Box kinds: step, person, app, api, database, storage, cloud, email, payment, note. Colours: sage, blue, orange, purple, rose, gold, teal, slate.
        - Refer to existing boxes by id or exact label. Group related boxes with add_group.
        - Never ask for, read, or store passwords or keys. I can undo your map changes with ⌘Z in Context.
        - When you're done, summarise what you changed.
        """
    }
}
