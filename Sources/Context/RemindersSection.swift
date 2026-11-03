import SwiftUI

/// Every reminder in a project, by the box it's on, opened from the Reminders button at the top of the project.
struct ProjectRemindersPanel: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var reminders = RemindersService.shared
    @Environment(\.pageTint) var tint
    let project: Project
    /// Shows a box on the map.
    let showBox: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "Reminders").padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    switch reminders.access {
                    case .granted: connected
                    case .unknown: ConnectRemindersCard(compact: true)
                    case .denied: ConnectRemindersCard(denied: true, compact: true)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 10)
            }
            if reminders.access == .granted {
                Rectangle().fill(Theme.border).frame(height: 1)
                listFooter.padding(.horizontal, 10).padding(.vertical, 9)
            }
        }
        .frame(width: 390).frame(maxHeight: 540)
    }

    @ViewBuilder var connected: some View {
        let split = reminders.byBox(for: project, in: store.workspace)
        let boxes = store.workspace.diagrams.filter { $0.projectID == project.id }.flatMap(\.nodes)
            .filter { node in split.boxes[node.id]?.contains { !$0.isCompleted } == true }
        let loose = split.loose.filter { !$0.isCompleted }.sorted(by: ReminderItem.order)
        if boxes.isEmpty && loose.isEmpty {
            Text("No reminders yet. Select a box on the map and add one in its details: dates like “tomorrow 5pm” are picked up as you type.")
                .font(T.small).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8).padding(.vertical, 6)
        }
        ForEach(boxes) { node in
            Button { showBox(node.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: node.entryID == nil ? node.kind.icon : "link").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
                    Text(boxTitle(node)).font(T.small.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer()
                    Image(systemName: "scope").font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
                }
                .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Show this box on the map")
            ForEach((split.boxes[node.id] ?? []).filter { !$0.isCompleted }.sorted(by: ReminderItem.order)) { ReminderRow(item: $0) }
        }
        if !loose.isEmpty {
            Text("NOT ON A BOX").font(T.label).tracking(1).foregroundStyle(Theme.ink3).padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 2)
            ForEach(loose) { ReminderRow(item: $0) }
        }
    }

    func boxTitle(_ node: DiagramNode) -> String {
        node.entryID.flatMap { store.entry($0)?.title } ?? node.label.ifEmpty(node.kind.name)
    }

    var listFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "checklist").font(.system(size: 11))
            if let name = reminders.listName(for: project) {
                Text("Synced with Apple Reminders · list")
                Menu(name) {
                    ForEach(reminders.lists) { list in
                        Button { reminders.link(project.id, to: list.id, in: store) } label: {
                            if list.id == project.remindersListID { Label(list.title, systemImage: "checkmark") } else { Text(list.title) }
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().help("Use a different Apple Reminders list for this project")
            } else {
                Text("Your first reminder creates a “\(project.name)” list in Apple Reminders.")
            }
            Spacer()
            Button("Open Reminders") { reminders.openRemindersApp() }.buttonStyle(.plain).foregroundStyle(tint)
        }
        .font(T.caption).foregroundStyle(Theme.ink3)
    }
}

/// A map box's reminders, in its details: what's set on it, ticked off when done, and a line to add one with a note.
struct BoxReminders: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var reminders = RemindersService.shared
    let project: Project
    let boxID: UUID
    @State private var showDone = false

    var body: some View {
        let all = reminders.items(for: project).filter { $0.boxID == boxID }
        let open = all.filter { !$0.isCompleted }.sorted(by: ReminderItem.order)
        let done = all.filter(\.isCompleted).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "Reminders")
            switch reminders.access {
            case .granted:
                VStack(spacing: 0) { ForEach(open) { ReminderRow(item: $0) } }
                ReminderComposer(projectID: project.id, boxID: boxID, compact: true)
                if !done.isEmpty {
                    Button { showDone.toggle() } label: {
                        Text(showDone ? "Hide done" : "Show \(done.count) done").font(T.caption.weight(.medium)).foregroundStyle(Theme.ink2)
                    }.buttonStyle(.plain)
                    if showDone { VStack(spacing: 0) { ForEach(done) { ReminderRow(item: $0) } } }
                }
            case .unknown:
                Text("Set reminders on this box. They're kept in Apple Reminders, so they alert you on your Mac and iPhone.")
                    .font(T.caption).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                Button { Task { if await reminders.connect() { _ = reminders.importLocalTasks(from: store) } } } label: {
                    Label("Connect Apple Reminders", systemImage: "link")
                }.buttonStyle(.softCompact)
            case .denied:
                Text("Context isn't allowed to use Apple Reminders.").font(T.caption).foregroundStyle(Theme.ink2)
                Button("Open System Settings") { reminders.openPrivacySettings() }.buttonStyle(.softCompact)
            }
        }
    }
}

