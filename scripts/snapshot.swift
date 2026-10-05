// Renders the app's screens to PNG files using a demo workspace in a temporary directory.
// Usage: zsh scripts/snapshot.sh <output-dir>
import SwiftUI
import AppKit

@MainActor
func snap<V: View>(_ view: V, size: CGSize, dark: Bool = false, chrome: Bool = false, to path: String) {
    let host = NSHostingView(rootView: view)
    // Matches `.windowStyle(.hiddenTitleBar)`: content runs under a transparent title bar.
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: chrome ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.titled],
                          backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = chrome
    window.titleVisibility = chrome ? .hidden : .visible
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    if !chrome { host.frame = NSRect(origin: .zero, size: size) }
    for _ in 0..<5 {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }
    let target: NSView = chrome ? (host.superview ?? host) : host
    guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
    target.cacheDisplay(in: target.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

@MainActor
func seed(_ store: Store, folder: URL) -> (ayuvam: Project, northwind: Client, service: Entry, task: WorkTask) {
    let cal = Calendar.current
    let now = Date()
    func at(_ days: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(bySettingHour: hour, minute: minute, second: 0, of: cal.date(byAdding: .day, value: days, to: now)!)!
    }
    let client = Client(name: "Northwind Studio", contactName: "Maya Chen", email: "maya@northwind.example", website: "https://northwind.example",
                        notes: "Prefers weekly async updates on **Fridays**.\n\n- Invoices via Stripe\n- Brand files live in their shared drive")
    store.save(client)

    var ayuvam = Project(name: "Ayuvam", summary: "Ayurvedic wellness brand — D2C store, content, and community.", kind: .brand, color: "sage")
    ayuvam.contextNote = """
    Store is **live** on Shopify; the new landing page is in review on the staging deploy.
    - [x] Migrate product photos
    - [ ] Finish monsoon launch copy
    - [ ] Swap payment webhook to production keys
    > Next: ship the landing page, then start the influencer outreach list.
    """
    store.save(ayuvam)
    var presently = Project(name: "Presently", summary: "Gift-planning app. Private beta with 40 testers.", kind: .product, status: .planning, color: "blue")
    presently.createdAt = cal.date(byAdding: .day, value: -60, to: now)!
    store.save(presently)
    var site = Project(name: "Northwind website", summary: "Marketing site rebuild for Northwind Studio.", kind: .client, clientID: client.id, color: "orange")
    store.save(site)
    site.status = .active
    store.save(Project(name: "Brand refresh", summary: "Logo and type system.", kind: .client, status: .paused, clientID: client.id, color: "purple"))

    let bookmark = try! folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    let connection = FolderConnection(projectID: ayuvam.id, name: folder.lastPathComponent, path: folder.path, bookmark: bookmark, purpose: "Source code")
    store.upsert(connection, in: \.folders)

    var repo = Entry(projectID: ayuvam.id, kind: .repository, title: "ayuvam-web", url: "https://github.com/example/ayuvam-web", category: "GitHub", pinned: true)
    repo.folderID = connection.id
    store.save(repo)
    let service = Entry(projectID: ayuvam.id, kind: .service, title: "Vercel", url: "https://vercel.com/dashboard", body: "Hosts the landing page. Preview deploys on every PR.",
                        account: "studio@ayuvam.example", category: "Hosting", environment: "Production",
                        credentials: [CredentialRef(label: "Deploy token", username: "ci-bot")])
    store.save(service)
    store.save(Entry(projectID: ayuvam.id, kind: .service, title: "Razorpay", url: "https://dashboard.razorpay.com", account: "finance@ayuvam.example", category: "Payments", environment: "Production"))
    store.save(Entry(projectID: ayuvam.id, kind: .service, title: "Neon database", url: "https://console.neon.tech/app/projects", account: "studio@ayuvam.example", category: "Database", environment: "Staging"))
    store.save(Entry(projectID: ayuvam.id, kind: .link, title: "Resend", url: "https://resend.com/emails", category: "Tool"))
    store.save(Entry(projectID: ayuvam.id, kind: .link, title: "Paddle vendors", url: "https://vendors.paddle.com/", category: "Tool"))
    store.save(Entry(projectID: ayuvam.id, kind: .link, title: "GoDaddy domains", url: "https://www.godaddy.com/", category: "Tool"))
    store.save(Entry(projectID: ayuvam.id, kind: .link, title: "Zoho Mail admin", url: "https://mailadmin.zoho.in", category: "Tool"))
    store.save(Entry(projectID: ayuvam.id, kind: .link, title: "Google Cloud console", url: "https://console.cloud.google.com/", category: "Tool"))
    store.save(Entry(projectID: ayuvam.id, kind: .social, title: "Ayuvam LinkedIn", url: "https://www.linkedin.com/company/ayuvam", category: "LinkedIn"))
    store.save(Entry(projectID: ayuvam.id, kind: .social, title: "Ayuvam Behance", url: "https://www.behance.net/ayuvam", category: "Behance"))
    store.save(Entry(projectID: ayuvam.id, kind: .link, title: "Live store", url: "https://ayuvam.example", category: "Website", tags: ["live"], pinned: true))
    store.save(Entry(projectID: ayuvam.id, kind: .conversation, title: "Monsoon campaign ideas", url: "https://claude.ai/chat/example",
                     body: "Settled on three hero products and a ‘rituals’ angle. Rejected discount-led messaging.", category: "Claude", tags: ["marketing"]))
    store.save(Entry(projectID: ayuvam.id, kind: .document, title: "Brand guidelines", url: "https://www.figma.com/file/example", category: "Figma"))
    store.save(Entry(projectID: ayuvam.id, kind: .note, title: "Deployment checklist",
                     body: "# Deploying\n1. Merge to `main`\n2. Check the Vercel preview\n3. Promote to production\n\n```\nnpm run build && npm run test\n```", pinned: true))
    store.save(Entry(projectID: ayuvam.id, kind: .note, title: "Supplier contacts", body: "- Herbs: Kerala co-op\n- Packaging: GreenPack (quote pending)"))
    store.save(Entry(projectID: ayuvam.id, kind: .note, title: "Launch plan", body: """
    # Monsoon launch
    The landing page goes live **Friday**. Staging is on `ayuvam-staging.vercel.app`.

    ## Channels
    | Channel | Owner | Budget | Status |
    | --- | --- | ---: | :---: |
    | Instagram reels | Hitesh | ₹12,000 | In progress |
    | Facebook ads | Riya | ₹8,000 | Planned |
    | Email (Resend) | Hitesh | — | Ready |

    ## Checklist
    - [x] Product photos retouched
    - [ ] Final copy for the hero section
    - [ ] Switch Razorpay to live keys

    ## Deploy
    1. Merge `release` into `main`
    2. Check the Vercel preview
    3. Promote to production

    ```bash
    npm run build && npm run test
    ```

    > Keep discounts out of the messaging — lead with rituals.
    """))
    store.save(Entry(projectID: ayuvam.id, kind: .prompt, title: "Product description writer", body: "Write a warm, factual product description for {product}…", details: "Use with Claude; paste the ingredient list first."))
    store.save(Entry(projectID: ayuvam.id, kind: .social, title: "Ayuvam Instagram", url: "https://instagram.com/ayuvam", account: "@ayuvam", category: "Instagram", managementURL: "https://business.facebook.com"))
    store.save(Entry(projectID: ayuvam.id, kind: .social, title: "Ayuvam Facebook", url: "https://facebook.com/ayuvam", account: "Ayuvam", category: "Facebook"))

    let overdue = WorkTask(projectID: ayuvam.id, title: "Swap payment webhook to production keys", due: at(-2, 11), relatedIDs: [service.id])
    store.save(overdue)
    store.save(WorkTask(projectID: ayuvam.id, title: "Review landing page copy", due: at(0, 15), reminderLead: 30))
    store.save(WorkTask(projectID: ayuvam.id, title: "Water-log check", due: at(0, 18), repeatRule: RepeatRule(kind: .daily, extraTimes: [13 * 60])))
    store.save(WorkTask(projectID: presently.id, title: "Send beta survey", due: at(1, 10)))
    store.save(WorkTask(projectID: presently.id, title: "Weekly metrics review", due: at(3, 9), repeatRule: RepeatRule(kind: .weekly, weekdays: [2, 5])))
    store.save(WorkTask(projectID: site.id, title: "Homepage wireframes to Maya", due: at(-1, 17)))
    store.save(WorkTask(projectID: site.id, title: "Invoice follow-up", due: at(2, 12), repeatRule: RepeatRule(kind: .afterCompletion, interval: 14)))
    store.save(WorkTask(projectID: ayuvam.id, title: "Research influencer list", snoozedUntil: at(1, 9)))
    store.save(WorkTask(projectID: presently.id, title: "Think about referral rewards"))

    var post = ContentItem(projectID: ayuvam.id, title: "Monsoon launch carousel", caption: "Three rituals for the rainy season 🌧", due: at(0, 19),
                           targets: [PostTarget(platform: "Instagram", completedAt: now), PostTarget(platform: "Facebook"), PostTarget(platform: "LinkedIn"), PostTarget(platform: "Community newsletter")])
    post.assets = [folder.appendingPathComponent("hero.png").path]
    store.upsert(post, in: \.contentItems)
    store.upsert(ContentItem(projectID: ayuvam.id, title: "Founder story reel", due: at(3, 18), targets: [PostTarget(platform: "Instagram")]), in: \.contentItems)

    let n1 = DiagramNode(label: "", entryID: repo.id, x: 200, y: 140)
    let n2 = DiagramNode(label: "", entryID: service.id, x: 480, y: 140)
    let n3 = DiagramNode(label: "Customers", x: 760, y: 140, kind: .person)
    let n4 = DiagramNode(label: "Old CDN", entryID: UUID(), x: 480, y: 320)
    let n5 = DiagramNode(label: "Orders database", x: 760, y: 320, kind: .database)
    let n6 = DiagramNode(label: "Ask Riya about the CDN contract before removing it", x: 200, y: 330, kind: .note)
    store.upsert(Diagram(projectID: ayuvam.id, title: "Deployment flow", nodes: [n1, n2, n3, n4, n5, n6],
                         edges: [DiagramEdge(from: n1.id, to: n2.id, label: "deploys to"), DiagramEdge(from: n2.id, to: n3.id, label: "serves"), DiagramEdge(from: n2.id, to: n4.id, dashed: true),
                                 DiagramEdge(from: n2.id, to: n5.id, label: "reads & writes")]), in: \.diagrams)
    return (store.project(ayuvam.id)!, client, service, overdue)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "snapshots"
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-snapshot-\(UUID().uuidString)")
    let folder = root.appendingPathComponent("ayuvam-web")
    try! FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
    for name in ["README.md", "package.json", "hero.png", "vercel.json"] { try! Data("demo".utf8).write(to: folder.appendingPathComponent(name)) }
    defer { try? FileManager.default.removeItem(at: root) }

    let store = Store(directory: root.appendingPathComponent("data"))
    let backup = BackupManager(directory: root.appendingPathComponent("data"))
    let seeded = seed(store, folder: folder)
    let size = CGSize(width: 1380, height: 900)
    @MainActor func page(_ route: Route, _ name: String, dark: Bool = false, launcher: Bool = false, chrome: Bool = false) {
        snap(ContentView(initialRoute: route, showLauncher: launcher).environmentObject(store).environmentObject(backup), size: size, dark: dark, chrome: chrome, to: "\(out)/\(name).png")
    }
    let id = seeded.ayuvam.id
    HomeView.greetingName = "Alex"
    page(.home, "01-home", chrome: true)
    page(.home, "01-home-dark", dark: true)
    page(.home, "02-launcher", launcher: true)
    page(.tasks, "03-tasks")
    page(.client(seeded.northwind.id), "04-client")
    store.lastSection[id] = .overview; page(.project(id), "10-overview")
    store.lastSection[id] = .tasks; page(.project(id), "11-tasks")
    store.lastSection[id] = .links; page(.project(id), "12-links")
    store.lastSection[id] = .map; page(.project(id), "13-map")
    page(.project(id), "13-map-dark", dark: true)
    store.lastSection[id] = .notes
    store.selectedNote[id] = store.workspace.entries.first { $0.title == "Launch plan" }?.id
    page(.project(id), "14-notes")
    page(.project(id), "14-notes-dark", dark: true)
    let blank = Entry(projectID: id, kind: .note, title: "")
    store.save(blank); store.selectedNote[id] = blank.id
    page(.project(id), "15-note-editing")
    store.deleteEntry(blank.id)
    store.lastSection[id] = .files; page(.project(id), "16-files")
    store.lastSection[id] = .overview; page(.project(id), "17-overview-dark", dark: true)
    store.lastSection[id] = .notes
    snap(NoteDocument(noteID: store.workspace.entries.first { $0.title == "Launch plan" }!.id, startEditing: true).environmentObject(store).environment(\.pageTint, Theme.color("sage")),
         size: CGSize(width: 1100, height: 800), to: "\(out)/15-note-editing-content.png")
    snap(BackupView().environmentObject(store).environmentObject(backup), size: CGSize(width: 640, height: 700), to: "\(out)/20-backup.png")
    snap(TaskEditor(task: seeded.task).environmentObject(store), size: CGSize(width: 620, height: 720), to: "\(out)/21-task-editor.png")
    snap(EntryEditor(entry: seeded.service).environmentObject(store), size: CGSize(width: 660, height: 720), to: "\(out)/22-link-editor.png")
    snap(ProjectEditor(project: seeded.ayuvam).environmentObject(store), size: CGSize(width: 600, height: 700), to: "\(out)/23-project-editor.png")
    snap(MenuBarPanel().environmentObject(store).environmentObject(backup), size: CGSize(width: 400, height: 460), to: "\(out)/24-menubar.png")
    let empty = Store(directory: root.appendingPathComponent("empty"))
    snap(ContentView().environmentObject(empty).environmentObject(BackupManager(directory: root.appendingPathComponent("empty"))), size: size, to: "\(out)/00-welcome.png")
}
