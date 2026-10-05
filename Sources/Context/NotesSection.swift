import SwiftUI
import UniformTypeIdentifiers

struct NotesSection: View {
    @EnvironmentObject var store: Store
    @Environment(\.pageTint) var tint
    let project: Project
    @State private var filter = ""
    @State private var kind: EntryKind?

    var all: [Entry] { store.workspace.entries.filter { $0.projectID == project.id && EntryKind.noteKinds.contains($0.kind) } }
    var notes: [Entry] {
        all.filter { kind == nil || $0.kind == kind }
            .filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) || $0.body.localizedCaseInsensitiveContains(filter) }
            .sorted { ($0.pinned ? 0 : 1, $1.updatedAt) < ($1.pinned ? 0 : 1, $0.updatedAt) }
    }
    var selection: UUID? {
        if let id = store.selectedNote[project.id], all.contains(where: { $0.id == id }) { return id }
        return nil
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn.frame(width: 300)
            Rectangle().fill(Theme.border).frame(width: 1)
            if let id = selection {
                NoteDocument(noteID: id).id(id)
            } else {
                EmptyState(icon: "note.text", title: all.isEmpty ? "Write your first note" : "Select a note",
                           message: all.isEmpty ? "Paste or write Markdown. Tables, code blocks, and checklists render properly, and long notes get an outline." : "Everything saves automatically as you type.",
                           actionTitle: all.isEmpty ? "New Note" : nil) { newNote(.note) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { store.selectedNote[project.id] = notes.first?.id } }
    }

    var listColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                    TextField("Search notes", text: $filter).textFieldStyle(.plain).font(T.small)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
                Menu {
                    Button { newNote(.note) } label: { Label("New Note", systemImage: "note.text") }
                    Button { newNote(.prompt) } label: { Label("New Prompt", systemImage: "text.bubble") }
                } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 32, height: 30).background(tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                } primaryAction: { newNote(kind ?? .note) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("New note (⌥⌘N). Hold for a prompt.")
            }
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 10)

            if all.contains(where: { $0.kind == .prompt }) {
                Segmented(options: [(nil, "All", nil), (Optional(EntryKind.note), "Notes", nil), (Optional(EntryKind.prompt), "Prompts", nil)], selection: $kind)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 10)
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(notes) { note in
                        NoteListCard(note: note, selected: note.id == selection)
                            .onTapGesture { store.selectedNote[project.id] = note.id }
                    }
                    if notes.isEmpty && !all.isEmpty {
                        Text("No notes match “\(filter)”").font(T.small).foregroundStyle(Theme.ink2).padding(.top, 20)
                    }
                }.padding(.horizontal, 8).padding(.bottom, 12)
            }
        }
        .background(Theme.sidebar.opacity(0.55))
    }

    func newNote(_ kind: EntryKind) {
        let note = Entry(projectID: project.id, kind: kind, title: "")
        if store.save(note) { filter = ""; if self.kind != nil { self.kind = kind }; store.selectedNote[project.id] = note.id }
    }
}

struct NoteListCard: View {
    @EnvironmentObject var store: Store
    @Environment(\.pageTint) var tint
    let note: Entry
    let selected: Bool
    @State private var hovering = false
    @State private var confirmDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2).fill(selected ? tint : .clear).frame(width: 3).padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    if note.kind == .prompt { Image(systemName: "text.bubble.fill").font(.system(size: 10)).foregroundStyle(tint) }
                    Text(note.title.isEmpty ? "Untitled" : note.title).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(note.title.isEmpty ? Theme.ink3 : Theme.ink).lineLimit(1)
                    Spacer(minLength: 0)
                    if note.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.ink3) }
                }
                Text(Markdown.plain(note.body, limit: 140).ifEmpty("No content yet")).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Text("\(DueText.ago(note.updatedAt, now: store.clock).capitalizedFirst) · \(Markdown.wordCount(note.body)) words")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
            }
            .padding(.leading, 9).padding(.trailing, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(selected ? Theme.card : (hovering ? Theme.hover : .clear), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Theme.border : .clear))
        .shadow(color: .black.opacity(selected ? 0.05 : 0), radius: 4, y: 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(note.pinned ? "Unpin" : "Pin to Top") { store.togglePin(note) }
            Button("Copy Text") { copyToClipboard(note.body) }
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Delete “\(note.title.isEmpty ? "Untitled" : note.title)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.deleteEntry(note.id) }
        } message: { Text("This can only be undone by restoring a backup.") }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// One note: a clean reading view by default, and an editor with a formatting bar when editing.
struct NoteDocument: View {
    @EnvironmentObject var store: Store
    @Environment(\.pageTint) var tint
    let noteID: UUID
    @State private var draft: Entry?
    @State private var editing: Bool

