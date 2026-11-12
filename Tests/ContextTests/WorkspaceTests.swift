import Foundation
import AppKit
import EventKit

final class WorkspaceTests {
    var cleanup: [() -> Void] = []
    func addTeardownBlock(_ block: @escaping () -> Void) { cleanup.append(block) }
    func finish() { cleanup.forEach { $0() }; cleanup = [] }

    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ContextTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testWorkspaceRoundTripAndPreviousVersionBackup() throws {
        let disk = WorkspaceDisk(directory: try temporaryDirectory())
        let project = Project(name: "Ayuvam")
        var first = Workspace()
        first.projects = [project]
        first.entries = [Entry(projectID: project.id, kind: .note, title: "Deployment", body: "Local context")]
        try disk.save(first)
        XCTAssertEqual(try disk.load(), first)
        var second = first
        second.projects[0].summary = "Design agency"
        try disk.save(second)
        XCTAssertEqual(try disk.load(), second)
        XCTAssertEqual(try disk.decode(Data(contentsOf: disk.backup)), first)
    }

    func testCorruptDataIsNotSilentlyReplaced() throws {
        let disk = WorkspaceDisk(directory: try temporaryDirectory())
        let corrupt = Data("invalid json".utf8)
        try corrupt.write(to: disk.file)
        XCTAssertThrowsError(try disk.load())
        XCTAssertThrowsError(try disk.save(Workspace()))
        XCTAssertEqual(try Data(contentsOf: disk.file), corrupt)
    }

    func testInvalidReferencesAndVersionsRejected() throws {
        var workspace = Workspace()
        workspace.version = 3
        XCTAssertThrowsError(try workspace.validated())
        XCTAssertThrowsError(try WorkspaceDisk(directory: try temporaryDirectory()).decode(Data(#"{"version": 3}"#.utf8)))
        workspace.version = Workspace.currentVersion
        workspace.tasks = [WorkTask(projectID: UUID(), title: "Orphan")]
        XCTAssertThrowsError(try workspace.validated())
        var clientless = Workspace()
        clientless.projects = [Project(name: "Lost", clientID: UUID())]
        XCTAssertThrowsError(try clientless.validated())
    }

    func testVersionOneDataMigrates() throws {
        let project = UUID(), second = UUID(), task = UUID()
        let json = """
        {"version": 1,
         "projects": [
           {"id": "\(project)", "name": "Presently", "summary": "", "kind": "Product", "client": "Acme", "color": "blue",
            "sections": ["Overview", "Tasks", "Notes"], "createdAt": 0},
           {"id": "\(second)", "name": "Site", "summary": "", "kind": "Client", "client": "acme", "color": "sage",
            "sections": ["Overview"], "createdAt": 0}],
         "entries": [], "folders": [],
         "tasks": [{"id": "\(task)", "projectID": "\(project)", "title": "Backup", "details": "", "due": 0,
                    "recurrence": "Every 3 days", "remind": true, "completionHistory": [], "platform": ""}]}
        """
        let workspace = try WorkspaceDisk(directory: try temporaryDirectory()).decode(Data(json.utf8))
        XCTAssertEqual(workspace.version, Workspace.currentVersion)
        XCTAssertEqual(workspace.clients.count, 1)
        XCTAssertEqual(workspace.clients[0].name, "Acme")
        XCTAssertEqual(workspace.projects[0].clientID, workspace.clients[0].id)
        XCTAssertEqual(workspace.projects[1].clientID, workspace.clients[0].id)
        XCTAssertEqual(workspace.tasks[0].repeatRule, RepeatRule(kind: .everyNDays, interval: 3))
        XCTAssertEqual(workspace.tasks[0].reminderLead, 0)
        // Saving and reloading keeps the migrated shape without legacy fields.
        let disk = WorkspaceDisk(directory: try temporaryDirectory())
        try disk.save(workspace)
        XCTAssertEqual(try disk.load(), workspace)
        XCTAssertFalse(String(decoding: try Data(contentsOf: disk.file), as: UTF8.self).contains("\"client\""))
    }

    func testProjectsKeepTheirPictureListAndOldFields() throws {
        // A project saved by an earlier version, with tabs ("sections") and an Overview note, still loads.
        let id = UUID()
        let json = """
        {"id": "\(id)", "name": "Ayuvam", "summary": "", "kind": "Brand", "color": "sage", "contextNote": "Where things stand",
         "sections": [{"section": "Overview", "title": "", "enabled": true}, {"section": "Map", "title": "", "enabled": true}],
         "createdAt": 0}
        """
        var project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        XCTAssertEqual(project.name, "Ayuvam")
        XCTAssertEqual(project.contextNote, "Where things stand")
        XCTAssertNil(project.image)
        XCTAssertNil(project.remindersListID)
        // A picture and an Apple Reminders list survive a save and reload, and old tab settings are dropped.
        let pixel = NSImage(size: NSSize(width: 600, height: 300), flipped: false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
        project.image = ProjectImage.prepare(pixel)
        project.remindersListID = "list-123"
        var workspace = Workspace()
        workspace.projects = [project]
        let disk = WorkspaceDisk(directory: try temporaryDirectory())
        try disk.save(workspace)
        let reloaded = try disk.load()
        XCTAssertEqual(reloaded.projects[0].image, project.image)
        XCTAssertEqual(reloaded.projects[0].remindersListID, "list-123")
        XCTAssertFalse(String(decoding: try Data(contentsOf: disk.file), as: UTF8.self).contains("\"sections\""))
    }

    func testProjectPicturesAreSmallSquares() throws {
        func render(_ size: NSSize, alpha: Bool) -> NSImage {
            NSImage(size: size, flipped: false) { rect in
                (alpha ? NSColor.clear : NSColor.white).setFill(); rect.fill()
                NSColor.systemRed.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 20, dy: 20)).fill()
                return true
            }
        }
        // A wide photo becomes a 256 px square JPEG; a logo with transparency keeps it as PNG.
        let photo = try XCTUnwrap(ProjectImage.prepare(render(NSSize(width: 1600, height: 900), alpha: false)))
        let photoRep = try XCTUnwrap(NSBitmapImageRep(data: photo))
        XCTAssertTrue(photoRep.pixelsWide <= ProjectImage.side * 2 && photoRep.pixelsWide == photoRep.pixelsHigh)
        let logo = try XCTUnwrap(ProjectImage.prepare(render(NSSize(width: 120, height: 60), alpha: true)))
        XCTAssertEqual(Array(logo.prefix(4)), [0x89, 0x50, 0x4E, 0x47]) // PNG signature
        XCTAssertTrue(photo.count < 120_000 && logo.count < 120_000)
    }

    func testQuickReminderReadsDatesFromText() {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        let dated = QuickReminderParser.parse("Renew domain tomorrow")
        XCTAssertEqual(dated.title, "Renew domain")
        XCTAssertEqual(dated.due, tomorrow)
        XCTAssertFalse(dated.hasTime)
        let timed = QuickReminderParser.parse("Call Riya tomorrow at 5pm")
        XCTAssertEqual(timed.title, "Call Riya")
        XCTAssertTrue(timed.hasTime)
        XCTAssertEqual(timed.due.map { calendar.component(.hour, from: $0) }, 17)
        XCTAssertEqual(timed.due.map { calendar.startOfDay(for: $0) }, tomorrow)
        // No date: the text is the title. Only a date: kept as the title rather than leaving it empty.
        XCTAssertEqual(QuickReminderParser.parse("  Update the pricing page  "), QuickReminder(title: "Update the pricing page"))
        XCTAssertEqual(QuickReminderParser.parse("tomorrow").title, "tomorrow")
        XCTAssertNil(QuickReminderParser.parse("tomorrow").due)
    }

    func testRepeatOptionsMatchAppleReminders() {
        for option in RepeatOption.choices {
            XCTAssertEqual(RepeatOption(rules: option.rule.map { [$0] }), option)
        }
        XCTAssertEqual(RepeatOption(rules: [EKRecurrenceRule(recurrenceWith: .daily, interval: 3, end: nil)]), .custom)
        XCTAssertNil(RepeatOption.custom.rule)
        // Tasks from earlier versions keep their schedule when they move to Apple Reminders.
        XCTAssertEqual(RepeatOption.rule(for: RepeatRule(kind: .everyNDays, interval: 3))?.interval, 3)
        XCTAssertEqual(RepeatOption.rule(for: RepeatRule(kind: .weekly, weekdays: [2, 4]))?.daysOfTheWeek?.map { $0.dayOfTheWeek.rawValue }, [2, 4])
        XCTAssertNil(RepeatOption.rule(for: RepeatRule(kind: .afterCompletion, interval: 2)))
        // Date-only reminders are floating days; timed ones carry the hour and timezone.
        let due = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 17, minute: 30))!
        XCTAssertNil(DateComponents.reminderDue(due, hasTime: false).hour)
        XCTAssertEqual(DateComponents.reminderDue(due, hasTime: true).hour, 17)
        XCTAssertNotNil(DateComponents.reminderDue(due, hasTime: true).timeZone)
    }

