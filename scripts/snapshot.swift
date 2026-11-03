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

/// A made-up logo for the demo project, so screenshots show a project picture.
@MainActor
func demoLogo() -> Data? {
    let image = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
        NSGradient(starting: NSColor(srgbRed: 0.98, green: 0.62, blue: 0.32, alpha: 1), ending: NSColor(srgbRed: 0.86, green: 0.29, blue: 0.42, alpha: 1))?
            .draw(in: rect, angle: -60)
        NSColor(white: 1, alpha: 0.92).setFill()
        NSBezierPath(ovalIn: NSRect(x: 78, y: 92, width: 100, height: 100)).fill()
        let leaf = NSBezierPath()
        leaf.move(to: NSPoint(x: 40, y: 40)); leaf.curve(to: NSPoint(x: 216, y: 40), controlPoint1: NSPoint(x: 90, y: 120), controlPoint2: NSPoint(x: 166, y: 120))
        leaf.curve(to: NSPoint(x: 40, y: 40), controlPoint1: NSPoint(x: 166, y: 70), controlPoint2: NSPoint(x: 90, y: 70))
        NSColor(srgbRed: 0.1, green: 0.45, blue: 0.32, alpha: 1).setFill(); leaf.fill()
        return true
    }
    return ProjectImage.prepare(image)
}

