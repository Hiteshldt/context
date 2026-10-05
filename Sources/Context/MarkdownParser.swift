import Foundation

enum MDAlign: Equatable { case leading, center, trailing }

enum MDBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(text: String, indent: Int)
    case numbered(number: String, text: String, indent: Int)
    /// `line` is the zero-based source line, so a rendered checkbox can be toggled in the text.
    case check(done: Bool, text: String, line: Int, indent: Int)
    case quote(String)
    case code(language: String, text: String)
    case table(header: [String], alignments: [MDAlign], rows: [[String]])
    case rule
}

/// A small Markdown parser covering what notes actually use: headings, lists, checklists, quotes,
/// fenced code, tables, and rules. Inline styles are left to `AttributedString`.
enum Markdown {
    static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    static func parse(_ text: String) -> [MDBlock] {
        let lines = lines(text)
        var blocks: [MDBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        func flushParagraph() { if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
        func flushQuote() { if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] } }
        func flush() { flushParagraph(); flushQuote() }

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                let fence = String(line.prefix(3))
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { body.append(lines[i]); i += 1 }
                blocks.append(.code(language: language, text: body.joined(separator: "\n")))
                i += 1
                continue
            }
            if line.isEmpty { flush(); i += 1; continue }

            // Table: a row of cells followed by a separator row.
            if line.contains("|"), i + 1 < lines.count, let alignments = separator(lines[i + 1]) {
                let header = cells(line)
                if header.count == alignments.count || header.count > 1 {
                    flush()
                    var rows: [[String]] = []
                    i += 2
                    while i < lines.count {
                        let next = lines[i].trimmingCharacters(in: .whitespaces)
                        guard !next.isEmpty, next.contains("|") else { break }
                        var row = cells(next)
                        if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                        rows.append(Array(row.prefix(header.count)))
                        i += 1
                    }
                    let aligned = (0..<header.count).map { $0 < alignments.count ? alignments[$0] : .leading }
                    blocks.append(.table(header: header, alignments: aligned, rows: rows))
                    continue
                }
            }