/// Explains the Apple Reminders link and asks for access.
struct ConnectRemindersCard: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var reminders = RemindersService.shared
    @Environment(\.pageTint) var tint
    var denied = false
    var compact = false

    var body: some View {
        Card(padding: compact ? 16 : 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "checklist").font(.system(size: compact ? 15 : 18, weight: .semibold)).foregroundStyle(tint)
                        .frame(width: compact ? 34 : 42, height: compact ? 34 : 42).background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(denied ? "Allow Context to use Apple Reminders" : "Reminders, synced with Apple Reminders").font(compact ? T.h3 : T.h2).foregroundStyle(Theme.ink)
                        Text(denied ? "Access was turned off. Turn Context on in System Settings → Privacy & Security → Reminders, then come back."
                                    : "Each project gets its own list in Apple Reminders, so your reminders show up on your iPhone and notify you everywhere.")
                            .font(T.small).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                let earlier = store.workspace.tasks.filter { !$0.isComplete }.count
                if earlier > 0 && !denied {
                    Text("\(earlier) reminder\(earlier == 1 ? "" : "s") from an earlier version of Context will move into Apple Reminders when you connect.")
                        .font(T.caption).foregroundStyle(Theme.ink2)
                }
                HStack {
                    if denied {
                        Button("Open System Settings") { reminders.openPrivacySettings() }.buttonStyle(.primary)
                    } else {
                        Button { Task { if await reminders.connect() { _ = reminders.importLocalTasks(from: store) } } } label: {
                            Label("Connect Apple Reminders", systemImage: "link")
                        }.buttonStyle(.primary)
                    }
                    Spacer()
                }
            }
        }
    }
}

/// One line to add a reminder. A date typed into the text ("tomorrow 5pm") is recognised as you type.
struct ReminderComposer: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var reminders = RemindersService.shared
    @Environment(\.pageTint) var tint
    let projectID: UUID
    /// The map box new reminders go on.
    var boxID: UUID? = nil
    /// The smaller version for a box's details, with a field for a note once something is typed.
    var compact = false
    @State private var text = ""
    @State private var note = ""
    @State private var pickedDue: Date?
    @State private var pickedHasTime = false
    @State private var choosing = false
    @FocusState private var focused: Bool

    var parsed: QuickReminder { QuickReminderParser.parse(text) }
    var due: (date: Date, hasTime: Bool)? {
        if let pickedDue { return (pickedDue, pickedHasTime) }
        return parsed.due.map { ($0, parsed.hasTime) }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: compact ? 7 : 10) {
                Image(systemName: "plus.circle.fill").font(.system(size: compact ? 15 : 17)).foregroundStyle(tint)
                TextField(compact ? "Add a reminder…" : "Add a reminder, e.g. “Renew domain next friday”", text: $text)
                    .textFieldStyle(.plain).font(compact ? T.small : T.body).focused($focused).onSubmit(add)
                if let due {
                    let label = DueText.describe(due.date, hasTime: due.hasTime, now: store.clock)
                    Text(label.text).font(.system(size: compact ? 11 : 12, weight: .semibold)).foregroundStyle(label.color).lineLimit(1)
                        .padding(.horizontal, compact ? 6 : 8).padding(.vertical, 3).background(label.color.opacity(0.12), in: Capsule())
                        .help(pickedDue == nil ? "Recognised from what you typed" : "Chosen date")
                }
                IconButton(icon: "calendar", help: "Choose a date", size: compact ? 26 : 29, tint: pickedDue == nil ? Theme.ink2 : tint) { choosing = true }
                    .popover(isPresented: $choosing, arrowEdge: .bottom) {
                        DueChooser(due: $pickedDue, hasTime: $pickedHasTime, close: { choosing = false })
                    }
            }
            if compact && !text.trimmingCharacters(in: .whitespaces).isEmpty {
                TextField("Note (optional)", text: $note, axis: .vertical)
                    .textFieldStyle(.plain).font(T.small).foregroundStyle(Theme.ink2).lineLimit(1...4).onSubmit(add)
                    .padding(.leading, 22)
                Button("Add Reminder", action: add).buttonStyle(.primaryCompact)
            }
        }
        .padding(.horizontal, compact ? 10 : 14).padding(.vertical, compact ? 7 : 12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous).strokeBorder(focused ? tint.opacity(0.6) : Theme.border))
    }

    func add() {
        let title = pickedDue == nil ? parsed.title : text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        reminders.add(title, notes: note, due: due?.date, hasTime: due?.hasTime ?? false, to: projectID, box: boxID, in: store)
        text = ""; note = ""; pickedDue = nil; pickedHasTime = false
        focused = true
    }
}

