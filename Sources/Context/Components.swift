import SwiftUI
import AppKit

// MARK: - Browsers

enum InstalledBrowsers {
    static func all() -> [URL] {
        guard let probe = URL(string: "https://example.com") else { return [] }
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: probe).filter { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard name != "Context", !seen.contains(name) else { return false }
            seen.insert(name)
            return true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    static func name(_ app: URL) -> String { FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "") }
    static func open(_ url: URL, with app: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct OpenInBrowserMenu: View {
    let url: URL
    var body: some View {
        Menu("Open in") {
            ForEach(InstalledBrowsers.all(), id: \.self) { app in
                Button { InstalledBrowsers.open(url, with: app) } label: {
                    Label { Text(InstalledBrowsers.name(app)) } icon: { Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)) }
                }
            }
        }
    }
}

func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
