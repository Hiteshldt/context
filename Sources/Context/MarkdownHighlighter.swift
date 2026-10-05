import AppKit

/// Computes which parts of Markdown source should be styled. Pure, so it can be tested without a text view.
enum MarkdownHighlighter {
    enum Style: Equatable { case heading(Int), marker, bold, italic, code, codeBlock, quote, table, link, done }
    struct Span: Equatable { let range: NSRange; let style: Style }

    private static let inline: [(NSRegularExpression, Style)] = {
        let patterns: [(String, Style)] = [
            ("`[^`\\n]+`", .code),
            ("\\*\\*[^*\\n]+\\*\\*", .bold),
            ("(?<![*\\w])\\*[^*\\n]+\\*(?![*\\w])", .italic),
            ("(?<![_\\w])_[^_\\n]+_(?![_\\w])", .italic),
            ("\\[[^\\]\\n]+\\]\\([^)\\n]+\\)", .link),
            ("https?://[^\\s)>\\]]+", .link),
        ]
        return patterns.compactMap { pattern, style in (try? NSRegularExpression(pattern: pattern)).map { ($0, style) } }
    }()

    static func spans(for text: String) -> [Span] {
        let ns = text as NSString
        var spans: [Span] = []
        var inFence = false
        var location = 0
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            let line = ns.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let leading = line.prefix { $0 == " " || $0 == "\t" }.utf16.count
            defer { location = NSMaxRange(lineRange) }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                spans.append(Span(range: lineRange, style: .codeBlock))
                continue
            }
            if inFence { spans.append(Span(range: lineRange, style: .codeBlock)); continue }
            if trimmed.isEmpty { continue }

            if case .heading(let level, _)? = Markdown.heading(trimmed) {
                spans.append(Span(range: lineRange, style: .heading(level)))
                spans.append(Span(range: NSRange(location: lineRange.location + leading, length: level), style: .marker))
                continue
            }
            if trimmed.hasPrefix("|") {
                spans.append(Span(range: lineRange, style: .table))
                continue
            }
            if trimmed.hasPrefix(">") {
                spans.append(Span(range: lineRange, style: .quote))
                spans.append(Span(range: NSRange(location: lineRange.location + leading, length: 1), style: .marker))
            } else if let check = Markdown.check(trimmed) {
                spans.append(Span(range: NSRange(location: lineRange.location + leading, length: 5), style: .marker))
                if check.done { spans.append(Span(range: NSRange(location: lineRange.location + leading + 6, length: max(0, (trimmed as NSString).length - 6)), style: .done)) }
            } else if Markdown.bullet(trimmed) != nil {
                spans.append(Span(range: NSRange(location: lineRange.location + leading, length: 1), style: .marker))
            } else if let numbered = Markdown.numbered(trimmed) {
                spans.append(Span(range: NSRange(location: lineRange.location + leading, length: numbered.number.utf16.count + 1), style: .marker))
            }
            for (regex, style) in inline {
                for match in regex.matches(in: text, range: lineRange) { spans.append(Span(range: match.range, style: style)) }
            }
        }
        return spans
    }

    static func apply(to storage: NSTextStorage, size: CGFloat, monospaced: Bool, tint: NSColor) {
        let full = NSRange(location: 0, length: storage.length)
        let base = monospaced ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular) : NSFont.systemFont(ofSize: size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.paragraphSpacing = 2
        storage.beginEditing()
        storage.setAttributes([.font: base, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: full)
        for span in spans(for: storage.string) where NSMaxRange(span.range) <= storage.length {
            switch span.style {
            case .heading(let level):
                let headingSize = level == 1 ? size + 8 : (level == 2 ? size + 4.5 : size + 1.5)
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: headingSize, weight: .bold), range: span.range)
            case .marker:
                storage.addAttribute(.foregroundColor, value: tint, range: span.range)
            case .bold:
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .bold), range: span.range)
            case .italic:
                storage.addAttribute(.font, value: NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask), range: span.range)
            case .code:
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: size - 1.5, weight: .medium),
                                       .backgroundColor: NSColor.labelColor.withAlphaComponent(0.07)], range: span.range)
            case .codeBlock:
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: size - 2, weight: .regular),
                                       .foregroundColor: NSColor.secondaryLabelColor], range: span.range)
            case .table:
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size - 2, weight: .regular), range: span.range)
            case .quote:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
            case .link:
                storage.addAttribute(.foregroundColor, value: tint, range: span.range)
            case .done:
                storage.addAttributes([.foregroundColor: NSColor.tertiaryLabelColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: span.range)
            }
        }
        storage.endEditing()
    }
}