/// Quick choices plus a calendar, with an optional time.
struct DueChooser: View {
    @Binding var due: Date?
    @Binding var hasTime: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                quick("Today", Calendar.current.startOfDay(for: Date()))
                quick("Tomorrow", Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!)
                quick("Next Week", nextMonday)
            }
            DatePicker("", selection: Binding(get: { due ?? Date() }, set: { due = hasTime ? $0 : Calendar.current.startOfDay(for: $0) }),
                       displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden()
            HStack {
                Toggle("Time", isOn: Binding(get: { hasTime }, set: { on in
                    hasTime = on
                    let base = due ?? Calendar.current.startOfDay(for: Date())
                    due = on ? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: base) : Calendar.current.startOfDay(for: base)
                })).toggleStyle(.checkbox)
                if hasTime {
                    DatePicker("", selection: Binding(get: { due ?? Date() }, set: { due = $0 }), displayedComponents: .hourAndMinute).labelsHidden()
                }
                Spacer()
            }
            HStack {
                Button("No Date") { due = nil; hasTime = false; close() }.buttonStyle(.softCompact)
                Spacer()
                Button("Done") { if due == nil { due = Calendar.current.startOfDay(for: Date()) }; close() }.buttonStyle(.primaryCompact).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14).frame(width: 270)
    }

    var nextMonday: Date {
        let calendar = Calendar.current
        return calendar.nextDate(after: Date(), matching: DateComponents(weekday: 2), matchingPolicy: .nextTime).map(calendar.startOfDay(for:)) ?? Date()
    }

    func quick(_ title: String, _ date: Date) -> some View {
        Button(title) {
            if hasTime, let due {
                let time = Calendar.current.dateComponents([.hour, .minute], from: due)
                self.due = Calendar.current.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: date)
            } else { self.due = date }
            close()
        }.buttonStyle(.softCompact)
    }
}

/// A reminder in a list: tick it off, or click it to edit.
struct ReminderRow: View {
    @EnvironmentObject var store: Store
    @Environment(\.navigate) var navigate
    @ObservedObject private var reminders = RemindersService.shared
    let item: ReminderItem
    /// Shown on Home, where reminders from every project are listed together.
    var project: Project? = nil
    @State private var editing = false
    @State private var hovering = false

