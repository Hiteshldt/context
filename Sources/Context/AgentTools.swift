import Foundation
import CoreGraphics

/// What AI agents can do with projects, maps, and links. Each tool works on a copy of the workspace;
/// the app saves the copy (which validates it) and shows the change live. Passwords are never exposed.
enum AgentTools {
    struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }

    struct Result {
        var value: Any
        /// A short line for the activity list in Context, e.g. "Added 4 boxes to Overview".
        var summary: String
    }

    static let colors = ["sage", "blue", "orange", "purple", "rose", "gold", "teal", "slate"]

    static let instructions = """
    Context is a Mac app where each project has maps (diagrams of boxes, connections, and groups) and links (dashboards, repos, \
    accounts). Start with list_projects, then get_map. Refer to a project by its id or name, a map by map_id (or project plus map title), \
    and a box by its id or exact label. To draw a diagram in one call, use add_boxes with `connections` and `arrange: true`. \
    Box kinds: step, person, app, api, database, storage, cloud, email, payment, note (a sticky note). \
    Colours: sage, blue, orange, purple, rose, gold, teal, slate. Boxes are 196×62 points; x and y are box centres. \
    The person can undo your map changes with ⌘Z. Saved passwords are never available.
    """

    // MARK: Tool list

    static var specs: [AgentToolSpec] {
        let boxRef: [String: Any] = ["type": "string", "description": "A box id, or its exact label."]
        let mapTarget: [String: Any] = [
            "map_id": ["type": "string", "description": "The map's id (from list_projects or get_map)."],
            "project": ["type": "string", "description": "Instead of map_id: the project's id or name…"],
            "map": ["type": "string", "description": "…and the map's title. Optional when the project has one map."],
        ]
        func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
            var schema: [String: Any] = ["type": "object", "properties": properties]
            if !required.isEmpty { schema["required"] = required }
            return schema
        }
        let kind: [String: Any] = ["type": "string", "enum": NodeKind.allCases.map(\.rawValue)]
        let color: [String: Any] = ["type": "string", "enum": colors]
        let newBox = object([
            "label": ["type": "string", "description": "The box's name (or the sticky note's text)."],
            "kind": kind, "color": color,
            "notes": ["type": "string", "description": "Details shown when the box is selected."],
            "url": ["type": "string", "description": "Make this box a link: it's saved to the project's links and shows the site's logo."],
            "link_id": ["type": "string", "description": "Make this box show one of the project's existing links."],
            "x": ["type": "number"], "y": ["type": "number"],
            "ref": ["type": "string", "description": "A name for this box within this call, to use in `connections`."],
        ])
        let connection = object([
            "from": ["type": "string", "description": "A box id, exact label, or `ref` from this call."],
            "to": ["type": "string", "description": "A box id, exact label, or `ref` from this call."],
            "label": ["type": "string", "description": "e.g. \"deploys to\""],
            "dashed": ["type": "boolean"],
        ], required: ["from", "to"])

        return [
            AgentToolSpec(name: "list_projects", description: "Lists every project with its maps (box and connection counts) and number of links.",
                          inputSchema: object([:])),
            AgentToolSpec(name: "create_project", description: "Creates a project with an empty map called Overview.",
                          inputSchema: object(["name": ["type": "string"], "description": ["type": "string"], "color": color], required: ["name"])),
            AgentToolSpec(name: "get_map", description: "Returns a map in full: its boxes (with positions, notes, and links), connections, and groups.",
                          inputSchema: object(mapTarget)),
            AgentToolSpec(name: "create_map", description: "Adds a new, empty map to a project.",
                          inputSchema: object(["project": ["type": "string", "description": "The project's id or name."], "title": ["type": "string"]], required: ["project", "title"])),
            AgentToolSpec(name: "update_map",
                          description: "Renames a map, changes how its lines are drawn, or arranges it: `arrange: true` lays the boxes out in columns that follow the arrows (groups are refitted).",
                          inputSchema: object(mapTarget.merging([
                            "title": ["type": "string"],
                            "line_style": ["type": "string", "enum": ["elbow", "curved", "straight"]],
                            "arrange": ["type": "boolean"],
                          ]) { a, _ in a })),
            AgentToolSpec(name: "delete_map", description: "Deletes a map. The project's links are kept.", inputSchema: object(mapTarget)),
            AgentToolSpec(name: "add_boxes",
                          description: "Adds boxes to a map, optionally connecting them in the same call. Boxes without x/y are placed below what's already there; pass `arrange: true` to lay out the whole map automatically.",
                          inputSchema: object(mapTarget.merging([
                            "boxes": ["type": "array", "items": newBox],
                            "connections": ["type": "array", "items": connection],
                            "arrange": ["type": "boolean"],
                          ]) { a, _ in a }, required: ["boxes"])),
            AgentToolSpec(name: "update_boxes",
                          description: "Changes boxes: label, kind, colour, notes, or position. For a box that shows a link, the label and notes are the link's title and notes.",
                          inputSchema: object(mapTarget.merging([
                            "boxes": ["type": "array", "items": object([
                                "box": boxRef, "label": ["type": "string"], "kind": kind, "color": color,
                                "notes": ["type": "string"], "x": ["type": "number"], "y": ["type": "number"],
                            ], required: ["box"])],
                          ]) { a, _ in a }, required: ["boxes"])),
            AgentToolSpec(name: "delete_boxes", description: "Removes boxes (and their connections) from a map. Links shown by the boxes stay saved.",
                          inputSchema: object(mapTarget.merging(["boxes": ["type": "array", "items": boxRef]]) { a, _ in a }, required: ["boxes"])),
            AgentToolSpec(name: "connect",
                          description: "Connects boxes with arrows. Connecting two boxes that are already connected updates that line's label, style, and direction.",
                          inputSchema: object(mapTarget.merging(["connections": ["type": "array", "items": connection]]) { a, _ in a }, required: ["connections"])),
            AgentToolSpec(name: "delete_connections", description: "Removes connections, given by id or by their two boxes.",
                          inputSchema: object(mapTarget.merging([
                            "connections": ["type": "array", "items": object(["id": ["type": "string"], "from": boxRef, "to": boxRef])],
                          ]) { a, _ in a }, required: ["connections"])),
            AgentToolSpec(name: "add_group", description: "Draws a labelled frame around boxes, e.g. \"Backend\". Boxes inside a group move with it.",
                          inputSchema: object(mapTarget.merging([
                            "title": ["type": "string"], "boxes": ["type": "array", "items": boxRef], "color": color,
                          ]) { a, _ in a }, required: ["title", "boxes"])),
            AgentToolSpec(name: "delete_group", description: "Removes a group's frame, given by id or title. Its boxes stay.",
                          inputSchema: object(mapTarget.merging(["group": ["type": "string"]]) { a, _ in a }, required: ["group"])),
            AgentToolSpec(name: "list_links", description: "Lists a project's links (dashboards, repos, accounts, docs) with their notes and which maps show them. Passwords are never included.",
                          inputSchema: object(["project": ["type": "string", "description": "The project's id or name."]], required: ["project"])),
            AgentToolSpec(name: "add_link",
                          description: "Saves a link to a project. Its kind and name are guessed from the address unless given. Pass map_id to also put it on that map.",
                          inputSchema: object([
                            "project": ["type": "string"], "url": ["type": "string"], "title": ["type": "string"],
                            "kind": ["type": "string", "enum": EntryKind.linkKinds.map(\.agentName)],
                            "notes": ["type": "string"], "account": ["type": "string", "description": "An account label like an email address. Never a password."],
                            "environment": ["type": "string", "enum": ["Production", "Staging", "Development", "Shared"]],
                            "tags": ["type": "array", "items": ["type": "string"]],
                            "map_id": ["type": "string"],
                          ], required: ["project", "url"])),
            AgentToolSpec(name: "update_link", description: "Changes a link's title, address, notes, account label, environment, or tags.",
                          inputSchema: object([
                            "link_id": ["type": "string"], "title": ["type": "string"], "url": ["type": "string"], "notes": ["type": "string"],
                            "account": ["type": "string"], "environment": ["type": "string"], "tags": ["type": "array", "items": ["type": "string"]],
                          ], required: ["link_id"])),
        ]
    }

    // MARK: Running

    /// Runs a tool against `workspace`, changing it in place. Throws `Failure` with a message the agent can act on.
    static func run(_ name: String, _ args: [String: Any], in workspace: inout Workspace) throws -> Result {
        switch name {
        case "list_projects":
            let projects = workspace.projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map { project in
                [
                    "id": project.id.uuidString, "name": project.name, "description": project.summary, "status": project.status.rawValue,
                    "links": workspace.entries.filter { $0.projectID == project.id && EntryKind.linkKinds.contains($0.kind) }.count,
                    "maps": workspace.diagrams.filter { $0.projectID == project.id }.map {
                        ["id": $0.id.uuidString, "title": $0.title, "boxes": $0.nodes.count, "connections": $0.edges.count, "groups": $0.groups.count] as [String: Any]
                    },
                ] as [String: Any]
            }
            return Result(value: ["projects": projects], summary: "Read the project list")

        case "create_project":
            let name = try text(args, "name", required: true)!
            var project = Project(name: name)
            project.summary = try text(args, "description") ?? ""
            if let color = try colorArg(args) { project.color = color }
            let map = Diagram(projectID: project.id, title: "Overview")
            workspace.projects.append(project)
            workspace.diagrams.append(map)
            return Result(value: ["project_id": project.id.uuidString, "map_id": map.id.uuidString], summary: "Created the project \(name)")

        case "get_map":
            let index = try mapIndex(args, in: workspace)
            return Result(value: describe(workspace.diagrams[index], in: workspace), summary: "Read \(workspace.diagrams[index].title)")

        case "create_map":
            let project = try findProject(args["project"], in: workspace)
            let title = try text(args, "title", required: true)!
            let map = Diagram(projectID: project.id, title: title)
            workspace.diagrams.append(map)
            return Result(value: ["map_id": map.id.uuidString], summary: "Created the map \(title) in \(project.name)")

        case "update_map":
            let index = try mapIndex(args, in: workspace)
            var changes: [String] = []
            if let title = try text(args, "title") { workspace.diagrams[index].title = title; changes.append("renamed") }
            if let style = try text(args, "line_style") {
                guard let value = LineStyle.allCases.first(where: { $0.rawValue.lowercased() == style.lowercased() }) else {
                    throw Failure("line_style must be elbow, curved, or straight.")
                }
                workspace.diagrams[index].lineStyle = value; changes.append("\(style) lines")
            }
            if args["arrange"] as? Bool == true { workspace.diagrams[index] = arrange(workspace.diagrams[index]); changes.append("arranged") }
            guard !changes.isEmpty else { throw Failure("Nothing to change: pass title, line_style, or arrange.") }
            return Result(value: describe(workspace.diagrams[index], in: workspace),
                          summary: "Updated \(workspace.diagrams[index].title) (\(changes.joined(separator: ", ")))")

        case "delete_map":
            let index = try mapIndex(args, in: workspace)
            let map = workspace.diagrams.remove(at: index)
            return Result(value: ["deleted": map.id.uuidString], summary: "Deleted the map \(map.title)")

        case "add_boxes":
            return try addBoxes(args, in: &workspace)

        case "update_boxes":
            let index = try mapIndex(args, in: workspace)
            let changes = try list(args, "boxes")
            for change in changes {
                guard let reference = change["box"] as? String else { throw Failure("Each item in boxes needs `box`: a box id or label.") }
                let boxIndex = try findBox(reference, in: workspace.diagrams[index], workspace: workspace)
                var node = workspace.diagrams[index].nodes[boxIndex]
                let label = try text(change, "label"), notes = try text(change, "notes", allowEmpty: true)
                if let entryID = node.entryID, let entryIndex = workspace.entries.firstIndex(where: { $0.id == entryID }) {
                    if let label { workspace.entries[entryIndex].title = label; node.label = label }
                    if let notes { workspace.entries[entryIndex].body = notes }
                    if label != nil || notes != nil { workspace.entries[entryIndex].updatedAt = Date() }
                } else {
                    if let label { node.label = label }
                    if let notes { node.notes = notes }
                }
                if let kind = try kindArg(change) { node.kind = kind; node.color = "" }
                if let color = try colorArg(change) { node.color = color }
                if let point = point(change, default: CGPoint(x: node.x, y: node.y)) { node.x = point.x; node.y = point.y }
                let kept = DiagramLayout.clamp(CGPoint(x: node.x, y: node.y), for: node)
                node.x = kept.x; node.y = kept.y
                workspace.diagrams[index].nodes[boxIndex] = node
            }
            return Result(value: describe(workspace.diagrams[index], in: workspace),
                          summary: "Updated \(count(changes.count, "box", "boxes")) on \(workspace.diagrams[index].title)")

        case "delete_boxes":
            let index = try mapIndex(args, in: workspace)
            guard let references = args["boxes"] as? [String], !references.isEmpty else { throw Failure("boxes must be a list of box ids or labels.") }
            let ids = try Set(references.map { workspace.diagrams[index].nodes[try findBox($0, in: workspace.diagrams[index], workspace: workspace)].id })
            workspace.diagrams[index].edges.removeAll { ids.contains($0.from) || ids.contains($0.to) }
            workspace.diagrams[index].nodes.removeAll { ids.contains($0.id) }
            return Result(value: ["deleted": ids.map(\.uuidString)], summary: "Removed \(count(ids.count, "box", "boxes")) from \(workspace.diagrams[index].title)")

        case "connect":
            let index = try mapIndex(args, in: workspace)
            let ids = try connect(try list(args, "connections"), in: &workspace.diagrams[index], refs: [:], workspace: workspace)
            return Result(value: ["connections": ids.map(\.uuidString)], summary: "Made \(count(ids.count, "connection", "connections")) on \(workspace.diagrams[index].title)")

        case "delete_connections":
            let index = try mapIndex(args, in: workspace)
            var removed = 0
            for item in try list(args, "connections") {
                let diagram = workspace.diagrams[index]
                let edgeID: UUID?
                if let id = (item["id"] as? String).flatMap(UUID.init(uuidString:)) {
                    edgeID = diagram.edges.first { $0.id == id }?.id
                } else if let from = item["from"] as? String, let to = item["to"] as? String {
                    let a = diagram.nodes[try findBox(from, in: diagram, workspace: workspace)].id, b = diagram.nodes[try findBox(to, in: diagram, workspace: workspace)].id
                    edgeID = diagram.edges.first { ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a) }?.id
                } else { throw Failure("Each connection needs an id, or from and to.") }
                guard let edgeID else { throw Failure("No such connection on this map.") }
                workspace.diagrams[index].edges.removeAll { $0.id == edgeID }
                removed += 1
            }
            return Result(value: ["deleted": removed], summary: "Removed \(count(removed, "connection", "connections")) from \(workspace.diagrams[index].title)")

        case "add_group":
            let index = try mapIndex(args, in: workspace)
            let title = try text(args, "title", required: true)!
            guard let references = args["boxes"] as? [String], !references.isEmpty else { throw Failure("boxes must list the boxes to group.") }
            let diagram = workspace.diagrams[index]
            let nodes = try references.map { diagram.nodes[try findBox($0, in: diagram, workspace: workspace)] }
            let group = DiagramLayout.clamp(DiagramLayout.group(around: nodes, or: .zero, title: title,
                                                                color: try colorArg(args) ?? colors[diagram.groups.count % colors.count]))
            workspace.diagrams[index].groups.append(group)
            // A group is a frame: anything sitting between the boxes ends up inside too, so say what's in it.
            let inside = DiagramLayout.members(of: group, in: workspace.diagrams[index])
            let labels = inside.compactMap { id in try? findLabel(id, in: workspace.diagrams[index], workspace: workspace) }
            var value: [String: Any] = ["group_id": group.id.uuidString, "boxes_inside": labels]
            if inside.count > nodes.count {
                value["note"] = "The frame also covers boxes that sit between the ones you named. Move them, or use update_map with arrange: true first."
            }
            return Result(value: value, summary: "Grouped \(count(nodes.count, "box", "boxes")) as \(title)")

        case "delete_group":
            let index = try mapIndex(args, in: workspace)
            let reference = try text(args, "group", required: true)!
            let groups = workspace.diagrams[index].groups
            guard let group = groups.first(where: { $0.id.uuidString.caseInsensitiveCompare(reference) == .orderedSame })
                    ?? groups.first(where: { $0.title.caseInsensitiveCompare(reference) == .orderedSame }) else { throw Failure("No group called \(reference) on this map.") }
            workspace.diagrams[index].groups.removeAll { $0.id == group.id }
            return Result(value: ["deleted": group.id.uuidString], summary: "Removed the group \(group.title.isEmpty ? "Untitled" : group.title)")

        case "list_links":
            let project = try findProject(args["project"], in: workspace)
            let links = workspace.entries.filter { $0.projectID == project.id && EntryKind.linkKinds.contains($0.kind) }
                .sorted { $0.title.lowercased() < $1.title.lowercased() }
                .map { describe($0, in: workspace) }
            return Result(value: ["links": links], summary: "Read \(project.name)'s links")

        case "add_link":
            let project = try findProject(args["project"], in: workspace)
            let url = try text(args, "url", required: true)!
            guard var entry = Entry.quick(url: url, projectID: project.id) else { throw Failure("\(url) isn't a web address (use https://…).") }
            try fill(&entry, from: args)
            if let kind = try text(args, "kind") {
                guard let value = EntryKind.linkKinds.first(where: { $0.agentName == kind.lowercased() }) else {
                    throw Failure("kind must be one of: \(EntryKind.linkKinds.map(\.agentName).joined(separator: ", ")).")
                }
                entry.kind = value
            }
            workspace.entries.append(entry)
            var value: [String: Any] = ["link_id": entry.id.uuidString, "title": entry.title, "kind": entry.kind.agentName]
            if args["map_id"] != nil {
                let index = try mapIndex(["map_id": args["map_id"]!], in: workspace)
                guard workspace.diagrams[index].projectID == project.id else { throw Failure("That map belongs to another project.") }
                let spot = DiagramLayout.freeSpot(near: placementStart(workspace.diagrams[index]), in: workspace.diagrams[index])
                let node = DiagramNode(label: entry.title, entryID: entry.id, x: spot.x, y: spot.y)
                workspace.diagrams[index].nodes.append(node)
                value["box_id"] = node.id.uuidString
            }
            return Result(value: value, summary: "Saved the link \(entry.title) to \(project.name)")

        case "update_link":
            guard let id = (args["link_id"] as? String).flatMap(UUID.init(uuidString:)),
                  let index = workspace.entries.firstIndex(where: { $0.id == id && EntryKind.linkKinds.contains($0.kind) }) else {
                throw Failure("No link with that link_id. Use list_links to find it.")
            }
            try fill(&workspace.entries[index], from: args)
            if let url = try text(args, "url") {
                guard let valid = webURL(url.contains("://") ? url : "https://" + url) else { throw Failure("\(url) isn't a web address.") }
                workspace.entries[index].url = valid.absoluteString
            }
            workspace.entries[index].updatedAt = Date()
            return Result(value: describe(workspace.entries[index], in: workspace), summary: "Updated the link \(workspace.entries[index].title)")

        default:
            throw Failure("Unknown tool \(name).")
        }
    }

    // MARK: Boxes and connections

    static func addBoxes(_ args: [String: Any], in workspace: inout Workspace) throws -> Result {
        let index = try mapIndex(args, in: workspace)
        let items = try list(args, "boxes")
        guard !items.isEmpty, items.count <= 200 else { throw Failure("Pass between 1 and 200 boxes.") }
        let projectID = workspace.diagrams[index].projectID
        var refs: [String: UUID] = [:]
        var added: [[String: Any]] = []
        var autoPlaced = 0
        let start = placementStart(workspace.diagrams[index])
        for item in items {
            var node = DiagramNode(label: try text(item, "label") ?? "", x: 0, y: 0, kind: try kindArg(item) ?? .step)
            node.notes = try text(item, "notes", allowEmpty: true) ?? ""
            if let color = try colorArg(item) { node.color = color }
            if let url = try text(item, "url") {
                // Reuse a link the project already has for the same address.
                let existing = workspace.entries.first { $0.projectID == projectID && EntryKind.linkKinds.contains($0.kind) && sameAddress($0.url, url) }
                if let existing {
                    node.entryID = existing.id
                } else {
                    guard var entry = Entry.quick(url: url, projectID: projectID) else { throw Failure("\(url) isn't a web address (use https://…).") }
                    if !node.label.isEmpty { entry.title = node.label }
                    if !node.notes.isEmpty { entry.body = node.notes; node.notes = "" }
                    workspace.entries.append(entry)
                    node.entryID = entry.id
                }
            } else if let linkID = item["link_id"] as? String {
                guard let id = UUID(uuidString: linkID), let entry = workspace.entries.first(where: { $0.id == id && $0.projectID == projectID }) else {
                    throw Failure("No link \(linkID) in this project. Use list_links.")
                }
                node.entryID = entry.id
            }
            if let entryID = node.entryID { node.label = workspace.entries.first { $0.id == entryID }?.title ?? node.label }
            guard node.entryID != nil || !node.label.isEmpty || node.kind == .note else { throw Failure("Each box needs a label, url, or link_id.") }
            if let point = point(item, default: nil) {
                node.x = point.x; node.y = point.y
            } else {
                let column = autoPlaced % 5, row = autoPlaced / 5
                let spot = DiagramLayout.freeSpot(near: CGPoint(x: start.x + Double(column) * 250, y: start.y + Double(row) * 120), in: workspace.diagrams[index])
                node.x = spot.x; node.y = spot.y
                autoPlaced += 1
            }
            let kept = DiagramLayout.clamp(CGPoint(x: node.x, y: node.y), for: node)
            node.x = kept.x; node.y = kept.y
            workspace.diagrams[index].nodes.append(node)
            var summary: [String: Any] = ["id": node.id.uuidString, "label": node.label]
            if let ref = item["ref"] as? String, !ref.isEmpty { refs[ref.lowercased()] = node.id; summary["ref"] = ref }
            if let entryID = node.entryID { summary["link_id"] = entryID.uuidString }
            added.append(summary)
        }
        var connectionIDs: [UUID] = []
        if let connections = args["connections"] as? [[String: Any]], !connections.isEmpty {
            connectionIDs = try connect(connections, in: &workspace.diagrams[index], refs: refs, workspace: workspace)
        }
        if args["arrange"] as? Bool == true { workspace.diagrams[index] = arrange(workspace.diagrams[index]) }
        let positions = Dictionary(uniqueKeysWithValues: workspace.diagrams[index].nodes.map { ($0.id.uuidString, ($0.x, $0.y)) })
        added = added.map { box in
            var box = box
            if let id = box["id"] as? String, let p = positions[id] { box["x"] = p.0; box["y"] = p.1 }
            return box
        }
        var summary = "Added \(count(items.count, "box", "boxes")) to \(workspace.diagrams[index].title)"
        if !connectionIDs.isEmpty { summary += " with \(count(connectionIDs.count, "connection", "connections"))" }
        return Result(value: ["boxes": added, "connections": connectionIDs.map(\.uuidString)], summary: summary)
    }

    /// Adds or updates connections. Returns their ids.
    static func connect(_ items: [[String: Any]], in diagram: inout Diagram, refs: [String: UUID], workspace: Workspace) throws -> [UUID] {
        var ids: [UUID] = []
        for item in items {
            guard let fromRef = item["from"] as? String, let toRef = item["to"] as? String else { throw Failure("Each connection needs from and to.") }
            let from = try refs[fromRef.lowercased()] ?? diagram.nodes[try findBox(fromRef, in: diagram, workspace: workspace)].id
            let to = try refs[toRef.lowercased()] ?? diagram.nodes[try findBox(toRef, in: diagram, workspace: workspace)].id
            guard from != to else { throw Failure("A box can't connect to itself (\(fromRef)).") }
            let label = try text(item, "label", allowEmpty: true)
            if let existing = diagram.edges.firstIndex(where: { ($0.from == from && $0.to == to) || ($0.from == to && $0.to == from) }) {
                diagram.edges[existing].from = from; diagram.edges[existing].to = to
                if let label { diagram.edges[existing].label = label }
                if let dashed = item["dashed"] as? Bool { diagram.edges[existing].dashed = dashed }
                ids.append(diagram.edges[existing].id)
            } else {
                let edge = DiagramEdge(from: from, to: to, label: label ?? "", dashed: item["dashed"] as? Bool ?? false)
                diagram.edges.append(edge)
                ids.append(edge.id)
            }
        }
        return ids
    }

    /// Lays the boxes out in columns that follow the arrows, then refits each group around the boxes it had.
    static func arrange(_ diagram: Diagram) -> Diagram {
        let members = Dictionary(uniqueKeysWithValues: diagram.groups.map { ($0.id, Set(DiagramLayout.members(of: $0, in: diagram))) })
        var result = DiagramLayout.tidy(diagram)
        for index in result.nodes.indices {
            let kept = DiagramLayout.clamp(CGPoint(x: result.nodes[index].x, y: result.nodes[index].y), for: result.nodes[index])
            result.nodes[index].x = kept.x; result.nodes[index].y = kept.y
        }
        for index in result.groups.indices {
            let inside = result.nodes.filter { members[result.groups[index].id]?.contains($0.id) == true }
            guard !inside.isEmpty else { continue }
            var fitted = DiagramLayout.group(around: inside, or: .zero)
            fitted.id = result.groups[index].id; fitted.title = result.groups[index].title; fitted.color = result.groups[index].color
            result.groups[index] = DiagramLayout.clamp(fitted)
        }
        return result
    }

    /// Where boxes without a position go: below everything already on the map.
    static func placementStart(_ diagram: Diagram) -> CGPoint {
        guard let bounds = DiagramLayout.contentBounds(diagram) else { return CGPoint(x: 300, y: 200) }
        return DiagramLayout.clamp(CGPoint(x: DiagramLayout.snap(bounds.minX + 98), y: DiagramLayout.snap(bounds.maxY + 110)))
    }

    // MARK: Lookups

    static func findProject(_ reference: Any?, in workspace: Workspace) throws -> Project {
        guard let reference = reference as? String, !reference.isEmpty else {
            if workspace.projects.count == 1 { return workspace.projects[0] }
            throw Failure("Say which project: its id or name. Use list_projects.")
        }
        if let id = UUID(uuidString: reference), let project = workspace.projects.first(where: { $0.id == id }) { return project }
        let named = workspace.projects.filter { $0.name.caseInsensitiveCompare(reference) == .orderedSame }
        if named.count == 1 { return named[0] }
        if named.count > 1 { throw Failure("More than one project is called \(reference); use its id.") }
        throw Failure("No project called \(reference). Projects: \(workspace.projects.map(\.name).joined(separator: ", ")).")
    }

    static func mapIndex(_ args: [String: Any], in workspace: Workspace) throws -> Int {
        if let mapID = args["map_id"] as? String {
            guard let id = UUID(uuidString: mapID), let index = workspace.diagrams.firstIndex(where: { $0.id == id }) else {
                throw Failure("No map with id \(mapID). Use list_projects to see maps.")
            }
            return index
        }
        let project = try findProject(args["project"], in: workspace)
        let maps = workspace.diagrams.indices.filter { workspace.diagrams[$0].projectID == project.id }
        if let title = args["map"] as? String, !title.isEmpty {
            guard let index = maps.first(where: { workspace.diagrams[$0].title.caseInsensitiveCompare(title) == .orderedSame }) else {
                throw Failure("\(project.name) has no map called \(title). Its maps: \(maps.map { workspace.diagrams[$0].title }.joined(separator: ", ")).")
            }
            return index
        }
        guard maps.count == 1 else {
            throw Failure(maps.isEmpty ? "\(project.name) has no maps yet; use create_map." : "\(project.name) has several maps; say which with `map` or map_id.")
        }
        return maps[0]
    }

    /// A box by id, or by its label (or the title of the link it shows), ignoring case.
    static func findBox(_ reference: String, in diagram: Diagram, workspace: Workspace) throws -> Int {
        if let id = UUID(uuidString: reference), let index = diagram.nodes.firstIndex(where: { $0.id == id }) { return index }
        let matches = diagram.nodes.indices.filter { index in
            let node = diagram.nodes[index]
            let title = node.entryID.flatMap { id in workspace.entries.first { $0.id == id }?.title } ?? node.label
            return title.caseInsensitiveCompare(reference) == .orderedSame
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw Failure("More than one box is labelled \(reference); use its id from get_map.") }
        throw Failure("No box \(reference) on \(diagram.title). Use get_map to see the boxes.")
    }

    static func findLabel(_ id: UUID, in diagram: Diagram, workspace: Workspace) throws -> String {
        guard let node = diagram.nodes.first(where: { $0.id == id }) else { throw Failure("No such box.") }
        return node.entryID.flatMap { entryID in workspace.entries.first { $0.id == entryID }?.title } ?? node.label
    }

    // MARK: Descriptions

    static func describe(_ diagram: Diagram, in workspace: Workspace) -> [String: Any] {
        let groupOf = Dictionary(diagram.groups.flatMap { group in DiagramLayout.members(of: group, in: diagram).map { ($0, group.title) } }, uniquingKeysWith: { a, _ in a })
        let labels = Dictionary(uniqueKeysWithValues: diagram.nodes.map { node in
            (node.id, node.entryID.flatMap { id in workspace.entries.first { $0.id == id }?.title } ?? node.label)
        })
        let boxes: [[String: Any]] = diagram.nodes.map { node in
            var box: [String: Any] = ["id": node.id.uuidString, "label": labels[node.id] ?? "", "kind": node.kind.rawValue, "x": node.x, "y": node.y]
            if !node.color.isEmpty { box["color"] = node.color }
            if let group = groupOf[node.id] { box["group"] = group }
            if let entryID = node.entryID {
                if let entry = workspace.entries.first(where: { $0.id == entryID }) {
                    box["link"] = ["id": entry.id.uuidString, "url": entry.url, "kind": entry.kind.agentName]
                    if !entry.body.isEmpty { box["notes"] = entry.body }
                } else {
                    box["link"] = ["deleted": true]
                }
            } else if !node.notes.isEmpty {
                box["notes"] = node.notes
            }
            return box
        }
        return [
            "id": diagram.id.uuidString, "title": diagram.title, "project": workspace.projects.first { $0.id == diagram.projectID }?.name ?? "",
            "line_style": diagram.lineStyle.rawValue.lowercased(), "boxes": boxes,
            "connections": diagram.edges.map { edge in
                var line: [String: Any] = ["id": edge.id.uuidString, "from": edge.from.uuidString, "to": edge.to.uuidString,
                                           "from_label": labels[edge.from] ?? "", "to_label": labels[edge.to] ?? ""]
                if !edge.label.isEmpty { line["label"] = edge.label }
                if edge.dashed { line["dashed"] = true }
                return line
            },
            "groups": diagram.groups.map { group in
                ["id": group.id.uuidString, "title": group.title, "color": group.color,
                 "boxes": DiagramLayout.members(of: group, in: diagram).map(\.uuidString)] as [String: Any]
            },
        ]
    }

    static func describe(_ entry: Entry, in workspace: Workspace) -> [String: Any] {
        var link: [String: Any] = ["id": entry.id.uuidString, "title": entry.title, "kind": entry.kind.agentName, "url": entry.url]
        if !entry.body.isEmpty { link["notes"] = entry.body }
        if !entry.account.isEmpty { link["account"] = entry.account }
        if !entry.environment.isEmpty { link["environment"] = entry.environment }
        if !entry.tags.isEmpty { link["tags"] = entry.tags }
        if !entry.credentials.isEmpty { link["saved_passwords"] = entry.credentials.count }
        let maps = workspace.diagrams.filter { $0.nodes.contains { $0.entryID == entry.id } }.map(\.title)
        if !maps.isEmpty { link["on_maps"] = maps }
        return link
    }

    // MARK: Arguments

    static func text(_ args: [String: Any], _ key: String, required: Bool = false, allowEmpty: Bool = false) throws -> String? {
        guard let raw = args[key] else {
            if required { throw Failure("\(key) is required.") }
            return nil
        }
        guard let value = raw as? String else { throw Failure("\(key) must be text.") }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && !allowEmpty {
            if required { throw Failure("\(key) can't be empty.") }
            return nil
        }
        return trimmed
    }

    static func list(_ args: [String: Any], _ key: String) throws -> [[String: Any]] {
        guard let items = args[key] as? [[String: Any]] else { throw Failure("\(key) must be a list of objects.") }
        return items
    }

    static func point(_ args: [String: Any], default fallback: CGPoint?) -> CGPoint? {
        let x = (args["x"] as? NSNumber)?.doubleValue, y = (args["y"] as? NSNumber)?.doubleValue
        guard x != nil || y != nil else { return nil }
        guard let px = x ?? fallback.map({ Double($0.x) }), let py = y ?? fallback.map({ Double($0.y) }) else { return nil }
        let clamped = DiagramLayout.clamp(CGPoint(x: px, y: py))
        return CGPoint(x: DiagramLayout.snap(clamped.x), y: DiagramLayout.snap(clamped.y))
    }

    static func kindArg(_ args: [String: Any]) throws -> NodeKind? {
        guard let raw = try text(args, "kind")?.lowercased() else { return nil }
        let synonyms: [String: NodeKind] = [
            "box": .step, "process": .step, "user": .person, "people": .person, "customer": .person, "site": .app, "website": .app,
            "frontend": .app, "web": .app, "server": .api, "backend": .api, "service": .api, "db": .database, "bucket": .storage,
            "files": .storage, "external": .cloud, "third-party": .cloud, "mail": .email, "payments": .payment, "billing": .payment,
            "sticky": .note, "sticky note": .note, "text": .note,
        ]
        if let kind = NodeKind(rawValue: raw) ?? synonyms[raw] { return kind }
        throw Failure("Unknown kind \(raw). Use one of: \(NodeKind.allCases.map(\.rawValue).joined(separator: ", ")).")
    }

    static func colorArg(_ args: [String: Any]) throws -> String? {
        guard let raw = try text(args, "color")?.lowercased() else { return nil }
        let synonyms = ["green": "sage", "red": "rose", "pink": "rose", "yellow": "gold", "amber": "gold", "violet": "purple",
                        "grey": "slate", "gray": "slate", "cyan": "teal", "emerald": "sage"]
        let color = synonyms[raw] ?? raw
        guard colors.contains(color) else { throw Failure("Unknown color \(raw). Use one of: \(colors.joined(separator: ", ")).") }
        return color
    }

    static func fill(_ entry: inout Entry, from args: [String: Any]) throws {
        if let title = try text(args, "title") { entry.title = title }
        if let notes = try text(args, "notes", allowEmpty: true) { entry.body = notes }
        if let account = try text(args, "account", allowEmpty: true) { entry.account = account }
        if let environment = try text(args, "environment", allowEmpty: true) { entry.environment = environment }
        if let tags = args["tags"] as? [String] { entry.tags = tags.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty } }
    }

    static func sameAddress(_ a: String, _ b: String) -> Bool {
        func normal(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "www.", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return normal(a) == normal(b)
    }

    static func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
}

extension EntryKind {
    /// The kind's name in agent tools.
    var agentName: String {
        switch self {
        case .link: return "website"
        case .repository: return "repository"
        case .document: return "document"
        case .conversation: return "ai_chat"
        case .service: return "service"
        case .social: return "social"
        case .note: return "note"
        case .prompt: return "prompt"
        }
    }
}