    func testRemindersSortAndCountWhatsDue() {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!
        let today = Calendar.current.startOfDay(for: now)
        let overdue = ReminderItem(listID: "a", title: "Late", due: today.addingTimeInterval(-86_400))
        let dueToday = ReminderItem(listID: "a", title: "Today", due: today)
        let laterToday = ReminderItem(listID: "a", title: "Tonight", due: now.addingTimeInterval(3_600 * 8), hasTime: true)
        let nextWeek = ReminderItem(listID: "a", title: "Later", due: today.addingTimeInterval(86_400 * 7))
        let undated = ReminderItem(listID: "a", title: "Someday")
        let done = ReminderItem(listID: "a", title: "Done", due: today, isCompleted: true)
        let sorted = [undated, nextWeek, laterToday, dueToday, overdue].sorted(by: ReminderItem.order)
        XCTAssertEqual(sorted.map(\.title), ["Late", "Today", "Tonight", "Later", "Someday"])
        XCTAssertEqual([overdue, dueToday, laterToday, nextWeek, undated, done].filter { $0.needsAttention(now: now) }.map(\.title), ["Late", "Today", "Tonight"])
        XCTAssertTrue(overdue.isOverdue(now: now))
        XCTAssertFalse(dueToday.isOverdue(now: now))   // A date-only reminder isn't overdue until the day has passed.
    }

    func testBoxesStayOnTheCanvas() throws {
        // A tall sticky note centred near the top would hang off the canvas, where it can't be reached or grabbed.
        let note = DiagramNode(label: String(repeating: "A long line of notes about how it all works. ", count: 12), x: 1950, y: 150, kind: .note)
        let height = DiagramLayout.size(of: note).height
        XCTAssertTrue(height > 300)
        let kept = DiagramLayout.clamp(CGPoint(x: note.x, y: note.y), for: note)
        XCTAssertTrue(kept.y - height / 2 >= 0)
        XCTAssertEqual(kept.x, 1950)
        let corner = DiagramLayout.clamp(CGPoint(x: 99_999, y: 99_999), for: DiagramNode(label: "Box", x: 0, y: 0))
        XCTAssertTrue(corner.x + 98 <= DiagramLayout.canvas.width && corner.y + 31 <= DiagramLayout.canvas.height)
        // Agents can't put boxes there either.
        var ws = Workspace()
        _ = try AgentTools.run("create_project", ["name": "P"], in: &ws)
        _ = try AgentTools.run("add_boxes", ["project": "P", "boxes": [["label": note.label, "kind": "note", "x": 1950, "y": 150]]], in: &ws)
        let placed = ws.diagrams[0].nodes[0]
        XCTAssertTrue(DiagramLayout.rect(of: placed).minY >= 0)
    }

    func testMapNotesGrowAndFitTheScreen() {
        let short = DiagramNode(label: "Ask Riya", x: 300, y: 300, kind: .note)
        let long = DiagramNode(label: String(repeating: "A long note about the CDN contract. ", count: 8), x: 600, y: 300, kind: .note)
        XCTAssertEqual(DiagramLayout.size(of: short).height, 110)
        XCTAssertTrue(DiagramLayout.size(of: long).height > 200)
        var map = Diagram(projectID: UUID())
        XCTAssertNil(DiagramLayout.contentBounds(map))
        map.nodes = [short, long]
        map.groups = [DiagramGroup(title: "Backend", x: 1000, y: 900, width: 400, height: 260)]
        let bounds = DiagramLayout.contentBounds(map)!
        XCTAssertEqual(bounds.minX, DiagramLayout.rect(of: short).minX)
        XCTAssertEqual(bounds.maxY, 1160)
    }