    var tint: Color { Theme.color(project?.color ?? store.workspace.projects.first { $0.remindersListID == item.listID }?.color ?? "sage") }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            Button { withAnimation(.easeOut(duration: 0.2)) { reminders.setCompleted(item, !item.isCompleted) } } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17)).foregroundStyle(item.isCompleted ? tint : Theme.ink3)
            }
            .buttonStyle(.plain).help(item.isCompleted ? "Mark as not done" : "Mark as done")
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.ifEmpty("Untitled")).font(T.body).foregroundStyle(item.isCompleted ? Theme.ink3 : Theme.ink)
                    .strikethrough(item.isCompleted, color: Theme.ink3).lineLimit(2)
                if !item.notes.isEmpty {
                    Text(item.notes).font(T.caption).foregroundStyle(Theme.ink2).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let project {
                Button { navigate(.project(project.id)) } label: {
                    HStack(spacing: 5) { ProjectIcon(project: project, size: 14); Text(project.name) }
                        .font(T.caption).foregroundStyle(Theme.ink2).lineLimit(1)
                }.buttonStyle(.plain).help("Open \(project.name)")
            }
            if item.repeats != .never { Image(systemName: "repeat").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.ink3).help(item.repeats.rawValue) }
            if let due = item.due, !item.isCompleted {
                let label = DueText.describe(due, hasTime: item.hasTime, now: store.clock)
                Text(label.text).font(.system(size: 12, weight: .medium)).foregroundStyle(label.color).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { editing = true }
        .popover(isPresented: $editing, arrowEdge: .trailing) { ReminderEditor(item: item, close: { editing = false }) }
        .contextMenu {
            Button(item.isCompleted ? "Mark as Not Done" : "Mark as Done") { reminders.setCompleted(item, !item.isCompleted) }
            Button("Edit…") { editing = true }
            Divider()
            Button("Delete", role: .destructive) { reminders.delete(item) }
        }
    }
}

/// Edits one reminder. Changes save when the editor closes.
struct ReminderEditor: View {
    @ObservedObject private var reminders = RemindersService.shared
    @State private var draft: ReminderItem
    let original: ReminderItem
    let close: () -> Void
    @State private var deleted = false

    init(item: ReminderItem, close: @escaping () -> Void) {
        _draft = State(initialValue: item)
        original = item
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $draft.title, axis: .vertical).textFieldStyle(.plain).font(.system(size: 15, weight: .semibold)).lineLimit(1...3)
            TextField("Notes", text: $draft.notes, axis: .vertical).textFieldStyle(.plain).font(T.small).foregroundStyle(Theme.ink2).lineLimit(2...6)
            Rectangle().fill(Theme.border).frame(height: 1)
            Toggle("Date", isOn: Binding(get: { draft.due != nil }, set: { on in
                draft.due = on ? Calendar.current.startOfDay(for: Date()) : nil
                if !on { draft.hasTime = false; draft.repeats = .never }
            }))
            if draft.due != nil {
                DatePicker("Day", selection: Binding(get: { draft.due ?? Date() }, set: { draft.due = $0 }), displayedComponents: .date)
                Toggle("Time", isOn: Binding(get: { draft.hasTime }, set: { on in
                    draft.hasTime = on
                    let base = draft.due ?? Date()
                    draft.due = on ? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: base) : Calendar.current.startOfDay(for: base)
                }))
                if draft.hasTime {
                    DatePicker("At", selection: Binding(get: { draft.due ?? Date() }, set: { draft.due = $0 }), displayedComponents: .hourAndMinute)
                }
                Picker("Repeat", selection: $draft.repeats) {
                    ForEach(draft.repeats == .custom ? RepeatOption.choices + [.custom] : RepeatOption.choices) { Text($0.rawValue).tag($0) }
                }
            }
            HStack {
                Button(role: .destructive) { deleted = true; reminders.delete(original); close() } label: { Label("Delete", systemImage: "trash") }
                    .buttonStyle(.plain).foregroundStyle(Theme.overdue).font(T.small)
                Spacer()
                Button("Done") { close() }.buttonStyle(.primaryCompact).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 300)
        .onDisappear {
            draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !deleted, draft != original, !draft.title.isEmpty { reminders.update(draft) }
        }
    }
}
