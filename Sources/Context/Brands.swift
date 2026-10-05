import SwiftUI
import AppKit

extension Brand { var color: Color { Color(nsColor: nsColor) } }

struct BrandGlyph: Shape {
    let data: String
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        return Path(SVGPath.path(data)).applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.minX + (rect.width - 24 * scale) / 2, y: rect.minY + (rect.height - 24 * scale) / 2)))
    }
}

// MARK: - Icons

/// A brand's logo in white (or black on light colours) on a tile of its brand colour.
struct BrandBadge: View {
    let brand: Brand
    var size: CGFloat = 30
    var body: some View {
        let glyph: Color = brand.glyphIsDark ? .black : .white
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(brand.color)
            if let data = brand.path {
                BrandGlyph(data: data).fill(glyph, style: FillStyle(eoFill: false)).frame(width: size * 0.56, height: size * 0.56)
            } else {
                Text(brand.badgeText).font(.system(size: size * 0.42, weight: .bold, design: .rounded)).foregroundStyle(glyph)
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .help(brand.name)
        .accessibilityLabel(brand.name)
    }
}

/// Icon for a saved record: brand logo, else the website's own icon, else the record type.
struct EntryIcon: View {
    let entry: Entry
    var size: CGFloat = 30
    var body: some View {
        if let brand = BrandCatalog.brand(for: entry) {
            BrandBadge(brand: brand, size: size)
        } else {
            SiteIcon(url: entry.url, fallback: entry.kind.icon, size: size)
        }
    }
}

/// A platform chip icon for social posting ("Instagram", or any custom platform).
struct PlatformIcon: View {
    let platform: String
    var size: CGFloat = 18
    var body: some View {
        if let brand = BrandCatalog.named(platform) {
            BrandBadge(brand: brand, size: size)
        } else {
            Text(String(platform.prefix(1)).uppercased())
                .font(.system(size: size * 0.5, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Theme.muted, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        }
    }
}

struct SiteIcon: View {
    @ObservedObject private var icons = SiteIconStore.shared
    let url: String
    var fallback = "globe"
    var size: CGFloat = 30
    var body: some View {
        let host = BrandCatalog.host(of: url)
        Group {
            if host != nil, let brand = BrandCatalog.match(url: url, texts: []) {
                BrandBadge(brand: brand, size: size)
            } else if let host, let image = icons.image(for: host) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .padding(size * 0.14)
                    .frame(width: size, height: size)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            } else {
                Image(systemName: fallback).font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(Theme.accent)
                    .frame(width: size, height: size)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            }
        }
        .task(id: host) { if let host, BrandCatalog.match(url: url, texts: []) == nil { icons.request(host) } }
    }
}

/// Downloads each website's own icon once (directly from that site, never via a third party) and caches it on disk.
@MainActor
final class SiteIconStore: ObservableObject {
    static let shared = SiteIconStore()
    @Published private var images: [String: NSImage] = [:]
    private var inFlight = Set<String>()
    private var failures: [String: Date] = [:]
    var directory: URL?
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "downloadSiteIcons") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "downloadSiteIcons"); objectWillChange.send() }
    }
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh) Context/1.0"]
        return URLSession(configuration: config)
    }()

    private func file(_ host: String) -> URL? { directory?.appendingPathComponent("\(host).png") }

    func image(for host: String) -> NSImage? {
        if let image = images[host] { return image }
        if let file = file(host), let image = NSImage(contentsOf: file) {
            DispatchQueue.main.async { self.images[host] = image }
            return image
        }
        return nil
    }

    func request(_ host: String) {
        guard enabled, directory != nil, images[host] == nil, !inFlight.contains(host),
              (failures[host] ?? .distantPast) < Date().addingTimeInterval(-86_400 * 7),
              let file = file(host), !FileManager.default.fileExists(atPath: file.path) else { return }
        inFlight.insert(host)
        Task {
            let image = await fetch(host)
            inFlight.remove(host)
            guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { failures[host] = Date(); return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? png.write(to: file, options: .atomic)
            images[host] = image
        }
    }

    private func fetch(_ host: String) async -> NSImage? {
        guard let root = URL(string: "https://\(host)/") else { return nil }
        var candidates: [URL] = []
        if let (data, _) = try? await session.data(from: root), let html = String(data: data.prefix(200_000), encoding: .utf8) ?? String(data: data.prefix(200_000), encoding: .isoLatin1) {
            candidates += Self.iconLinks(in: html, base: root)
        }
        candidates += ["apple-touch-icon.png", "favicon.ico"].compactMap { URL(string: $0, relativeTo: root)?.absoluteURL }
        for url in candidates {
            guard url.scheme == "https", let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000,
                  let image = NSImage(data: data), image.size.width >= 8 else { continue }
            return image
        }
        return nil
    }

    /// Picks `<link rel="…icon…">` hrefs, preferring apple-touch-icon and larger sizes.
    static func iconLinks(in html: String, base: URL) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: "<link[^>]+>", options: [.caseInsensitive]) else { return [] }
        var found: [(URL, Int)] = []
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            func attribute(_ name: String) -> String? {
                guard let r = try? NSRegularExpression(pattern: "\(name)\\s*=\\s*[\"']([^\"']+)[\"']", options: .caseInsensitive),
                      let m = r.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)), let v = Range(m.range(at: 1), in: tag) else { return nil }
                return String(tag[v])
            }
            guard let rel = attribute("rel")?.lowercased(), rel.contains("icon"), !rel.contains("mask"),
                  let href = attribute("href"), !href.hasSuffix(".svg"), let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            let size = Int(attribute("sizes")?.split(separator: "x").first ?? "") ?? (rel.contains("apple") ? 180 : 32)
            found.append((url, size))
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

/// Renders brand badges as images for use inside menus, which can't host custom views.
@MainActor
enum BrandImages {
    private static var cache: [String: NSImage] = [:]
    static func image(_ brand: Brand, size: CGFloat = 16) -> NSImage {
        let key = "\(brand.id)-\(size)"
        if let cached = cache[key] { return cached }
        let renderer = ImageRenderer(content: BrandBadge(brand: brand, size: size))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        cache[key] = image
        return image
    }
}