    func testMCPRequestsParseAndAreGuarded() throws {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let raw = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47321\r\nAuthorization: Bearer secret\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .complete(let request) = HTTPRequest.parse(Data(raw.utf8)) else { fatalError("Request should parse") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), body)
        XCTAssertEqual(HTTPRequest.parse(Data(raw.utf8).dropLast(5)), .incomplete)
        guard case .complete(let chunked) = HTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)) else {
            fatalError("Chunked request should parse")
        }
        XCTAssertEqual(String(decoding: chunked.body, as: UTF8.self), "hello world")
        // Only requests for /mcp, addressed to this Mac, with the key, and not from a web page.
        XCTAssertNil(refuse(request, port: 47321, token: "secret"))
        XCTAssertEqual(refuse(request, port: 47321, token: "other")?.status, 401)
        var fromPage = request; fromPage.headers["origin"] = "https://evil.example"
        XCTAssertEqual(refuse(fromPage, port: 47321, token: "secret")?.status, 403)
        var rebound = request; rebound.headers["host"] = "evil.example:47321"
        XCTAssertEqual(refuse(rebound, port: 47321, token: "secret")?.status, 403)
        var elsewhere = request; elsewhere.path = "/admin"
        XCTAssertEqual(refuse(elsewhere, port: 47321, token: "secret")?.status, 404)
        XCTAssertTrue(constantTimeEqual("abc", "abc"))
        XCTAssertFalse(constantTimeEqual("abc", "abd"))
        XCTAssertFalse(constantTimeEqual("abc", "abcd"))
    }

    func testMCPDispatcherSpeaksTheProtocol() throws {
        let dispatcher = MCPDispatcher(serverName: "context", serverVersion: "test", instructions: "Hi", tools: AgentTools.specs) { name, _ in
            name == "delete_map" ? .failure("Nope") : .success(["called": name])
        }
        func reply(_ json: String) -> [String: Any]? {
            dispatcher.handle(Data(json.utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        let initialize = try XCTUnwrap(reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"claude-code"}}}"#))
        let result = try XCTUnwrap(initialize["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "context")
        XCTAssertNil(reply(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        let tools = try XCTUnwrap((reply(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, AgentTools.specs.count)
        XCTAssertTrue(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
        let called = try XCTUnwrap(reply(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_projects","arguments":{}}}"#)?["result"] as? [String: Any])
        XCTAssertEqual(called["isError"] as? Bool, false)
        XCTAssertTrue(((called["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("list_projects") == true)
        let failed = try XCTUnwrap(reply(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"delete_map","arguments":{}}}"#)?["result"] as? [String: Any])
        XCTAssertEqual(failed["isError"] as? Bool, true)
        XCTAssertEqual((reply(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"format_disk"}}"#)?["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertEqual((reply(#"{"jsonrpc":"2.0","id":6,"method":"sampling/createMessage"}"#)?["error"] as? [String: Any])?["code"] as? Int, -32601)
        let batch = try XCTUnwrap(dispatcher.handle(Data(#"[{"jsonrpc":"2.0","id":7,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#.utf8)))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: batch) as? [Any])?.count, 1)
    }

    func testAgentsBuildAndEditMaps() throws {
        var ws = Workspace()
        let created = try XCTUnwrap(try AgentTools.run("create_project", ["name": "Innerline", "color": "green"], in: &ws).value as? [String: Any])
        let mapID = try XCTUnwrap(created["map_id"] as? String)
        XCTAssertEqual(ws.projects.first?.color, "sage")
        // A whole diagram in one call: boxes (one from a pasted address), connections by ref or label, and automatic layout.
        let added = try AgentTools.run("add_boxes", ["project": "innerline", "arrange": true, "boxes": [
            ["label": "Users", "kind": "person", "ref": "u"],
            ["label": "Web app", "kind": "frontend", "ref": "web"],
            ["url": "https://vercel.com/dashboard", "ref": "host"],
            ["label": "Database", "kind": "db", "notes": "Neon Postgres"],
        ], "connections": [["from": "u", "to": "web", "label": "use"], ["from": "web", "to": "Database"], ["from": "host", "to": "web", "label": "serves"]]], in: &ws)
        XCTAssertTrue(added.summary.contains("4 boxes"))
        let map = ws.diagrams[0]
        XCTAssertEqual(map.nodes.count, 4)
        XCTAssertEqual(map.edges.count, 3)
        XCTAssertEqual(ws.entries.count, 1)
        XCTAssertEqual(ws.entries[0].kind, .service)
        XCTAssertEqual(map.nodes.first { $0.label == "Database" }?.kind, .database)
        func node(_ label: String) -> DiagramNode { ws.diagrams[0].nodes.first { $0.label == label }! }
        XCTAssertTrue(node("Users").x < node("Web app").x)   // arranged left to right along the arrows
        let described = try XCTUnwrap(try AgentTools.run("get_map", ["map_id": mapID], in: &ws).value as? [String: Any])
        XCTAssertEqual((described["connections"] as? [[String: Any]])?.contains { $0["from_label"] as? String == "Users" && $0["label"] as? String == "use" }, true)
        // Connecting an already-connected pair updates that line instead of adding another.
        _ = try AgentTools.run("connect", ["map_id": mapID, "connections": [["from": "Database", "to": "Web app", "label": "answers", "dashed": true]]], in: &ws)
        XCTAssertEqual(ws.diagrams[0].edges.count, 3)
        XCTAssertTrue(ws.diagrams[0].edges.contains { $0.from == node("Database").id && $0.label == "answers" && $0.dashed })
        // A box showing a link renames the link itself.
        _ = try AgentTools.run("update_boxes", ["map_id": mapID, "boxes": [["box": "Vercel", "label": "Vercel (prod)", "notes": "Team plan", "color": "blue"]]], in: &ws)
        XCTAssertEqual(ws.entries[0].title, "Vercel (prod)")
        XCTAssertEqual(ws.entries[0].body, "Team plan")
        let grouped = try XCTUnwrap(try AgentTools.run("add_group", ["map_id": mapID, "title": "Backend", "boxes": ["Database", "Vercel (prod)"]], in: &ws).value as? [String: Any])
        let inside = try XCTUnwrap(grouped["boxes_inside"] as? [String])
        XCTAssertTrue(inside.contains("Database") && inside.contains("Vercel (prod)"))
        XCTAssertEqual(Set(DiagramLayout.members(of: ws.diagrams[0].groups[0], in: ws.diagrams[0]).map { node in
            ws.diagrams[0].nodes.first { $0.id == node }.map { $0.entryID.flatMap { id in ws.entries.first { $0.id == id }?.title } ?? $0.label } ?? ""
        }), Set(inside))
        // Removing a box removes its lines; the link stays saved.
        _ = try AgentTools.run("delete_boxes", ["map_id": mapID, "boxes": ["Vercel (prod)"]], in: &ws)
        XCTAssertEqual(ws.diagrams[0].nodes.count, 3)
        XCTAssertFalse(ws.diagrams[0].edges.contains { edge in !ws.diagrams[0].nodes.contains { $0.id == edge.from } })
        XCTAssertEqual(ws.entries.count, 1)
        // Links: kind guessed from the address, placed on the map, and passwords never listed.
        let link = try XCTUnwrap(try AgentTools.run("add_link", ["project": "Innerline", "url": "github.com/acme/innerline", "map_id": mapID,
                                                                  "account": "dev@example.com"], in: &ws).value as? [String: Any])
        XCTAssertEqual(link["kind"] as? String, "repository")
        XCTAssertNotNil(link["box_id"])
        ws.entries[0].credentials = [CredentialRef(label: "API key")]
        let listed = String(describing: try AgentTools.run("list_links", ["project": "Innerline"], in: &ws).value)
        XCTAssertTrue(listed.contains("saved_passwords"))
        XCTAssertFalse(listed.contains("API key"))
        // Mistakes come back as messages the agent can act on, and the result always saves cleanly.
        XCTAssertThrowsError(try AgentTools.run("add_boxes", ["map_id": mapID, "boxes": [["label": "X", "kind": "spaceship"]]], in: &ws))
        XCTAssertThrowsError(try AgentTools.run("get_map", ["project": "Nope"], in: &ws))
        XCTAssertThrowsError(try AgentTools.run("connect", ["map_id": mapID, "connections": [["from": "Users", "to": "Ghost"]]], in: &ws))
        let disk = WorkspaceDisk(directory: try temporaryDirectory())
        try disk.save(ws)
        XCTAssertEqual(try disk.load(), ws)
    }

    func testAgentsConnectOverHTTP() throws {
        let project = Project(name: "Demo")
        var workspace = Workspace()
        workspace.projects = [project]
        workspace.diagrams = [Diagram(projectID: project.id, title: "Overview")]
        let lock = NSLock()
        let token = AgentSettings.newToken()
        let port = UInt16.random(in: 49_200...49_900)
        let dispatcher = MCPDispatcher(serverName: "context", serverVersion: "test", instructions: "", tools: AgentTools.specs) { name, arguments in
            lock.lock(); defer { lock.unlock() }
            do { return .success(try AgentTools.run(name, arguments, in: &workspace).value) }
            catch let failure as AgentTools.Failure { return .failure(failure.message) }
            catch { return .failure("\(error)") }
        }
        let server = AgentHTTPServer { request in
            if let refusal = refuse(request, port: port, token: token) { return refusal }
            guard let reply = dispatcher.handle(request.body) else { return HTTPResponse(status: 202) }
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: reply)
        }
        let ready = DispatchSemaphore(value: 0)
        var failure: String?
        server.start(port: port) { failure = $0; ready.signal() }
        ready.wait()
        defer { server.stop() }
        XCTAssertNil(failure)
        // The bridge agents launch talks to the app exactly like this.
        let settings = AgentSettings(enabled: true, port: port, token: token)
        guard case .reply(let hello, _) = AgentBridge.post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test"}}}"#,
                                                           settings: settings, session: nil) else { fatalError("initialize should succeed") }
        XCTAssertTrue(hello.contains(#""name":"context""#))
        let call = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add_boxes","arguments":{"project":"Demo","boxes":[{"label":"API"},{"label":"DB","kind":"database"}],"connections":[{"from":"API","to":"DB"}]}}}"#
        guard case .reply(let added, _) = AgentBridge.post(call, settings: settings, session: nil) else { fatalError("tools/call should succeed") }
        XCTAssertTrue(added.contains(#""isError":false"#))
        lock.lock()
        XCTAssertEqual(workspace.diagrams[0].nodes.count, 2)
        XCTAssertEqual(workspace.diagrams[0].edges.count, 1)
        lock.unlock()
        guard case .accepted = AgentBridge.post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, settings: settings, session: nil) else {
            fatalError("A notification gets 202 Accepted")
        }
        var wrongKey = settings
        wrongKey.token = "guess"
        guard case .refused(let reason) = AgentBridge.post(call, settings: wrongKey, session: nil) else { fatalError("A wrong key is refused") }
        XCTAssertTrue(reason.contains("access key"))
        // With access off, the bridge answers each request with an error the agent shows, and stays quiet for notifications.
        XCTAssertTrue(AgentBridge.errorReply(for: call, "Off")?.contains(#""id":2"#) == true)
        XCTAssertNil(AgentBridge.errorReply(for: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, "Off"))
    }

    func testCopiedPromptsTellAgentsHowToReachContext() {
        let project = Project(name: "Innerline ticket")
        var ws = Workspace()
        ws.projects = [project]
        let map = Diagram(projectID: project.id, title: "Overview")
        ws.diagrams = [map]
        ws.entries = [Entry(projectID: project.id, kind: .service, title: "Neon", url: "https://console.neon.tech")]
        let exe = "/Applications/Context.app/Contents/MacOS/Context"
        let prompt = AgentPrompt.make(.mapCode, project: project, in: ws, executable: exe)
        XCTAssertTrue(prompt.contains(AgentPrompt.Task.mapCode.instruction))
        XCTAssertTrue(prompt.contains("\"\(exe)\" --call get_map '{\"project\": \"\(project.id.uuidString)\"}'"))
        XCTAssertTrue(prompt.contains("map_id \(map.id.uuidString)"))
        XCTAssertTrue(prompt.contains("Saved links: 1"))
        XCTAssertTrue(prompt.contains("MCP server"))
        let custom = AgentPrompt.make(.custom, custom: "  Add Stripe and connect it to the API.  ", project: project, in: ws, executable: exe)
        XCTAssertTrue(custom.contains("Task: Add Stripe and connect it to the API.\n"))
        XCTAssertTrue(AgentPrompt.Task.allCases.filter { $0 != .custom }.allSatisfy { !$0.instruction.isEmpty && !$0.detail.isEmpty })
    }

    func testBrandMatching() {
        func id(_ url: String, _ texts: [String] = []) -> String? { BrandCatalog.match(url: url, texts: texts)?.id }
        XCTAssertEqual(id("https://console.neon.tech/app/projects"), "neon")
        XCTAssertEqual(id("https://mailadmin.zoho.in"), "zoho")
        XCTAssertEqual(id("https://vendors.paddle.com/"), "paddle")
        XCTAssertEqual(id("https://console.cloud.google.com/"), "googlecloud")
        XCTAssertEqual(id("https://www.google.com/"), "google")
        XCTAssertEqual(id("https://business.facebook.com/latest"), "meta")
        XCTAssertEqual(id("https://www.facebook.com/ayuvam"), "facebook")
        XCTAssertEqual(id("https://www.linkedin.com/company/x"), "linkedin")
        XCTAssertEqual(id("https://evil-github.com.example.net"), nil)
        XCTAssertEqual(id("", ["", "Ayuvam Instagram"]), "instagram")
        XCTAssertEqual(id("", ["Twitter"]), "x")
        XCTAssertEqual(id("", ["Newsletter"]), nil)
        XCTAssertEqual(id("", ["Google Cloud"]), "googlecloud")
    }

    func testEveryBrandIconParses() {
        for brand in BrandCatalog.all {
            guard let data = brand.path else { continue }
            let box = SVGPath.parse(data).boundingBoxOfPath
            guard !box.isEmpty, box.minX > -1, box.minY > -1, box.maxX < 25, box.maxY < 25, box.width > 8 || box.height > 8 else {
                fatalError("Icon \(brand.id) parsed to \(box)")
            }
        }
        XCTAssertTrue(BrandCatalog.all.count > 100)
        XCTAssertEqual(Set(BrandCatalog.all.map(\.id)).count, BrandCatalog.all.count)
    }

    func testMarkdownTablesAndBlocks() {
        let text = """
        # Plan
        Intro line
        second line
        | Item | Cost | Note |
        |:--- | ---: | :---: |
        | Hosting | $20 | `a|b` |
        | Domain \\| DNS | $12 |
        - [ ] write copy
        - [x] ship
        1. first
        > quoted
        > more
        ```swift
        let a = 1
        ```
        ---
        """
        let blocks = Markdown.parse(text)
        XCTAssertEqual(blocks[0], .heading(level: 1, text: "Plan"))
        XCTAssertEqual(blocks[1], .paragraph("Intro line\nsecond line"))
        guard case .table(let header, let alignments, let rows) = blocks[2] else { fatalError("expected a table, got \(blocks[2])") }
        XCTAssertEqual(header, ["Item", "Cost", "Note"])
        XCTAssertEqual(alignments, [.leading, .trailing, .center])
        XCTAssertEqual(rows[0], ["Hosting", "$20", "`a|b`"])
        XCTAssertEqual(rows[1], ["Domain | DNS", "$12", ""])
        XCTAssertEqual(blocks[3], .check(done: false, text: "write copy", line: 7, indent: 0))
        XCTAssertEqual(blocks[4], .check(done: true, text: "ship", line: 8, indent: 0))
        XCTAssertEqual(blocks[5], .numbered(number: "1", text: "first", indent: 0))
        XCTAssertEqual(blocks[6], .quote("quoted\nmore"))
        XCTAssertEqual(blocks[7], .code(language: "swift", text: "let a = 1"))
        XCTAssertEqual(blocks[8], .rule)
        XCTAssertEqual(blocks.count, 9)
        // A plain rule under text is not a table separator.
        XCTAssertEqual(Markdown.parse("a | b\n---"), [.paragraph("a | b"), .rule])
        let toggled = Markdown.toggleCheck(in: text, line: 7)
        XCTAssertTrue(Markdown.lines(toggled)[7].hasPrefix("- [x]"))
        XCTAssertEqual(Markdown.outline(blocks).map(\.title), ["Plan"])
        XCTAssertEqual(Markdown.plain("## **Bold** [link](https://x.com)\nbody"), "Bold link · body")
        XCTAssertEqual(Markdown.wordCount("Hello, world — `x` 12"), 4)
    }

    func testMarkdownEditingHelpers() {
        XCTAssertEqual(Markdown.listContinuation(for: "- item")?.prefix, "- ")
        XCTAssertEqual(Markdown.listContinuation(for: "  * item")?.prefix, "  * ")
        XCTAssertEqual(Markdown.listContinuation(for: "9. item")?.prefix, "10. ")
        XCTAssertEqual(Markdown.listContinuation(for: "- [x] done")?.prefix, "- [ ] ")
        XCTAssertTrue(Markdown.listContinuation(for: "- ")?.isEmptyItem == true)
        XCTAssertNil(Markdown.listContinuation(for: "plain text"))
        XCTAssertEqual(Markdown.togglePrefix("# ", in: "Title"), "# Title")
        XCTAssertEqual(Markdown.togglePrefix("# ", in: "# Title"), "Title")
        XCTAssertEqual(Markdown.togglePrefix("## ", in: "# Title"), "## Title")
        XCTAssertEqual(Markdown.togglePrefix("- ", in: "a\nb"), "- a\n- b")
        XCTAssertEqual(Markdown.togglePrefix("1. ", in: "- a"), "1. a")
    }

    func testMapNodesDecodeWithoutNewFields() throws {
        let json = #"{"id":"\#(UUID())","label":"API","x":10,"y":20}"#
        let node = try JSONDecoder().decode(DiagramNode.self, from: Data(json.utf8))
        XCTAssertEqual(node.kind, .step)
        XCTAssertEqual(node.color, "")
        let edge = try JSONDecoder().decode(DiagramEdge.self, from: Data(#"{"id":"\#(UUID())","from":"\#(UUID())","to":"\#(UUID())"}"#.utf8))
        XCTAssertFalse(edge.dashed)
        XCTAssertEqual(node.notes, "")
        // Maps saved before groups existed still load.
        let map = try JSONDecoder().decode(Diagram.self, from: Data(#"{"id":"\#(UUID())","projectID":"\#(UUID())","title":"Old","nodes":[],"edges":[],"updatedAt":0}"#.utf8))
        XCTAssertEqual(map.title, "Old")
        XCTAssertTrue(map.groups.isEmpty)
        XCTAssertEqual(map.lineStyle, .elbow)
        var curved = map
        curved.lineStyle = .curved
        XCTAssertEqual(try JSONDecoder().decode(Diagram.self, from: try JSONEncoder().encode(curved)).lineStyle, .curved)
    }

    func testMapConnectionsUseFacingSidesAndSpreadOut() {
        // Side by side joins left-to-right; stacked joins top-to-bottom.
        let left = CGRect(x: 0, y: 0, width: 100, height: 50), right = CGRect(x: 300, y: 0, width: 100, height: 50)
        let across = DiagramLayout.sides(from: left, to: right)
        XCTAssertEqual(across.0, .right)
        XCTAssertEqual(across.1, .left)
        let below = CGRect(x: 0, y: 200, width: 100, height: 50)
        let down = DiagramLayout.sides(from: left, to: below)
        XCTAssertEqual(down.0, .bottom)
        XCTAssertEqual(down.1, .top)

        let elbow = DiagramLayout.route(from: left, .right, to: right, .left, style: .elbow)
        XCTAssertEqual(elbow.start, CGPoint(x: 100, y: 25))
        XCTAssertEqual(elbow.end, CGPoint(x: 300, y: 25))
        XCTAssertEqual(elbow.arrow, CGVector(dx: 1, dy: 0))
        XCTAssertEqual(DiagramLayout.route(from: left, .right, to: right, .left, style: .straight).points.count, 2)
        XCTAssertEqual(DiagramLayout.route(from: left, .right, to: right, .left, style: .curved).points.count, 4)
        // An elbow between offset boxes turns at right angles, and its label sits halfway along.
        let lower = CGRect(x: 300, y: 100, width: 100, height: 50)
        let bent = DiagramLayout.route(from: left, .right, to: lower, .left, style: .elbow)
        XCTAssertEqual(bent.points.count, 4)
        XCTAssertTrue(zip(bent.points, bent.points.dropFirst()).allSatisfy { $0.x == $1.x || $0.y == $1.y })
        XCTAssertEqual(bent.labelPoint, CGPoint(x: 200, y: 75))

        // Two lines leaving the same side are spread apart, the upper one for the upper box, so they don't cross.
        let a = DiagramNode(label: "A", x: 0, y: 0), b = DiagramNode(label: "B", x: 0, y: 0), c = DiagramNode(label: "C", x: 0, y: 0)
        var map = Diagram(projectID: UUID())
        map.nodes = [a, b, c]
        let toB = DiagramEdge(from: a.id, to: b.id), toC = DiagramEdge(from: a.id, to: c.id)
        map.edges = [toC, toB]
        let rects = [a.id: CGRect(x: 0, y: 0, width: 200, height: 60),
                     b.id: CGRect(x: 400, y: -20, width: 200, height: 60), c.id: CGRect(x: 400, y: 30, width: 200, height: 60)]
        let routes = DiagramLayout.routes(for: map, rects: rects)
        let upper = try! XCTUnwrap(routes[toB.id]), lowerRoute = try! XCTUnwrap(routes[toC.id])
        XCTAssertEqual(upper.startSide, .right)
        XCTAssertEqual(lowerRoute.startSide, .right)
        XCTAssertTrue(upper.start.y < lowerRoute.start.y)
        XCTAssertEqual(upper.start.x, 200)

        // A line that would run under another box goes around it instead.
        let source = CGRect(x: 0, y: 0, width: 200, height: 60), blocker = CGRect(x: 300, y: 0, width: 200, height: 60)
        let target = CGRect(x: 300, y: 200, width: 200, height: 60)
        let open = DiagramLayout.sides(from: source, to: target, style: .elbow, avoiding: [])
        XCTAssertEqual(open.0, .right)
        XCTAssertEqual(open.1, .top)
        let around = DiagramLayout.sides(from: source, to: target, style: .elbow, avoiding: [blocker])
        XCTAssertEqual(around.0, .bottom)
        XCTAssertEqual(around.1, .left)
        XCTAssertTrue(DiagramLayout.segment(CGPoint(x: 200, y: 30), CGPoint(x: 400, y: 30), crosses: blocker))
        XCTAssertFalse(DiagramLayout.segment(CGPoint(x: 100, y: 60), CGPoint(x: 100, y: 230), crosses: blocker))
        XCTAssertTrue(DiagramLayout.segment(CGPoint(x: 250, y: -50), CGPoint(x: 550, y: 110), crosses: blocker))
    }

    func testDraggedBoxesLineUpWithOthers() {
        let other = DiagramNode(label: "API", x: 200, y: 500)
        let near = DiagramLayout.snap(CGPoint(x: 204, y: 333), for: UUID(), among: [other])
        XCTAssertEqual(near.point, CGPoint(x: 200, y: 330))
        XCTAssertEqual(near.guideX, 200)
        XCTAssertNil(near.guideY)
        let far = DiagramLayout.snap(CGPoint(x: 264, y: 333), for: UUID(), among: [other])
        XCTAssertEqual(far.point, CGPoint(x: 260, y: 330))
        XCTAssertNil(far.guideX)
        // A box never lines up with itself.
        XCTAssertNil(DiagramLayout.snap(CGPoint(x: 204, y: 333), for: other.id, among: [other]).guideX)
    }

    func testBackAndForwardLikeABrowser() {
        var history = NavigationHistory<String>()
        XCTAssertNil(history.goBack(from: "home"))
        history.leave("home")             // home → a
        history.leave("a")                // a → b
        XCTAssertEqual(history.goBack(from: "b"), "a")
        XCTAssertEqual(history.goBack(from: "a"), "home")
        XCTAssertNil(history.goBack(from: "home"))
        XCTAssertEqual(history.goForward(from: "home"), "a")
        XCTAssertEqual(history.goForward(from: "a"), "b")
        XCTAssertNil(history.goForward(from: "b"))
        // Going somewhere new clears the way forward.
        _ = history.goBack(from: "b")
        history.leave("a")                // a → c
        XCTAssertNil(history.goForward(from: "c"))
        XCTAssertEqual(history.goBack(from: "c"), "a")
        // Pages that no longer exist (a deleted project) are skipped.
        var skipping = NavigationHistory<String>()
        skipping.leave("home"); skipping.leave("deleted"); skipping.leave("a")
        XCTAssertEqual(skipping.goBack(from: "b", exists: { $0 != "deleted" }), "a")
        XCTAssertEqual(skipping.goBack(from: "a", exists: { $0 != "deleted" }), "home")
        // Visiting the same page twice in a row is one step, and history stays bounded.
        var repeats = NavigationHistory<Int>()
        repeats.limit = 3
        repeats.leave(1); repeats.leave(1)
        XCTAssertEqual(repeats.back, [1])
        for page in 2...9 { repeats.leave(page) }
        XCTAssertEqual(repeats.back, [7, 8, 9])
    }

    func testRemindersPointBackToTheirBox() {
        let box = UUID()
        let url = ReminderItem.boxURL(box)
        XCTAssertEqual(url.absoluteString, "context://box/\(box.uuidString)")
        XCTAssertEqual(ReminderItem.boxID(from: url), box)
        XCTAssertEqual(ReminderItem.boxID(from: URL(string: "CONTEXT://Box/\(box.uuidString.lowercased())")), box)
        // Links that aren't Context box links (or aren't there at all) belong to no box.
        XCTAssertNil(ReminderItem.boxID(from: nil))
        XCTAssertNil(ReminderItem.boxID(from: URL(string: "https://example.com/box/\(box.uuidString)")))
        XCTAssertNil(ReminderItem.boxID(from: URL(string: "context://project/\(box.uuidString)")))
        XCTAssertNil(ReminderItem.boxID(from: URL(string: "context://box/not-a-box")))
    }

    func testPastedLinksGuessTheirKindAndName() {
        let project = UUID()
        let repo = try! XCTUnwrap(Entry.quick(url: "github.com/acme/web", projectID: project))
        XCTAssertEqual(repo.kind, .repository)
        XCTAssertEqual(repo.title, "web")
        XCTAssertEqual(repo.url, "https://github.com/acme/web")
        XCTAssertEqual(repo.projectID, project)
        let neon = try! XCTUnwrap(Entry.quick(url: "  https://console.neon.tech/app  ", projectID: project))
        XCTAssertEqual(neon.kind, .service)
        XCTAssertEqual(neon.title, "Neon")
        XCTAssertEqual(Entry.quick(url: "https://www.instagram.com/ayuvam", projectID: project)?.kind, .social)
        XCTAssertEqual(Entry.quick(url: "https://claude.ai/chat/123", projectID: project)?.kind, .conversation)
        XCTAssertEqual(Entry.quick(url: "https://docs.google.com/document/d/1", projectID: project)?.kind, .document)
        let plain = try! XCTUnwrap(Entry.quick(url: "https://www.example.org/page", projectID: project))
        XCTAssertEqual(plain.kind, .link)
        XCTAssertEqual(plain.title, "example.org")
        // Anything that isn't clearly a web address is a box name, not a link.
        XCTAssertNil(Entry.quick(url: "", projectID: project))
        XCTAssertNil(Entry.quick(url: "Orders database", projectID: project))
        XCTAssertNil(Entry.quick(url: "backend", projectID: project))
        XCTAssertNil(Entry.quick(url: "javascript:alert(1)", projectID: project))
        XCTAssertNil(Entry.quick(url: "file:///etc/passwd", projectID: project))
    }

    func testMapGroups() throws {
        var map = Diagram(projectID: UUID())
        let api = DiagramNode(label: "API", x: 400, y: 300), db = DiagramNode(label: "DB", x: 400, y: 420), site = DiagramNode(label: "Site", x: 1200, y: 300)
        map.nodes = [api, db, site]
        // A group fitted around two boxes contains exactly those boxes, with room for its name tag above them.
        let group = DiagramLayout.group(around: [api, db], or: .zero, title: "Backend")
        XCTAssertEqual(Set(DiagramLayout.members(of: group, in: map)), [api.id, db.id])
        XCTAssertTrue(group.y + DiagramLayout.groupHeader <= DiagramLayout.rect(of: api).minY)
        XCTAssertEqual(group.title, "Backend")
        // Groups never shrink below a usable size or leave the canvas.
        let tiny = DiagramLayout.clamp(DiagramGroup(x: -500, y: 99_999, width: 5, height: 5))
        XCTAssertTrue(tiny.width >= DiagramLayout.minimumGroupSize.width)
        XCTAssertTrue(tiny.x >= 0)
        XCTAssertTrue(tiny.y + tiny.height <= DiagramLayout.canvas.height)
        // Groups and box notes survive a save and reload.
        var notedMap = map
        notedMap.nodes[0].notes = "Owned by Riya"
        notedMap.groups = [group]
        let decoded = try JSONDecoder().decode(Diagram.self, from: try JSONEncoder().encode(notedMap))
        XCTAssertEqual(decoded.groups, [group])
        XCTAssertEqual(decoded.nodes[0].notes, "Owned by Riya")
    }

    func testMapTidyAndBuildFromLinks() {
        let project = Project(name: "Ayuvam")
        var map = Diagram(projectID: project.id)
        let a = DiagramNode(label: "Site", x: 900, y: 900), b = DiagramNode(label: "API", x: 10, y: 10), c = DiagramNode(label: "DB", x: 500, y: 40)
        let loose = DiagramNode(label: "Idea", x: 0, y: 0)
        map.nodes = [c, loose, a, b]
        map.edges = [DiagramEdge(from: a.id, to: b.id), DiagramEdge(from: b.id, to: c.id), DiagramEdge(from: c.id, to: a.id)] // includes a cycle
        let tidy = DiagramLayout.tidy(map)
        func node(_ id: UUID) -> DiagramNode { tidy.nodes.first { $0.id == id }! }
        XCTAssertTrue(node(a.id).x < node(b.id).x || node(b.id).x < node(c.id).x)
        XCTAssertTrue(node(loose.id).y > max(node(a.id).y, node(b.id).y, node(c.id).y))
        XCTAssertEqual(Set(tidy.nodes.map { "\($0.x),\($0.y)" }).count, 4)

        let entries = [Entry(projectID: project.id, kind: .service, title: "Vercel"), Entry(projectID: project.id, kind: .service, title: "Neon"),
                       Entry(projectID: project.id, kind: .social, title: "Instagram"), Entry(projectID: UUID(), kind: .service, title: "Other project")]
        let built = DiagramLayout.fromLinks(project: project, entries: entries)
        XCTAssertEqual(built.nodes.count, 1 + 2 + 3)       // hub, two groups, three links
        XCTAssertEqual(built.edges.count, 2 + 3)
        XCTAssertEqual(built.nodes.filter { $0.entryID != nil }.count, 3)
        let hub = built.nodes[0]
        XCTAssertTrue(built.nodes.dropFirst().allSatisfy { $0.x > hub.x })
        let spot = DiagramLayout.freeSpot(near: CGPoint(x: tidy.nodes[0].x, y: tidy.nodes[0].y), in: tidy)
        XCTAssertFalse(tidy.nodes.contains { abs($0.x - spot.x) < 150 && abs($0.y - spot.y) < 60 })
    }

    func testLauncherRanking() {
        let project = Project(name: "Presently")
        var w = Workspace()
        w.projects = [project]
        var neon = Entry(projectID: project.id, kind: .service, title: "Neon Database", url: "https://console.neon.tech/app")
        neon.openCount = 3
        let vercel = Entry(projectID: project.id, kind: .service, title: "Vercel", url: "https://vercel.com/x")
        let note = Entry(projectID: project.id, kind: .note, title: "Deploy steps", body: "Remember to run the neon migration first")
        let gcloud = Entry(projectID: project.id, kind: .service, title: "Google Cloud console", url: "https://console.cloud.google.com")
        w.entries = [vercel, note, neon, gcloud]
        XCTAssertEqual(LauncherSearch.results(for: "neon", in: w).first?.target, .entry(neon.id))
        XCTAssertTrue(LauncherSearch.results(for: "neon", in: w).contains { $0.target == .entry(note.id) })
        XCTAssertEqual(LauncherSearch.results(for: "vrcl", in: w).first?.target, .entry(vercel.id))
        XCTAssertEqual(LauncherSearch.results(for: "gc", in: w).first?.target, .entry(gcloud.id))
        XCTAssertEqual(LauncherSearch.results(for: "pres", in: w).first?.target, .project(project.id))
        XCTAssertTrue(LauncherSearch.results(for: "backup", in: w).contains { $0.target == .action(.backupNow) })
        XCTAssertTrue(LauncherSearch.results(for: "zzzz qqq", in: w).isEmpty)
        let empty = LauncherSearch.results(for: "", in: w)
        XCTAssertEqual(empty.first?.target, .entry(neon.id)) // most used link first
    }

    func testBackupWriterKeepsOneFilePerDayAndPrunes() throws {
        let folder = try temporaryDirectory()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 9))!
        let first = try BackupWriter.write(Data("one".utf8), into: folder, date: day, keep: 3, calendar: calendar)
        XCTAssertEqual(first.lastPathComponent, "Context-2026-10-03.json")
        try BackupWriter.write(Data("two".utf8), into: folder, date: day.addingTimeInterval(3600), keep: 3, calendar: calendar)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "two")
        for offset in 1...4 { try BackupWriter.write(Data("\(offset)".utf8), into: folder, date: calendar.date(byAdding: .day, value: offset, to: day)!, keep: 3, calendar: calendar) }
        let files = BackupWriter.list(in: folder)
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files.map { $0.url.lastPathComponent }, ["Context-2026-10-07.json", "Context-2026-10-06.json", "Context-2026-10-05.json"])
    }

    func testCloudFolderDetection() throws {
        let home = try temporaryDirectory()
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent("Library/CloudStorage/GoogleDrive-me@example.com/My Drive"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Library/CloudStorage/OneDrive-Personal"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"), withIntermediateDirectories: true)
        let found = CloudFolders.detect(home: home)
        XCTAssertEqual(found.map(\.name), ["Google Drive (me@example.com)", "OneDrive · Personal", "iCloud Drive"])
        XCTAssertEqual(found[0].url.lastPathComponent, "My Drive")
        XCTAssertEqual(CloudFolders.name(for: found[0].url.path), "Google Drive")
    }

    func testDuplicateIdentifiersRejected() {
        let project = Project(name: "Test")
        var workspace = Workspace()
        workspace.projects = [project, project]
        XCTAssertThrowsError(try workspace.validated())
    }

    func testRecurringTaskRequiresDueDate() {
        let project = Project(name: "Test")
        var workspace = Workspace()
        workspace.projects = [project]
        workspace.tasks = [WorkTask(projectID: project.id, repeatRule: RepeatRule(kind: .daily))]
        XCTAssertThrowsError(try workspace.validated())
    }

    func testDiagramEdgesMustReferenceNodes() {
        let project = Project(name: "Test")
        var workspace = Workspace()
        workspace.projects = [project]
        let node = DiagramNode(label: "API", x: 0, y: 0)
        workspace.diagrams = [Diagram(projectID: project.id, nodes: [node], edges: [DiagramEdge(from: node.id, to: UUID())])]
        XCTAssertThrowsError(try workspace.validated())
    }

    func testOneOffCompletionPreservesHistory() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var task = WorkTask(projectID: UUID(), title: "Post image")
        task.complete(at: now)
        XCTAssertEqual(task.completedAt, now)
        XCTAssertEqual(task.completionHistory, [now])
        task.reopen()
        XCTAssertFalse(task.isComplete)
    }

    func utc() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testRecurringCompletionAdvancesPastMissedDates() {
        let calendar = utc()
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 10))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 11))!
        var task = WorkTask(projectID: UUID(), due: start, repeatRule: RepeatRule(kind: .everyNDays, interval: 3))
        task.complete(at: now, calendar: calendar)
        XCTAssertFalse(task.isComplete)
        XCTAssertEqual(task.due, calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 10)))
        XCTAssertEqual(task.completionHistory.count, 1)
    }

    func testDailyRecurrencePreservesWallClockAcrossDaylightSaving() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let due = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 9))!
        var task = WorkTask(projectID: UUID(), due: due, repeatRule: RepeatRule(kind: .daily))
        task.complete(at: due, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: task.due!), 9)
        XCTAssertEqual(calendar.component(.day, from: task.due!), 8)
        XCTAssertEqual(task.due!.timeIntervalSince(due), 23 * 3600)
    }

    func testCompletingEarlyAdvancesExactlyOneOccurrence() {
        let calendar = utc()
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        var task = WorkTask(projectID: UUID(), due: due, repeatRule: RepeatRule(kind: .weekly))
        task.complete(at: due.addingTimeInterval(-3600), calendar: calendar)
        XCTAssertEqual(task.due, calendar.date(byAdding: .day, value: 7, to: due))
    }

    func testWeeklyOnSelectedWeekdays() {
        let calendar = utc()
        // Monday 5 Oct 2026, 09:00. Repeat on Monday (2) and Thursday (5).
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))!
        let rule = RepeatRule(kind: .weekly, weekdays: [2, 5])
        let upcoming = rule.upcoming(from: monday, limit: 4, calendar: calendar).map { calendar.component(.day, from: $0) }
        XCTAssertEqual(upcoming, [5, 8, 12, 15])
        let fortnightly = RepeatRule(kind: .weekly, interval: 2, weekdays: [2])
        XCTAssertEqual(fortnightly.occurrence(after: monday, anchor: monday, calendar: calendar), calendar.date(byAdding: .day, value: 14, to: monday))
    }

    func testMultipleTimesPerDay() {
        let calendar = utc()
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))!
        var task = WorkTask(projectID: UUID(), due: morning, repeatRule: RepeatRule(kind: .daily, extraTimes: [13 * 60, 18 * 60 + 30]))
        task.complete(at: morning, calendar: calendar)
        XCTAssertEqual(task.due, calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 13)))
        // Missing the afternoon and evening slots collapses into the next future slot.
        task.complete(at: calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 20))!, calendar: calendar)
        XCTAssertEqual(task.due, calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 9)))
    }

    func testFollowUpAfterCompletion() {
        let calendar = utc()
        let due = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 16))!
        let finished = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 11))!
        var task = WorkTask(projectID: UUID(), due: due, repeatRule: RepeatRule(kind: .afterCompletion, interval: 5))
        task.complete(at: finished, calendar: calendar)
        XCTAssertEqual(task.due, calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 16)))
    }

    func testSnoozeDoesNotChangeRecurrence() {
        let calendar = utc()
        let due = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))!
        var task = WorkTask(projectID: UUID(), due: due, repeatRule: RepeatRule(kind: .daily), reminderLead: 15)
        XCTAssertEqual(task.reminderDate, due.addingTimeInterval(-900))
        let later = due.addingTimeInterval(7200)
        task.snoozedUntil = later
        XCTAssertTrue(task.isSnoozed(at: due))
        XCTAssertEqual(task.reminderDate, later)
        XCTAssertEqual(task.repeatRule, RepeatRule(kind: .daily))
        XCTAssertEqual(task.due, due)
        task.complete(at: due.addingTimeInterval(8000), calendar: calendar)
        XCTAssertNil(task.snoozedUntil)
        XCTAssertEqual(task.due, calendar.date(byAdding: .day, value: 1, to: due))
    }

    func testNotificationTimeIndependentOfDueDate() {
        let at = Date(timeIntervalSince1970: 1_900_000_000)
        let task = WorkTask(projectID: UUID(), title: "Call", notifyAt: at)
        XCTAssertNil(task.due)
        XCTAssertEqual(task.reminderDate, at)
    }

    func testPostingCompletionIsPerPlatform() {
        var item = ContentItem(projectID: UUID(), title: "Launch", targets: [PostTarget(platform: "Instagram"), PostTarget(platform: "Facebook")])
        item.targets[0].completedAt = Date()
        XCTAssertFalse(item.isComplete)
        XCTAssertEqual(item.remaining.map(\.platform), ["Facebook"])
        item.targets[1].completedAt = Date()
        XCTAssertTrue(item.isComplete)
    }

    func testCredentialsAreReferencesOnly() throws {
        let project = Project(name: "Test")
        var workspace = Workspace()
        workspace.projects = [project]
        workspace.entries = [Entry(projectID: project.id, kind: .service, title: "Hosting", credentials: [CredentialRef(label: "API key", username: "ops")])]
        let json = String(decoding: try WorkspaceDisk(directory: try temporaryDirectory()).encode(workspace), as: UTF8.self)
        XCTAssertTrue(json.contains("API key"))
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains("password"))
    }

    func testOnlyExplicitWebURLsAccepted() {
        XCTAssertNotNil(webURL("https://github.com/example/repo"))
        XCTAssertNil(webURL("javascript:alert(1)"))
        XCTAssertNil(webURL("file:///etc/passwd"))
        XCTAssertNil(webURL("https://user:password@example.com"))
        XCTAssertNil(webURL("example.com"))
    }

}