    init(noteID: UUID, startEditing: Bool = false) {
        self.noteID = noteID
        _editing = State(initialValue: startEditing)
    }
    @State private var saveTask: Task<Void, Never>?
    @State private var saved = true
    @State private var confirmDelete = false
    @State private var copied = false
    @State private var jump: Int?
    @StateObject private var controller = EditorController()
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let binding = Binding($draft) {
                let note = binding.wrappedValue
                let blocks = editing ? [] : Markdown.parse(note.body)
                topBar(binding, outline: Markdown.outline(blocks))
                Rectangle().fill(Theme.border).frame(height: 1)
                if editing { editor(binding) } else { reader(binding, blocks: blocks) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .onAppear {
            draft = store.entry(noteID)
            if let draft, draft.body.isEmpty { editing = true; if draft.title.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { titleFocused = true } } }
        }
        .onChange(of: draft) { old, new in if old != nil && new != old { saved = false; scheduleSave() } }
        .onDisappear {
            commit()
            // A note left completely empty (e.g. ⌘N then moving on) removes itself instead of cluttering the list.
            if let note = store.entry(noteID), note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, note.relatedIDs.isEmpty {
                store.deleteEntry(noteID)
            }
        }
        .confirmationDialog("Delete “\(draft?.title.ifEmpty("Untitled") ?? "this note")”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { saveTask?.cancel(); draft = nil; store.deleteEntry(noteID) }
        } message: { Text("This can only be undone by restoring a backup.") }
    }

    // MARK: Top bar