@MainActor
func seed(_ store: Store) -> (ayuvam: Project, service: Entry) {
    let cal = Calendar.current
    let now = Date()
    let today = cal.startOfDay(for: now)
    func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: today)! }
    func at(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Date { cal.date(bySettingHour: hour, minute: minute, second: 0, of: day(offset))! }

    var ayuvam = Project(name: "Ayuvam", summary: "Ayurvedic wellness brand — D2C store, content, and community.", kind: .brand, color: "sage")
    ayuvam.image = demoLogo()
    ayuvam.remindersListID = "demo-ayuvam"
    store.save(ayuvam)
    var presently = Project(name: "Presently", summary: "Gift-planning app. Private beta with 40 testers.", kind: .product, status: .planning, color: "blue")
    presently.remindersListID = "demo-presently"
    store.save(presently)
    var site = Project(name: "Northwind website", summary: "Marketing site rebuild for Northwind Studio.", kind: .client, color: "orange")
    site.remindersListID = "demo-northwind"
    store.save(site)
    store.save(Project(name: "Brand refresh", summary: "Logo and type system.", kind: .client, status: .paused, color: "purple"))

    let repo = Entry(projectID: ayuvam.id, kind: .repository, title: "ayuvam-web", url: "https://github.com/example/ayuvam-web", category: "GitHub", pinned: true)
    store.save(repo)
    let service = Entry(projectID: ayuvam.id, kind: .service, title: "Vercel", url: "https://vercel.com/dashboard", body: "Hosts the landing page. Preview deploys on every PR.",
                        account: "studio@ayuvam.example", category: "Hosting", environment: "Production",
                        credentials: [CredentialRef(label: "Deploy token", username: "ci-bot")])
    store.save(service)
    let razorpay = Entry(projectID: ayuvam.id, kind: .service, title: "Razorpay", url: "https://dashboard.razorpay.com", account: "finance@ayuvam.example", category: "Payments", environment: "Production")
    store.save(razorpay)
    store.save(Entry(projectID: ayuvam.id, kind: .service, title: "Neon database", url: "https://console.neon.tech/app/projects", account: "studio@ayuvam.example", category: "Database", environment: "Staging"))
    store.save(Entry(projectID: ayuvam.id, kind: .link, title: "Resend", url: "https://resend.com/emails", category: "Tool"))
    store.save(Entry(projectID: ayuvam.id, kind: .link, title: "GoDaddy domains", url: "https://www.godaddy.com/", category: "Tool"))
    store.save(Entry(projectID: ayuvam.id, kind: .link, title: "Google Cloud console", url: "https://console.cloud.google.com/", category: "Tool"))
    store.save(Entry(projectID: ayuvam.id, kind: .social, title: "Ayuvam Instagram", url: "https://instagram.com/ayuvam", account: "@ayuvam", category: "Instagram"))
    store.save(Entry(projectID: ayuvam.id, kind: .social, title: "Ayuvam LinkedIn", url: "https://www.linkedin.com/company/ayuvam", category: "LinkedIn"))
    store.save(Entry(projectID: ayuvam.id, kind: .link, title: "Live store", url: "https://ayuvam.example", category: "Website", tags: ["live"], pinned: true))
    store.save(Entry(projectID: ayuvam.id, kind: .conversation, title: "Monsoon campaign ideas", url: "https://claude.ai/chat/example",
                     body: "Settled on three hero products and a ‘rituals’ angle.", category: "Claude", tags: ["marketing"]))
    store.save(Entry(projectID: ayuvam.id, kind: .document, title: "Brand guidelines", url: "https://www.figma.com/file/example", category: "Figma"))
    store.save(Entry(projectID: presently.id, kind: .service, title: "Supabase", url: "https://supabase.com/dashboard", category: "Database"))
    store.save(Entry(projectID: presently.id, kind: .repository, title: "presently-app", url: "https://github.com/example/presently", category: "GitHub"))
    store.save(Entry(projectID: site.id, kind: .document, title: "Homepage wireframes", url: "https://www.figma.com/file/northwind", category: "Figma"))

    let n1 = DiagramNode(label: "", entryID: repo.id, x: 200, y: 140)
    let n2 = DiagramNode(label: "", entryID: service.id, x: 480, y: 140)
    let n3 = DiagramNode(label: "Customers", x: 760, y: 140, kind: .person)
    let n4 = DiagramNode(label: "Old CDN", entryID: UUID(), x: 480, y: 330)
    var n5 = DiagramNode(label: "Orders database", x: 760, y: 330, kind: .database)
    n5.notes = "Neon Postgres in ap-south-1. Nightly backups; the staging branch resets every Monday. Ask Riya before changing the schema."
    let n6 = DiagramNode(label: "Ask Riya about the CDN contract before removing it. The renewal is in March.", x: 200, y: 340, kind: .note)
    let n7 = DiagramNode(label: "", entryID: razorpay.id, x: 1040, y: 140)
    store.upsert(Diagram(projectID: ayuvam.id, title: "Deployment flow", nodes: [n1, n2, n3, n4, n5, n6, n7],
                         edges: [DiagramEdge(from: n1.id, to: n2.id, label: "deploys to"), DiagramEdge(from: n2.id, to: n3.id, label: "serves"),
                                 DiagramEdge(from: n2.id, to: n4.id, dashed: true), DiagramEdge(from: n2.id, to: n5.id, label: "reads & writes"),
                                 DiagramEdge(from: n3.id, to: n7.id, label: "pay with")],
                         groups: [DiagramLayout.group(around: [n4, n5], or: .zero, title: "Data & delivery", color: "teal")]), in: \.diagrams)

    RemindersService.shared.useDemo([
        ReminderItem(listID: "demo-ayuvam", title: "Swap payment webhook to production keys", notes: "Razorpay → Settings → Webhooks", due: day(-2)),
        ReminderItem(listID: "demo-ayuvam", title: "Review landing page copy", due: at(0, 15), hasTime: true),
        ReminderItem(listID: "demo-ayuvam", title: "Post the monsoon carousel", due: at(0, 19), hasTime: true),
        ReminderItem(listID: "demo-ayuvam", title: "Renew ayuvam.com", due: day(4), repeats: .yearly),
        ReminderItem(listID: "demo-ayuvam", title: "Water the herb samples", due: day(1), repeats: .daily),
        ReminderItem(listID: "demo-ayuvam", title: "Think about an influencer list"),
        ReminderItem(listID: "demo-ayuvam", title: "Retouch product photos", isCompleted: true, completedAt: day(-1)),
        ReminderItem(listID: "demo-presently", title: "Send the beta survey", due: at(1, 10), hasTime: true),
        ReminderItem(listID: "demo-presently", title: "Weekly metrics review", due: day(3), repeats: .weekly),
        ReminderItem(listID: "demo-northwind", title: "Homepage wireframes to Maya", due: day(-1)),
    ], lists: [ReminderList(id: "demo-ayuvam", title: "Ayuvam"), ReminderList(id: "demo-presently", title: "Presently"), ReminderList(id: "demo-northwind", title: "Northwind website")])
    return (store.project(ayuvam.id)!, service)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "snapshots"
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-snapshot-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let empty = Store(directory: root.appendingPathComponent("empty"))
    let size = CGSize(width: 1380, height: 900)
    HomeView.greetingName = "Alex"
    snap(ContentView().environmentObject(empty).environmentObject(BackupManager(directory: root.appendingPathComponent("empty"))), size: size, to: "\(out)/00-welcome.png")

    let store = Store(directory: root.appendingPathComponent("data"))
    let backup = BackupManager(directory: root.appendingPathComponent("data"))
    let seeded = seed(store)
    @MainActor func page(_ route: Route, _ name: String, dark: Bool = false, launcher: Bool = false, chrome: Bool = false) {
        snap(ContentView(initialRoute: route, showLauncher: launcher).environmentObject(store).environmentObject(backup), size: size, dark: dark, chrome: chrome, to: "\(out)/\(name).png")
    }
    let id = seeded.ayuvam.id
    page(.home, "01-home", chrome: true)
    page(.home, "01-home-dark", dark: true)
    page(.home, "02-launcher", launcher: true)
    store.lastSection[id] = .map; page(.project(id), "10-map")
    page(.project(id), "10-map-dark", dark: true)
    if let map = store.workspace.diagrams.first(where: { $0.title == "Deployment flow" }) {
        let selected = map.nodes.first { $0.label == "Orders database" }?.id
        snap(DiagramEditor(diagram: map, others: [map], select: { _ in }, create: { _ in }, initialSelection: selected)
                .environmentObject(store).environment(\.pageTint, Theme.color("sage")),
             size: CGSize(width: 1300, height: 820), to: "\(out)/11-map-selected.png")
        let vercel = map.nodes.first { $0.entryID.flatMap { store.entry($0) }?.title == "Vercel" }?.id
        snap(DiagramEditor(diagram: map, others: [map], select: { _ in }, create: { _ in }, initialSelection: vercel)
                .environmentObject(store).environment(\.pageTint, Theme.color("sage")),
             size: CGSize(width: 1300, height: 820), to: "\(out)/11-map-linked.png")
        snap(DiagramEditor(diagram: map, others: [map], select: { _ in }, create: { _ in }, initiallyShowLinks: true)
                .environmentObject(store).environment(\.pageTint, Theme.color("sage")),
             size: CGSize(width: 1300, height: 820), to: "\(out)/12-links.png")
    }
    store.lastSection[id] = .reminders; page(.project(id), "13-reminders")
    page(.project(id), "13-reminders-dark", dark: true)
    snap(BackupView().environmentObject(store).environmentObject(backup), size: CGSize(width: 640, height: 700), to: "\(out)/20-backup.png")
    snap(EntryEditor(entry: seeded.service).environmentObject(store), size: CGSize(width: 660, height: 720), to: "\(out)/22-link-editor.png")
    snap(ProjectEditor(project: seeded.ayuvam).environmentObject(store), size: CGSize(width: 540, height: 500), to: "\(out)/23-project-editor.png")
    snap(MenuBarPanel().environmentObject(store).environmentObject(backup), size: CGSize(width: 400, height: 460), to: "\(out)/24-menubar.png")
}
