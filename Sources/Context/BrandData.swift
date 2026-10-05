import Foundation
import CoreGraphics
import AppKit

struct Brand: Identifiable, Equatable {
    let id: String
    let name: String
    let hex: String
    let hosts: [String]
    let keywords: [String]
    let path: String?

    var nsColor: NSColor { NSColor(hex: hex) ?? .gray }
    /// Light brand colours (e.g. Snapchat yellow) need a dark glyph.
    var glyphIsDark: Bool {
        guard let c = nsColor.usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.72
    }
    var badgeText: String { id == "linkedin" ? "in" : (id == "openai" ? "AI" : String(name.prefix(1))) }

    static func == (a: Brand, b: Brand) -> Bool { a.id == b.id }
}

extension BrandCatalog {
    private static var cache: [String: Brand?] = [:]
    private static let byID: [String: Brand] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func brand(id: String) -> Brand? { byID[id] }

    static func host(of url: String) -> String? {
        guard let host = URL(string: url.trimmingCharacters(in: .whitespaces))?.host()?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Finds the brand for a saved record: the URL's host wins, then an exact platform/type name, then words in the title.
    static func match(url: String, texts: [String]) -> Brand? {
        let key = url + "\u{1}" + texts.joined(separator: "\u{1}")
        if let cached = cache[key] { return cached }
        var best: (Brand, Int)?
        if let host = host(of: url) {
            for brand in all {
                for h in brand.hosts where host == h || host.hasSuffix("." + h) {
                    if best == nil || h.count > best!.1 { best = (brand, h.count) }
                }
            }
        }
        if best == nil {
            for raw in texts {
                let text = raw.lowercased().trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let words = " " + text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ") + " "
                for brand in all {
                    for keyword in brand.keywords {
                        let score = text == keyword ? 1000 + keyword.count : (words.contains(" \(keyword) ") ? keyword.count : 0)
                        if score > (best?.1 ?? 0) { best = (brand, score) }
                    }
                }
            }
        }
        cache[key] = best?.0
        return best?.0
    }

    static func brand(for entry: Entry) -> Brand? {
        match(url: entry.url.isEmpty ? entry.managementURL : entry.url, texts: [entry.category, entry.title])
    }

    /// For platform names such as "Instagram" or a custom one the user typed.
    static func named(_ platform: String) -> Brand? { match(url: "", texts: [platform]) }

    static let socialPlatformIDs = ["instagram", "facebook", "x", "linkedin", "threads", "tiktok", "youtube", "pinterest",
                                    "reddit", "snapchat", "whatsapp", "telegram", "discord", "bluesky", "mastodon", "tumblr",
                                    "medium", "substack", "behance", "dribbble", "twitch", "producthunt", "quora"]
    static var socialPlatforms: [Brand] { socialPlatformIDs.compactMap { byID[$0] } }
}

// MARK: - SVG path parsing

/// Parses SVG path data (all commands, including arcs) in Simple Icons' 24×24 coordinate space.
enum SVGPath {
    private static var cache: [String: CGPath] = [:]

    static func path(_ data: String) -> CGPath {
        if let cached = cache[data] { return cached }
        let parsed = parse(data)
        cache[data] = parsed
        return parsed
    }