var assertionCount = 0
func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) {
    assertionCount += 1
    guard lhs == rhs else { fatalError("Expected equality at \(file):\(line): \(lhs) != \(rhs)") }
}
func XCTAssertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(value, true, file: file, line: line) }
func XCTAssertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertEqual(value, false, file: file, line: line) }
func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value == nil, file: file, line: line) }
func XCTAssertNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value != nil, file: file, line: line) }
func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    assertionCount += 1
    guard let value else { fatalError("Unexpected nil at \(file):\(line)") }
    return value
}
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    assertionCount += 1
    do { _ = try expression() } catch { return }
    fatalError("Expected an error at \(file):\(line)")
}

@main
struct TestRunner {
    static func main() throws {
        let tests = WorkspaceTests()
        defer { tests.finish() }
        let all: [(String, () throws -> Void)] = [
            ("testBoxesStayOnTheCanvas", { try tests.testBoxesStayOnTheCanvas() }),
            ("testCopiedPromptsTellAgentsHowToReachContext", { tests.testCopiedPromptsTellAgentsHowToReachContext() }),
            ("testMCPRequestsParseAndAreGuarded", { try tests.testMCPRequestsParseAndAreGuarded() }),
            ("testMCPDispatcherSpeaksTheProtocol", { try tests.testMCPDispatcherSpeaksTheProtocol() }),
            ("testAgentsBuildAndEditMaps", { try tests.testAgentsBuildAndEditMaps() }),
            ("testAgentsConnectOverHTTP", { try tests.testAgentsConnectOverHTTP() }),
            ("testWorkspaceRoundTripAndPreviousVersionBackup", { try tests.testWorkspaceRoundTripAndPreviousVersionBackup() }),
            ("testCorruptDataIsNotSilentlyReplaced", { try tests.testCorruptDataIsNotSilentlyReplaced() }),
            ("testInvalidReferencesAndVersionsRejected", { try tests.testInvalidReferencesAndVersionsRejected() }),
            ("testVersionOneDataMigrates", { try tests.testVersionOneDataMigrates() }),
            ("testProjectsKeepTheirPictureListAndOldFields", { try tests.testProjectsKeepTheirPictureListAndOldFields() }),
            ("testProjectPicturesAreSmallSquares", { try tests.testProjectPicturesAreSmallSquares() }),
            ("testQuickReminderReadsDatesFromText", { tests.testQuickReminderReadsDatesFromText() }),
            ("testRepeatOptionsMatchAppleReminders", { tests.testRepeatOptionsMatchAppleReminders() }),
            ("testRemindersSortAndCountWhatsDue", { tests.testRemindersSortAndCountWhatsDue() }),
            ("testMapNotesGrowAndFitTheScreen", { tests.testMapNotesGrowAndFitTheScreen() }),
            ("testBrandMatching", { tests.testBrandMatching() }),
            ("testEveryBrandIconParses", { tests.testEveryBrandIconParses() }),
            ("testMarkdownTablesAndBlocks", { tests.testMarkdownTablesAndBlocks() }),
            ("testMarkdownEditingHelpers", { tests.testMarkdownEditingHelpers() }),
            ("testMapNodesDecodeWithoutNewFields", { try tests.testMapNodesDecodeWithoutNewFields() }),
            ("testMapGroups", { try tests.testMapGroups() }),
            ("testMapTidyAndBuildFromLinks", { tests.testMapTidyAndBuildFromLinks() }),
            ("testMapConnectionsUseFacingSidesAndSpreadOut", { tests.testMapConnectionsUseFacingSidesAndSpreadOut() }),
            ("testDraggedBoxesLineUpWithOthers", { tests.testDraggedBoxesLineUpWithOthers() }),
            ("testPastedLinksGuessTheirKindAndName", { tests.testPastedLinksGuessTheirKindAndName() }),
            ("testBackAndForwardLikeABrowser", { tests.testBackAndForwardLikeABrowser() }),
            ("testRemindersPointBackToTheirBox", { tests.testRemindersPointBackToTheirBox() }),
            ("testLauncherRanking", { tests.testLauncherRanking() }),
            ("testBackupWriterKeepsOneFilePerDayAndPrunes", { try tests.testBackupWriterKeepsOneFilePerDayAndPrunes() }),
            ("testCloudFolderDetection", { try tests.testCloudFolderDetection() }),
            ("testDuplicateIdentifiersRejected", { tests.testDuplicateIdentifiersRejected() }),
            ("testRecurringTaskRequiresDueDate", { tests.testRecurringTaskRequiresDueDate() }),
            ("testDiagramEdgesMustReferenceNodes", { tests.testDiagramEdgesMustReferenceNodes() }),
            ("testOneOffCompletionPreservesHistory", { tests.testOneOffCompletionPreservesHistory() }),
            ("testRecurringCompletionAdvancesPastMissedDates", { tests.testRecurringCompletionAdvancesPastMissedDates() }),
            ("testDailyRecurrencePreservesWallClockAcrossDaylightSaving", { tests.testDailyRecurrencePreservesWallClockAcrossDaylightSaving() }),
            ("testCompletingEarlyAdvancesExactlyOneOccurrence", { tests.testCompletingEarlyAdvancesExactlyOneOccurrence() }),
            ("testWeeklyOnSelectedWeekdays", { tests.testWeeklyOnSelectedWeekdays() }),
            ("testMultipleTimesPerDay", { tests.testMultipleTimesPerDay() }),
            ("testFollowUpAfterCompletion", { tests.testFollowUpAfterCompletion() }),
            ("testSnoozeDoesNotChangeRecurrence", { tests.testSnoozeDoesNotChangeRecurrence() }),
            ("testNotificationTimeIndependentOfDueDate", { tests.testNotificationTimeIndependentOfDueDate() }),
            ("testPostingCompletionIsPerPlatform", { tests.testPostingCompletionIsPerPlatform() }),
            ("testCredentialsAreReferencesOnly", { try tests.testCredentialsAreReferencesOnly() }),
            ("testOnlyExplicitWebURLsAccepted", { tests.testOnlyExplicitWebURLsAccepted() }),
        ]
        for (name, run) in all {
            try run()
            print("PASS \(name)")
        }
        print("\(all.count) tests passed; \(assertionCount) assertions")
    }
}