            let indent = indentLevel(raw)
            if let heading = heading(line) { flush(); blocks.append(heading) }
            else if isRule(line) { flush(); blocks.append(.rule) }
            else if line.hasPrefix(">") {
                flushParagraph()
                var content = Substring(line)
                while content.hasPrefix(">") { content = content.dropFirst(); if content.hasPrefix(" ") { content = content.dropFirst() } }
                quote.append(String(content))
            }
            else if let check = check(line) { flush(); blocks.append(.check(done: check.done, text: check.text, line: i, indent: indent)) }
            else if let bullet = bullet(line) { flush(); blocks.append(.bullet(text: bullet, indent: indent)) }
            else if let numbered = numbered(line) { flush(); blocks.append(.numbered(number: numbered.number, text: numbered.text, indent: indent)) }
            else { flushQuote(); paragraph.append(line) }
            i += 1
        }
        flush()
        return blocks
    }

    static func indentLevel(_ raw: String) -> Int {
        var spaces = 0
        for character in raw {
            if character == " " { spaces += 1 } else if character == "\t" { spaces += 4 } else { break }
        }
        return min(4, spaces / 2)
    }

    static func heading(_ line: String) -> MDBlock? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.hasPrefix(" ") else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func check(_ line: String) -> (done: Bool, text: String)? {
        for marker in ["- [", "* [", "+ ["] where line.hasPrefix(marker) {
            let rest = line.dropFirst(3)
            guard let state = rest.first, rest.dropFirst().hasPrefix("]") else { return nil }
            guard state == " " || state == "x" || state == "X" else { return nil }
            return (state != " ", rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func bullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) { return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        return nil
    }

    static func numbered(_ line: String) -> (number: String, text: String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().hasPrefix(" ") else { return nil }
        return (String(digits), rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }

    /// Splits a table row into cells, honouring `\|` escapes and pipes inside inline code.
    static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var inCode = false
        var previous: Character?
        for character in line.trimmingCharacters(in: .whitespaces) {
            if character == "`" { inCode.toggle() }
            if character == "|" && !inCode && previous != "\\" {
                cells.append(current); current = ""
            } else {
                if character == "|" && previous == "\\" { current.removeLast() }
                current.append(character)
            }
            previous = character
        }
        cells.append(current)
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Recognises a table separator row such as `| --- | :---: | ---: |` and returns the column alignments.
    static func separator(_ line: String) -> [MDAlign]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // A separator must contain a pipe, so a plain `---` rule under a line of text isn't mistaken for a table.
        guard trimmed.contains("-"), trimmed.contains("|"), trimmed.allSatisfy({ "|-: ".contains($0) }) else { return nil }
        let parts = cells(trimmed)
        guard !parts.isEmpty, parts.allSatisfy({ $0.contains("-") }) else { return nil }
        return parts.map { part in
            let left = part.hasPrefix(":"), right = part.hasSuffix(":")
            return left && right ? .center : (right ? .trailing : .leading)
        }
    }

    // MARK: Helpers for the UI

    /// Flips `- [ ]` ⇄ `- [x]` on a source line.
    static func toggleCheck(in text: String, line: Int) -> String {
        var all = lines(text)
        guard all.indices.contains(line) else { return text }
        if let range = all[line].range(of: "[ ]") { all[line].replaceSubrange(range, with: "[x]") }
        else if let range = all[line].range(of: "[x]") ?? all[line].range(of: "[X]") { all[line].replaceSubrange(range, with: "[ ]") }
        return all.joined(separator: "\n")
    }

    static func outline(_ blocks: [MDBlock]) -> [(index: Int, level: Int, title: String)] {
        blocks.enumerated().compactMap { index, block in
            if case .heading(let level, let text) = block, level <= 3 { return (index, level, stripInline(text)) }
            return nil
        }
    }

    /// Removes inline markers for previews and outlines.
    static func stripInline(_ text: String) -> String {
        var result = text
        for marker in ["**", "__", "`", "~~"] { result = result.replacingOccurrences(of: marker, with: "") }
        // [label](url) → label
        while let open = result.range(of: "]("), let start = result[..<open.lowerBound].lastIndex(of: "["),
              let close = result[open.upperBound...].firstIndex(of: ")") {
            let label = String(result[result.index(after: start)..<open.lowerBound])
            result.replaceSubrange(start...close, with: label)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// A one-line plain preview of a note.
    static func plain(_ text: String, limit: Int = 220) -> String {
        var parts: [String] = []
        var length = 0
        for block in parse(String(text.prefix(2500))) {
            let piece: String
            switch block {
            case .heading(_, let t), .bullet(let t, _), .numbered(_, let t, _), .check(_, let t, _, _), .paragraph(let t), .quote(let t): piece = stripInline(t)
            case .code(_, let t): piece = t
            case .table(let header, _, _): piece = header.map(stripInline).joined(separator: ", ")
            case .rule: piece = ""
            }
            let flat = piece.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            guard !flat.isEmpty else { continue }
            parts.append(flat); length += flat.count
            if length > limit { break }
        }
        let joined = parts.joined(separator: " · ")
        return joined.count > limit ? String(joined.prefix(limit)) + "…" : joined
    }

    static func wordCount(_ text: String) -> Int {
        text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }

    // MARK: Editing helpers (used by the editor; pure so they can be tested)

    /// When Return is pressed at the end of a list line, the prefix to continue with — or `nil` to end the list
    /// (when the current item is empty).
    static func listContinuation(for line: String) -> (prefix: String, isEmptyItem: Bool)? {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let body = line.dropFirst(indent.count)
        if let check = check(String(body)) { return (indent + "- [ ] ", check.text.isEmpty) }
        for marker in ["- ", "* ", "+ "] where body.hasPrefix(marker) {
            return (indent + marker, body.dropFirst(2).trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if body == "-" || body == "*" { return (indent + "\(body) ", true) }
        if let numbered = numbered(String(body)), let n = Int(numbered.number) {
            return (indent + "\(n + 1). ", numbered.text.isEmpty)
        }
        if body.hasPrefix("> ") { return (indent + "> ", body.dropFirst(2).trimmingCharacters(in: .whitespaces).isEmpty) }
        return nil
    }

    /// Adds or removes a line prefix (`# `, `- `, `> ` …) for each line in a block of text.
    static func togglePrefix(_ prefix: String, in block: String) -> String {
        let all = block.components(separatedBy: "\n")
        let content = all.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allHave = !content.isEmpty && content.allSatisfy { $0.hasPrefix(prefix) }
        let headingPrefixes = ["# ", "## ", "### "]
        return all.map { line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty && all.count > 1 { return line }
            if allHave { return String(line.dropFirst(prefix.count)) }
            var stripped = line
            // Switching heading level or list type replaces the old marker rather than stacking.
            if headingPrefixes.contains(prefix) {
                for old in ["### ", "## ", "# "] where stripped.hasPrefix(old) { stripped = String(stripped.dropFirst(old.count)); break }
            } else {
                for old in ["- [ ] ", "- [x] ", "- ", "* ", "> "] where stripped.hasPrefix(old) && old != prefix { stripped = String(stripped.dropFirst(old.count)); break }
                if prefix == "1. ", let n = numbered(stripped) { stripped = n.text }
            }
            return prefix + stripped
        }.joined(separator: "\n")
    }
}