    func topBar(_ note: Binding<Entry>, outline: [(index: Int, level: Int, title: String)]) -> some View {
        let value = note.wrappedValue
        let words = Markdown.wordCount(value.body)
        return HStack(spacing: 8) {
            Text(value.kind == .prompt ? "PROMPT" : "NOTE").font(T.label).tracking(1.1).foregroundStyle(tint)
            Text("\(words) words\(words > 250 ? " · \(max(1, words / 220)) min read" : "") · \(saved ? "saved" : "saving…")")
                .font(T.caption).foregroundStyle(Theme.ink3).lineLimit(1)
            Spacer(minLength: 8)
            if !editing && outline.count >= 2 {
                Menu {
                    ForEach(outline, id: \.index) { item in
                        Button(String(repeating: "    ", count: item.level - 1) + item.title) { jump = item.index }
                    }
                } label: { Label("Outline", systemImage: "list.bullet.indent") }
                    .menuStyle(.borderlessButton).fixedSize().help("Jump to a heading")
            }
            if value.kind == .prompt {
                Button { copy(value.body) } label: { Label(copied ? "Copied" : "Copy prompt", systemImage: copied ? "checkmark" : "doc.on.doc") }.buttonStyle(.softCompact)
            }
            IconButton(icon: value.pinned ? "pin.fill" : "pin", help: value.pinned ? "Unpin" : "Pin to top of the list", tint: value.pinned ? tint : Theme.ink2) { note.wrappedValue.pinned.toggle() }
            Menu {
                Button("Copy as Markdown") { copy(value.body) }
                Button("Export as .md File…") { export(value) }
                Divider()
                Button("Delete Note…", role: .destructive) { confirmDelete = true }
            } label: { Image(systemName: "ellipsis").foregroundStyle(Theme.ink2).frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Button { toggleEditing() } label: { Label(editing ? "Done" : "Edit", systemImage: editing ? "checkmark" : "pencil") }
                .buttonStyle(editing ? AnyButtonStyle(.primaryCompact) : AnyButtonStyle(.softCompact))
                .keyboardShortcut("e")
                .help(editing ? "Finish editing (⌘E)" : "Edit this note (⌘E)")
        }
        .padding(.horizontal, 28).padding(.vertical, 10)
    }

    func toggleEditing() {
        if editing { commit() }
        editing.toggle()
        if editing { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { controller.focus() } }
    }

    // MARK: Reading

    func reader(_ note: Binding<Entry>, blocks: [MDBlock]) -> some View {
        let value = note.wrappedValue
        let outline = Markdown.outline(blocks)
        return GeometryReader { geo in
            let showRail = geo.size.width > 900 && outline.count >= 3
            HStack(alignment: .top, spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(value.title.isEmpty ? "Untitled" : value.title)
                                .font(T.display(32)).foregroundStyle(value.title.isEmpty ? Theme.ink3 : Theme.ink)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            Text("Edited \(DueText.ago(store.entry(noteID)?.updatedAt ?? value.updatedAt, now: store.clock)) · created \(value.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(T.small).foregroundStyle(Theme.ink3).padding(.top, 6)
                            if !value.details.isEmpty {
                                Label(value.details, systemImage: "info.circle").font(T.small).foregroundStyle(Theme.ink2)
                                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous)).padding(.top, 14)
                            }
                            if !value.relatedIDs.isEmpty { RelatedChips(ids: value.relatedIDs).padding(.top, 12) }
                            if blocks.isEmpty {
                                Button { toggleEditing() } label: {
                                    Text("This note is empty. Click to start writing.").font(T.body).foregroundStyle(Theme.ink3)
                                }.buttonStyle(.plain).padding(.top, 24)
                            } else {
                                MarkdownDocumentView(blocks: blocks, baseSize: 15) { line in
                                    note.wrappedValue.body = Markdown.toggleCheck(in: note.wrappedValue.body, line: line)
                                }.padding(.top, 22)
                            }
                        }
                        .padding(.horizontal, 44).padding(.top, 34).padding(.bottom, 60)
                        .frame(maxWidth: 840, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: showRail ? .leading : .center)
                    }
                    .onChange(of: jump) { _, target in
                        if let target { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target, anchor: .top) }; jump = nil }
                    }
                }
                if showRail {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            Eyebrow(text: "On this page").padding(.bottom, 8)
                            ForEach(outline, id: \.index) { item in
                                Button { jump = item.index } label: {
                                    Text(item.title).font(.system(size: item.level == 1 ? 13 : 12.5, weight: item.level == 1 ? .semibold : .regular))
                                        .foregroundStyle(item.level == 1 ? Theme.ink : Theme.ink2).lineLimit(2).multilineTextAlignment(.leading)
                                        .padding(.leading, CGFloat(item.level - 1) * 11).padding(.vertical, 4)
                                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }.padding(.top, 40).padding(.trailing, 24)
                    }.frame(width: 220)
                }
            }
        }
    }

    // MARK: Editing

    func editor(_ note: Binding<Entry>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            formatBar
            Rectangle().fill(Theme.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                TextField("Title", text: note.title, axis: .vertical)
                    .font(T.display(30)).textFieldStyle(.plain).focused($titleFocused)
                    .onSubmit { controller.focus() }
                if note.wrappedValue.kind == .prompt {
                    TextField("Usage notes — when to use it, which model, what to paste in", text: note.details, axis: .vertical)
                        .textFieldStyle(.plain).font(T.small).foregroundStyle(Theme.ink2).lineLimit(1...3)
                        .padding(10).background(Theme.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                HStack { RecordLinker(projectID: note.wrappedValue.projectID, excluding: noteID, selection: note.relatedIDs); Spacer() }
                    .font(T.small)
            }
            .padding(.horizontal, 44).padding(.top, 26).padding(.bottom, 4)
            .frame(maxWidth: 900, alignment: .leading)
            MarkdownEditor(text: note.body, controller: controller, monospaced: note.wrappedValue.kind == .prompt, size: 15, tint: tint)
                .padding(.leading, 40).padding(.trailing, 20)
                .frame(maxWidth: 900, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Group {
                Button("") { controller.wrap("**") }.keyboardShortcut("b")
                Button("") { controller.wrap("*") }.keyboardShortcut("i")
            }.opacity(0).allowsHitTesting(false)
        }
    }

    var formatBar: some View {
        HStack(spacing: 2) {
            formatText("H1", "Heading 1") { controller.togglePrefix("# ") }
            formatText("H2", "Heading 2") { controller.togglePrefix("## ") }
            formatText("H3", "Heading 3") { controller.togglePrefix("### ") }
            separator
            IconButton(icon: "bold", help: "Bold (⌘B)") { controller.wrap("**") }
            IconButton(icon: "italic", help: "Italic (⌘I)") { controller.wrap("*") }
            IconButton(icon: "chevron.left.forwardslash.chevron.right", help: "Inline code") { controller.wrap("`") }
            separator
            IconButton(icon: "list.bullet", help: "Bulleted list") { controller.togglePrefix("- ") }
            IconButton(icon: "list.number", help: "Numbered list") { controller.togglePrefix("1. ") }
            IconButton(icon: "checklist", help: "Checklist") { controller.togglePrefix("- [ ] ") }
            IconButton(icon: "text.quote", help: "Quote") { controller.togglePrefix("> ") }
            separator
            IconButton(icon: "link", help: "Link") { controller.insertLink() }
            IconButton(icon: "tablecells", help: "Table") { controller.insertTable() }
            IconButton(icon: "curlybraces", help: "Code block") { controller.insertCodeBlock() }
            Spacer()
            Text("Markdown · ⌘F to find").font(T.caption).foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 24).padding(.vertical, 6)
    }

    var separator: some View { Rectangle().fill(Theme.border).frame(width: 1, height: 16).padding(.horizontal, 5) }

    func formatText(_ label: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink2).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).help(help)
    }

    // MARK: Saving

    func copy(_ text: String) {
        copyToClipboard(text); copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }

    func export(_ note: Entry) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = (note.title.isEmpty ? "Untitled" : note.title).replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ("# \(note.title)\n\n" + note.body).write(to: url, atomically: true, encoding: .utf8) }
        catch { store.error = error.localizedDescription }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    func commit() {
        saveTask?.cancel()
        guard var updated = draft, let current = store.entry(noteID) else { saved = true; return }
        updated.updatedAt = current.updatedAt
        updated.lastOpenedAt = current.lastOpenedAt
        updated.openCount = current.openCount
        guard updated != current else { saved = true; return }
        if store.save(updated) { saved = true }
    }
}

/// Lets a view choose between two button styles at runtime.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
