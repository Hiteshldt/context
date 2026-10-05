import SwiftUI
import AppKit

enum InlineMarkdown {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Inline Markdown (bold, italic, code, links) as styled text. Bare URLs become links too.
    static func attributed(_ text: String, tint: Color = Theme.accent, codeSize: CGFloat = 13) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                                             failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(text)
        for run in result.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                result[run.range].font = .system(size: codeSize, weight: .medium, design: .monospaced)
                result[run.range].backgroundColor = Theme.raised
            }
            if run.link != nil { result[run.range].foregroundColor = tint; result[run.range].underlineStyle = .single }
        }
        let plain = String(result.characters)
        if plain.contains("://"), let detector {
            for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let url = match.url, let range = Range(match.range, in: result), result[range].link == nil else { continue }
                result[range].link = url
                result[range].foregroundColor = tint
            }
        }
        return result
    }
}

/// Renders parsed Markdown blocks as a readable document.
struct MarkdownDocumentView: View {
    @Environment(\.pageTint) var tint
    let blocks: [MDBlock]
    var baseSize: CGFloat = 15
    /// Called with the source line of a checklist item when it is clicked.
    var onToggleCheck: ((Int) -> Void)? = nil

    init(blocks: [MDBlock], baseSize: CGFloat = 15, onToggleCheck: ((Int) -> Void)? = nil) {
        self.blocks = blocks; self.baseSize = baseSize; self.onToggleCheck = onToggleCheck
    }
    init(source: String, baseSize: CGFloat = 15) { self.init(blocks: Markdown.parse(source), baseSize: baseSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block)
                    .padding(.top, index == 0 ? 0 : spacing(before: block, previous: blocks[index - 1]))
                    .id(index)
            }
        }
        .font(.system(size: baseSize))
        .foregroundStyle(Theme.ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func isListItem(_ block: MDBlock) -> Bool {
        switch block { case .bullet, .numbered, .check: return true; default: return false }
    }

    func spacing(before block: MDBlock, previous: MDBlock) -> CGFloat {
        switch block {
        case .heading(let level, _): return level == 1 ? 30 : (level == 2 ? 26 : 20)
        case .bullet, .numbered, .check: return isListItem(previous) ? 6 : 11
        case .table, .code: return 16
        case .rule: return 18
        default:
            if case .heading = previous { return 9 }
            return 12
        }
    }

    func inline(_ text: String) -> AttributedString { InlineMarkdown.attributed(text, tint: tint, codeSize: baseSize - 1.5) }

    @ViewBuilder func view(for block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            VStack(alignment: .leading, spacing: 6) {
                Text(inline(text))
                    .font(level == 1 ? .system(size: baseSize + 9, weight: .bold) : level == 2 ? .system(size: baseSize + 4.5, weight: .bold) : .system(size: baseSize + 1.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if level == 1 { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        case .paragraph(let text):
            Text(inline(text)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
        case .bullet(let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Circle().fill(indent == 0 ? tint : Theme.ink3).frame(width: 5, height: 5).offset(y: -3)
                Text(inline(text)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }.padding(.leading, 4 + CGFloat(indent) * 20)
        case .numbered(let number, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).").font(.system(size: baseSize, weight: .semibold).monospacedDigit()).foregroundStyle(tint)
                    .frame(minWidth: 20, alignment: .trailing)
                Text(inline(text)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }.padding(.leading, CGFloat(indent) * 20)
        case .check(let done, let text, let line, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Button { onToggleCheck?(line) } label: {
                    Image(systemName: done ? "checkmark.square.fill" : "square")
                        .font(.system(size: baseSize + 1)).foregroundStyle(done ? tint : Theme.ink3)
                }
                .buttonStyle(.plain).disabled(onToggleCheck == nil)
                .help(done ? "Mark as not done" : "Mark as done")
                Text(inline(text)).strikethrough(done, color: Theme.ink3).foregroundStyle(done ? Theme.ink3 : Theme.ink)
                    .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }.padding(.leading, 2 + CGFloat(indent) * 20)
        case .quote(let text):
            Text(inline(text)).lineSpacing(5).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 10).padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3).padding(.vertical, 6) }
        case .code(let language, let text):
            MDCodeBlock(language: language, text: text, size: baseSize - 2)
        case .table(let header, let alignments, let rows):
            MDTable(header: header, alignments: alignments, rows: rows, size: baseSize - 1.5, inline: inline)
        case .rule:
            Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 2)
        }
    }
}

struct MDCodeBlock: View {
    let language: String
    let text: String
    var size: CGFloat = 13
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "CODE" : language.uppercased()).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink3)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11.5, weight: .medium))
                }.buttonStyle(.plain).foregroundStyle(copied ? Theme.success : Theme.ink2)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.system(size: size, design: .monospaced)).lineSpacing(3).foregroundStyle(Theme.ink)
                    .padding(12).fixedSize(horizontal: true, vertical: true)
            }
        }
        .background(Theme.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
    }
}

struct MDTable: View {
    let header: [String]
    let alignments: [MDAlign]
    let rows: [[String]]
    var size: CGFloat = 13.5
    let inline: (String) -> AttributedString

    func alignment(_ column: Int) -> Alignment {
        switch alignments.indices.contains(column) ? alignments[column] : .leading {
        case .leading: return .topLeading
        case .center: return .top
        case .trailing: return .topTrailing
        }
    }

    var body: some View {
        let grid = Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(header.indices, id: \.self) { column in
                    Text(inline(header[column])).font(.system(size: size, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(column))
                        .background(Theme.raised)
                }
            }
            ForEach(rows.indices, id: \.self) { row in
                Rectangle().fill(Theme.border).frame(height: 1)
                GridRow {
                    ForEach(header.indices, id: \.self) { column in
                        Text(inline(rows[row].indices.contains(column) ? rows[row][column] : ""))
                            .font(.system(size: size)).lineSpacing(2.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(column))
                            .background(row % 2 == 1 ? Theme.raised.opacity(0.35) : Theme.card)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))

        if header.count > 6 {
            ScrollView(.horizontal) { grid.frame(minWidth: CGFloat(header.count) * 150) }
        } else {
            grid
        }
    }
}