    static func parse(_ data: String) -> CGPath {
        let path = CGMutablePath()
        let chars = Array(data.utf8)
        var i = 0
        var current = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: UInt8 = 0

        func skipSeparators() { while i < chars.count, chars[i] == 32 || chars[i] == 44 || chars[i] == 10 || chars[i] == 13 || chars[i] == 9 { i += 1 } }
        func number() -> CGFloat? {
            skipSeparators()
            guard i < chars.count else { return nil }
            let begin = i
            if chars[i] == 43 || chars[i] == 45 { i += 1 }
            var sawDot = false, sawDigit = false
            while i < chars.count {
                let c = chars[i]
                if c >= 48 && c <= 57 { sawDigit = true; i += 1 }
                else if c == 46 && !sawDot { sawDot = true; i += 1 }
                else if (c == 101 || c == 69) && sawDigit {
                    i += 1
                    if i < chars.count, chars[i] == 43 || chars[i] == 45 { i += 1 }
                } else { break }
            }
            guard sawDigit, let string = String(bytes: chars[begin..<i], encoding: .ascii), let value = Double(string) else { i = begin; return nil }
            return CGFloat(value)
        }
        func flag() -> Bool? {
            skipSeparators()
            guard i < chars.count, chars[i] == 48 || chars[i] == 49 else { return nil }
            defer { i += 1 }
            return chars[i] == 49
        }
        func isCommand(_ c: UInt8) -> Bool { "MmLlHhVvCcSsQqTtAaZz".utf8.contains(c) }

        while i < chars.count {
            skipSeparators()
            guard i < chars.count else { break }
            var command = chars[i]
            if isCommand(command) { i += 1 } else if lastCommand != 0 {
                // Implicit repetition; a repeated moveto becomes a lineto.
                command = lastCommand == 77 ? 76 : (lastCommand == 109 ? 108 : lastCommand)
            } else { break }
            let relative = command >= 97
            let base = relative ? current : .zero
            switch command | 0x20 {
            case 109: // m
                guard let x = number(), let y = number() else { return path }
                current = CGPoint(x: base.x + x, y: base.y + y); start = current
                path.move(to: current); lastControl = nil
            case 108: // l
                guard let x = number(), let y = number() else { return path }
                current = CGPoint(x: base.x + x, y: base.y + y); path.addLine(to: current); lastControl = nil
            case 104: // h
                guard let x = number() else { return path }
                current.x = relative ? current.x + x : x; path.addLine(to: current); lastControl = nil
            case 118: // v
                guard let y = number() else { return path }
                current.y = relative ? current.y + y : y; path.addLine(to: current); lastControl = nil
            case 99: // c
                guard let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(), let x = number(), let y = number() else { return path }
                let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                current = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: current, control1: CGPoint(x: base.x + x1, y: base.y + y1), control2: c2)
                lastControl = c2
            case 115: // s
                guard let x2 = number(), let y2 = number(), let x = number(), let y = number() else { return path }
                let previous = "CcSs".utf8.contains(lastCommand) ? lastControl : nil
                let c1 = previous.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                current = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2
            case 113: // q
                guard let x1 = number(), let y1 = number(), let x = number(), let y = number() else { return path }
                let c = CGPoint(x: base.x + x1, y: base.y + y1)
                current = CGPoint(x: base.x + x, y: base.y + y)
                path.addQuadCurve(to: current, control: c); lastControl = c
            case 116: // t
                guard let x = number(), let y = number() else { return path }
                let previous = "QqTt".utf8.contains(lastCommand) ? lastControl : nil
                let c = previous.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                current = CGPoint(x: base.x + x, y: base.y + y)
                path.addQuadCurve(to: current, control: c); lastControl = c
            case 97: // a
                guard let rx = number(), let ry = number(), let rotation = number(), let large = flag(), let sweep = flag(),
                      let x = number(), let y = number() else { return path }
                let end = CGPoint(x: base.x + x, y: base.y + y)
                addArc(path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end; lastControl = nil
            case 122: // z
                path.closeSubpath(); current = start; lastControl = nil
            default:
                return path
            }
            lastCommand = command
        }
        return path
    }

    /// Converts an SVG endpoint arc into cubic Béziers (at most 90° each).
    static func addArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy, y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coefficient = denominator == 0 ? 0 : sqrt(max(0, numerator / denominator))
        if large == sweep { coefficient = -coefficient }
        let cxp = coefficient * rx * y1p / ry, cyp = -coefficient * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let sign: CGFloat = ux * vy - uy * vx < 0 ? -1 : 1
            let dot = (ux * vx + uy * vy) / (sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy))
            return sign * acos(min(1, max(-1, dot)))
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let t = 4 / 3 * tan(step / 4)
        var theta = theta1
        func point(_ a: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(a) * cosPhi - ry * sin(a) * sinPhi, y: cy + rx * cos(a) * sinPhi + ry * sin(a) * cosPhi)
        }
        func derivative(_ a: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(a) * cosPhi - ry * cos(a) * sinPhi, y: -rx * sin(a) * sinPhi + ry * cos(a) * cosPhi)
        }
        for _ in 0..<segments {
            let next = theta + step
            let a = point(theta), b = point(next), da = derivative(theta), db = derivative(next)
            path.addCurve(to: b, control1: CGPoint(x: a.x + t * da.x, y: a.y + t * da.y), control2: CGPoint(x: b.x - t * db.x, y: b.y - t * db.y))
            theta = next
        }
    }
}


extension NSColor {
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = Int(value, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((number >> 16) & 0xFF) / 255, green: CGFloat((number >> 8) & 0xFF) / 255, blue: CGFloat(number & 0xFF) / 255, alpha: 1)
    }
}
