import AppKit
import UniformTypeIdentifiers

/// Project pictures: stored small, inside the project record, so they travel with backups.
enum ProjectImage {
    static let side = 256

    /// A square picture at most 256 px. Photos are cropped to fill the square; images with transparency
    /// (most logos) are fitted inside it so nothing is cut off. PNG keeps transparency, JPEG keeps photos small.
    static func prepare(_ image: NSImage) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil), source.width > 0, source.height > 0 else { return nil }
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(source.alphaInfo)
        let size = min(side, max(source.width, source.height))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let w = Double(source.width), h = Double(source.height), s = Double(size)
        let scale = hasAlpha ? min(s / w, s / h) : max(s / w, s / h)
        context.draw(source, in: CGRect(x: (s - w * scale) / 2, y: (s - h * scale) / 2, width: w * scale, height: h * scale))
        guard let output = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: output)
        return hasAlpha ? rep.representation(using: .png, properties: [:])
                        : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86])
    }

    static func prepare(contentsOf url: URL) -> Data? { NSImage(contentsOf: url).flatMap(prepare) }

    /// Asks for a picture file. Returns nil when cancelled or unreadable.
    @MainActor
    static func choose() -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a logo or picture for this project."
        panel.prompt = "Use Picture"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return prepare(contentsOf: url)
    }

    private static let cache = NSCache<NSString, NSImage>()

    static func image(for project: Project) -> NSImage? {
        guard let data = project.image else { return nil }
        let key = "\(project.id)-\(data.count)-\(data.prefix(64).hashValue)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Light, dark, or following the Mac.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    static let key = "appearance"
    var id: String { rawValue }
    var name: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    static var current: AppAppearance { AppAppearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }

    @MainActor static func apply(_ value: AppAppearance) {
        UserDefaults.standard.set(value.rawValue, forKey: key)
        NSApp.appearance = value.appearance
    }

    /// Whether Context is showing dark right now (whatever the setting).
    @MainActor static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
