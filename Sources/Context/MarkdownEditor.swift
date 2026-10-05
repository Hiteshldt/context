import SwiftUI
import AppKit

/// Formatting commands for the editor's toolbar and keyboard shortcuts.
@MainActor
final class EditorController: ObservableObject {
    weak var textView: NSTextView?

    func focus() { if let textView { textView.window?.makeFirstResponder(textView) } }

    /// Wraps the selection in a marker such as `**`, or removes it if already wrapped.
    func wrap(_ marker: String) {
        guard let textView else { return }
        let range = textView.selectedRange()
        let ns = textView.string as NSString
        let selected = ns.substring(with: range)
        let length = (marker as NSString).length
        if range.length == 0 {
            textView.insertText(marker + marker, replacementRange: range)
            textView.setSelectedRange(NSRange(location: range.location + length, length: 0))
        } else if selected.hasPrefix(marker), selected.hasSuffix(marker), range.length >= length * 2 {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            textView.insertText(inner, replacementRange: range)
            textView.setSelectedRange(NSRange(location: range.location, length: (inner as NSString).length))
        } else {
            textView.insertText(marker + selected + marker, replacementRange: range)
            textView.setSelectedRange(NSRange(location: range.location + length, length: range.length))
        }
        focus()
    }

    /// Toggles a line prefix (`# `, `- `, `> ` …) on every selected line.
    func togglePrefix(_ prefix: String) {
        guard let textView else { return }
        let ns = textView.string as NSString
        var lines = ns.lineRange(for: textView.selectedRange())
        var block = ns.substring(with: lines)
        if block.hasSuffix("\n") { block.removeLast(); lines.length -= 1 }
        let replaced = Markdown.togglePrefix(prefix, in: block)
        textView.insertText(replaced, replacementRange: lines)
        textView.setSelectedRange(NSRange(location: lines.location + (replaced as NSString).length, length: 0))
        focus()
    }

    func insert(_ text: String, cursorOffset: Int? = nil) {
        guard let textView else { return }
        let range = textView.selectedRange()
        let ns = textView.string as NSString
        // Block inserts start on their own line.
        let needsBreak = text.hasPrefix("\n") == false && text.contains("\n") && range.location > 0 && ns.character(at: range.location - 1) != 10
        let inserted = (needsBreak ? "\n" : "") + text
        textView.insertText(inserted, replacementRange: range)
        if let cursorOffset { textView.setSelectedRange(NSRange(location: range.location + (needsBreak ? 1 : 0) + cursorOffset, length: 0)) }
        focus()
    }

    func insertLink() {
        guard let textView else { return }
        let range = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: range)
        let label = selected.isEmpty ? "link text" : selected
        textView.insertText("[\(label)](https://)", replacementRange: range)
        textView.setSelectedRange(NSRange(location: range.location + (label as NSString).length + 3, length: 8))
        focus()
    }

    func insertTable() { insert("| Column | Column |\n| --- | --- |\n| Value | Value |\n", cursorOffset: 2) }
    func insertCodeBlock() { insert("```\n\n```\n", cursorOffset: 4) }
}

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let controller: EditorController
    var monospaced = false
    var size: CGFloat = 15
    var tint: Color = Theme.accent

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: NSViewRepresentableContext<MarkdownEditor>) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 10)
        textView.textContainer?.lineFragmentPadding = 0
        textView.insertionPointColor = NSColor(tint)
        textView.string = text
        controller.textView = textView
        context.coordinator.restyle(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: NSViewRepresentableContext<MarkdownEditor>) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        if controller.textView !== textView { controller.textView = textView }
        // Only replace the text when it changed outside the editor, so typing never moves the cursor.
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            context.coordinator.restyle(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        init(_ parent: MarkdownEditor) { self.parent = parent }

        func restyle(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            MarkdownHighlighter.apply(to: storage, size: parent.size, monospaced: parent.monospaced, tint: NSColor(parent.tint))
            textView.typingAttributes = [.font: parent.monospaced ? NSFont.monospacedSystemFont(ofSize: parent.size - 1, weight: .regular) : NSFont.systemFont(ofSize: parent.size),
                                         .foregroundColor: NSColor.labelColor]
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            restyle(textView)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let ns = textView.string as NSString
            let selection = textView.selectedRange()
            let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
            var line = ns.substring(with: lineRange)
            if line.hasSuffix("\n") { line.removeLast() }

            if selector == #selector(NSResponder.insertNewline(_:)) {
                // Continue lists; an empty item ends the list instead.
                guard selection.length == 0, selection.location == lineRange.location + (line as NSString).length,
                      let continuation = Markdown.listContinuation(for: line) else { return false }
                if continuation.isEmptyItem {
                    textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: (line as NSString).length))
                } else {
                    textView.insertText("\n" + continuation.prefix, replacementRange: selection)
                }
                return true
            }
            let isListLine = Markdown.bullet(line.trimmingCharacters(in: .whitespaces)) != nil || Markdown.numbered(line.trimmingCharacters(in: .whitespaces)) != nil
                || Markdown.check(line.trimmingCharacters(in: .whitespaces)) != nil
            if selector == #selector(NSResponder.insertTab(_:)), isListLine {
                textView.insertText("  ", replacementRange: NSRange(location: lineRange.location, length: 0))
                return true
            }
            if selector == #selector(NSResponder.insertBacktab(_:)), isListLine, line.hasPrefix("  ") {
                textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: 2))
                return true
            }
            return false
        }
    }
}
