import Foundation
import AppKit

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
        XCTAssertTrue(workspace.projects[0].shows(.notes))
        XCTAssertFalse(workspace.projects[0].shows(.files))
        XCTAssertFalse(workspace.projects[0].shows(.links))
        XCTAssertEqual(workspace.projects[0].sections.count, ProjectSection.allCases.count)
        XCTAssertEqual(workspace.tasks[0].repeatRule, RepeatRule(kind: .everyNDays, interval: 3))
        XCTAssertEqual(workspace.tasks[0].reminderLead, 0)
        // Saving and reloading keeps the migrated shape without legacy fields.
        let disk = WorkspaceDisk(directory: try temporaryDirectory())
        try disk.save(workspace)
        XCTAssertEqual(try disk.load(), workspace)
        XCTAssertFalse(String(decoding: try Data(contentsOf: disk.file), as: UTF8.self).contains("\"client\""))
    }

    func testMergedSectionsMigrate() throws {
        let json = """
        [{"section": "Overview", "title": "", "enabled": true}, {"section": "Services", "title": "Hosting", "enabled": false},
         {"section": "Resources", "title": "", "enabled": true}, {"section": "Prompts", "title": "", "enabled": true},
         {"section": "Notes", "title": "Journal", "enabled": false}, {"section": "Image Tools", "title": "", "enabled": true}]
        """
        let configs = SectionConfig.normalized(try JSONDecoder().decode([SectionConfig].self, from: Data(json.utf8)))
        XCTAssertEqual(configs.map(\.section), [.overview, .links, .map, .notes, .files, .tasks])
        let links = configs[1], map = configs[2], notes = configs[3]
        XCTAssertTrue(links.enabled)            // Resources was shown, so the merged section is shown.
        XCTAssertEqual(links.title, "")         // "Hosting" named only the old Services section.
        XCTAssertTrue(map.enabled)              // The map lived inside Links, so it follows Links.
        XCTAssertTrue(notes.enabled)            // Prompts was shown.
        XCTAssertTrue(configs[4].enabled)       // Image Tools → Files & Tools.
        XCTAssertFalse(configs[5].enabled)      // Tasks was missing: appended hidden.
    }

    func testMapBecomesItsOwnTab() throws {
        // A project saved in the old default order moves to the new one.
        let old = [ProjectSection.overview, .tasks, .links, .notes, .files].map { SectionConfig(section: $0) }
        XCTAssertEqual(SectionConfig.normalized(old).map(\.section), [.overview, .tasks, .links, .map, .files, .notes])
        XCTAssertTrue(SectionConfig.normalized(old).allSatisfy(\.enabled))
        // A custom order is kept; Map slots in after Links and stays hidden when Links was hidden.
        let custom = [SectionConfig(section: .overview), SectionConfig(section: .notes, title: "Journal"),
                      SectionConfig(section: .links, enabled: false), SectionConfig(section: .tasks), SectionConfig(section: .files)]
        let configs = SectionConfig.normalized(custom)
        XCTAssertEqual(configs.map(\.section), [.overview, .notes, .links, .map, .tasks, .files])
        XCTAssertFalse(configs[3].enabled)
        XCTAssertEqual(configs[1].displayName, "Journal")
        // The old "Diagrams" section now means Map.
        XCTAssertEqual(ProjectSection.migrating("Diagrams"), .map)
        // New projects use the new order.
        XCTAssertEqual(Project(name: "New").sections.map(\.section), [.overview, .tasks, .links, .map, .files, .notes])
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
        let spans = MarkdownHighlighter.spans(for: "# Head\n**bold** and `code`\n```\nx\n```")
        XCTAssertTrue(spans.contains(.init(range: NSRange(location: 0, length: 7), style: .heading(1))))
        XCTAssertTrue(spans.contains { $0.style == .bold && $0.range == NSRange(location: 7, length: 8) })
        XCTAssertTrue(spans.contains { $0.style == .code && $0.range.length == 6 })
        XCTAssertEqual(spans.filter { $0.style == .codeBlock }.count, 3)
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
    }

    func testMarkdownFilesReadInPlace() throws {
        XCTAssertTrue(MarkdownFile.matches(URL(fileURLWithPath: "/x/README.md")))
        XCTAssertTrue(MarkdownFile.matches(URL(fileURLWithPath: "/x/Notes.MARKDOWN")))
        XCTAssertFalse(MarkdownFile.matches(URL(fileURLWithPath: "/x/notes.txt")))
        XCTAssertEqual(MarkdownFile.withoutFrontMatter("---\ntitle: Hi\n---\n# Heading\nBody"), "# Heading\nBody")
        XCTAssertEqual(MarkdownFile.withoutFrontMatter("# No front matter\n---\nrule"), "# No front matter\n---\nrule")
        let folder = try temporaryDirectory()
        let file = folder.appendingPathComponent("plan.md")
        try Data("# Plan\n- [ ] Ship".utf8).write(to: file)
        let before = try Data(contentsOf: file)
        XCTAssertEqual(try MarkdownFile.load(file), "# Plan\n- [ ] Ship")
        XCTAssertEqual(try Data(contentsOf: file), before)   // Reading never changes the original.
        let big = folder.appendingPathComponent("huge.md")
        try Data(repeating: 65, count: MarkdownFile.sizeLimit + 1).write(to: big)
        XCTAssertThrowsError(try MarkdownFile.load(big))
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
        // Connectors leave from the facing sides.
        let left = CGRect(x: 0, y: 0, width: 100, height: 50), right = CGRect(x: 300, y: 0, width: 100, height: 50)
        let c1 = DiagramLayout.connector(from: left, to: right)
        XCTAssertEqual(c1.start, CGPoint(x: 100, y: 25))
        XCTAssertTrue(c1.end.x < 300)
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

    func testSectionConfigNormalizes() {
        let configs = SectionConfig.normalized([SectionConfig(section: .notes, title: "Journal"), SectionConfig(section: .notes, enabled: false), SectionConfig(section: .overview, enabled: false)])
        XCTAssertEqual(configs.first?.section, .overview)
        XCTAssertTrue(configs[0].enabled)
        XCTAssertEqual(configs[1].displayName, "Journal")
        XCTAssertEqual(configs.count, ProjectSection.allCases.count)
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

    func testFolderBrowsingDoesNotRecurseOrModifyOriginals() throws {
        let root = try temporaryDirectory()
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let content = Data("original".utf8)
        let file = root.appendingPathComponent("note.txt")
        try content.write(to: file)
        try content.write(to: nested.appendingPathComponent("deep.txt"))
        let listing = try FolderListing.read(root)
        XCTAssertEqual(Set(listing.items.map { $0.url.lastPathComponent }), ["nested", "note.txt"])
        XCTAssertEqual(try Data(contentsOf: file), content)
        XCTAssertFalse(listing.truncated)
    }

    func testFolderListingIsBoundedAndPages() throws {
        let root = try temporaryDirectory()
        for i in 0..<510 { try Data().write(to: root.appendingPathComponent("\(i).txt")) }
        let listing = try FolderListing.read(root)
        XCTAssertEqual(listing.items.count, 500)
        XCTAssertTrue(listing.truncated)
        let more = try FolderListing.read(root, limit: 1000)
        XCTAssertEqual(more.items.count, 510)
        XCTAssertFalse(more.truncated)
    }

    func testMovedFolderResolvesAndMissingFolderReportsUnavailable() throws {
        let root = try temporaryDirectory()
        let original = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        let bookmark = try original.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let folder = FolderConnection(projectID: UUID(), name: "assets", path: original.path, bookmark: bookmark)
        let moved = root.appendingPathComponent("assets-renamed")
        try FileManager.default.moveItem(at: original, to: moved)
        let result = resolveFolder(folder)
        guard case .available(let resolved) = result.status else { fatalError("Moved folder should resolve") }
        XCTAssertEqual(resolved.lastPathComponent, "assets-renamed")
        XCTAssertEqual(result.refreshed.map { URL(fileURLWithPath: $0.path).lastPathComponent }, "assets-renamed")
        try FileManager.default.removeItem(at: moved)
        if case .available = resolveFolder(folder).status { fatalError("Deleted folder should be unavailable") }
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
        try tests.testWorkspaceRoundTripAndPreviousVersionBackup()
        print("PASS testWorkspaceRoundTripAndPreviousVersionBackup")
        try tests.testCorruptDataIsNotSilentlyReplaced()
        print("PASS testCorruptDataIsNotSilentlyReplaced")
        try tests.testInvalidReferencesAndVersionsRejected()
        print("PASS testInvalidReferencesAndVersionsRejected")
        try tests.testVersionOneDataMigrates()
        print("PASS testVersionOneDataMigrates")
        try tests.testMergedSectionsMigrate()
        print("PASS testMergedSectionsMigrate")
        try tests.testMapBecomesItsOwnTab()
        print("PASS testMapBecomesItsOwnTab")
        tests.testBrandMatching()
        print("PASS testBrandMatching")
        tests.testEveryBrandIconParses()
        print("PASS testEveryBrandIconParses")
        tests.testMarkdownTablesAndBlocks()
        print("PASS testMarkdownTablesAndBlocks")
        tests.testMarkdownEditingHelpers()
        print("PASS testMarkdownEditingHelpers")
        try tests.testMapNodesDecodeWithoutNewFields()
        print("PASS testMapNodesDecodeWithoutNewFields")
        try tests.testMapGroups()
        print("PASS testMapGroups")
        try tests.testMarkdownFilesReadInPlace()
        print("PASS testMarkdownFilesReadInPlace")
        tests.testMapTidyAndBuildFromLinks()
        print("PASS testMapTidyAndBuildFromLinks")
        tests.testLauncherRanking()
        print("PASS testLauncherRanking")
        try tests.testBackupWriterKeepsOneFilePerDayAndPrunes()
        print("PASS testBackupWriterKeepsOneFilePerDayAndPrunes")
        try tests.testCloudFolderDetection()
        print("PASS testCloudFolderDetection")
        tests.testDuplicateIdentifiersRejected()
        print("PASS testDuplicateIdentifiersRejected")
        tests.testRecurringTaskRequiresDueDate()
        print("PASS testRecurringTaskRequiresDueDate")
        tests.testDiagramEdgesMustReferenceNodes()
        print("PASS testDiagramEdgesMustReferenceNodes")
        tests.testOneOffCompletionPreservesHistory()
        print("PASS testOneOffCompletionPreservesHistory")
        tests.testRecurringCompletionAdvancesPastMissedDates()
        print("PASS testRecurringCompletionAdvancesPastMissedDates")
        tests.testDailyRecurrencePreservesWallClockAcrossDaylightSaving()
        print("PASS testDailyRecurrencePreservesWallClockAcrossDaylightSaving")
        tests.testCompletingEarlyAdvancesExactlyOneOccurrence()
        print("PASS testCompletingEarlyAdvancesExactlyOneOccurrence")
        tests.testWeeklyOnSelectedWeekdays()
        print("PASS testWeeklyOnSelectedWeekdays")
        tests.testMultipleTimesPerDay()
        print("PASS testMultipleTimesPerDay")
        tests.testFollowUpAfterCompletion()
        print("PASS testFollowUpAfterCompletion")
        tests.testSnoozeDoesNotChangeRecurrence()
        print("PASS testSnoozeDoesNotChangeRecurrence")
        tests.testNotificationTimeIndependentOfDueDate()
        print("PASS testNotificationTimeIndependentOfDueDate")
        tests.testPostingCompletionIsPerPlatform()
        print("PASS testPostingCompletionIsPerPlatform")
        tests.testSectionConfigNormalizes()
        print("PASS testSectionConfigNormalizes")
        try tests.testCredentialsAreReferencesOnly()
        print("PASS testCredentialsAreReferencesOnly")
        tests.testOnlyExplicitWebURLsAccepted()
        print("PASS testOnlyExplicitWebURLsAccepted")
        try tests.testFolderBrowsingDoesNotRecurseOrModifyOriginals()
        print("PASS testFolderBrowsingDoesNotRecurseOrModifyOriginals")
        try tests.testFolderListingIsBoundedAndPages()
        print("PASS testFolderListingIsBoundedAndPages")
        try tests.testMovedFolderResolvesAndMissingFolderReportsUnavailable()
        print("PASS testMovedFolderResolvesAndMissingFolderReportsUnavailable")
        print("36 tests passed; \(assertionCount) assertions")
    }
}
