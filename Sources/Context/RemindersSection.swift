import SwiftUI

/// A project's reminders, kept in its own list in Apple Reminders.
struct RemindersSection: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var reminders = RemindersService.shared
    @Environment(\.pageTint) var tint
    let project: Project
    @State private var showCompleted = false

    var all: [ReminderItem] { reminders.items(for: project) }
    var open: [ReminderItem] { all.filter { !$0.isCompleted }.sorted(by: ReminderItem.order) }
    var done: [ReminderItem] { all.filter(\.isCompleted).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) } }

    var body: some View {
        Page(maxWidth: 780, spacing: 14) {
            switch reminders.access {
            case .granted: connected
            case .unknown: ConnectRemindersCard()
            case .denied: ConnectRemindersCard(denied: true)
            }
        }
    }

    @ViewBuilder var connected: some View {
        ReminderComposer(projectID: project.id)
        if open.isEmpty {
            Text(all.isEmpty ? "No reminders yet. Type one above and press Return. Dates like “tomorrow 5pm” or “next friday” are picked up as you type."
                             : "All done.")
                .font(T.small).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6).padding(.top, 4)
        } else {
            Card(padding: 6) { VStack(spacing: 0) { ForEach(open) { ReminderRow(item: $0) } } }
        }
        if !done.isEmpty {
            Button { withAnimation(.easeOut(duration: 0.15)) { showCompleted.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: showCompleted ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .bold))
                    Text(showCompleted ? "Hide completed" : "Show \(done.count) completed")
                }.font(T.small.weight(.medium)).foregroundStyle(Theme.ink2).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 6)
            if showCompleted { Card(padding: 6) { VStack(spacing: 0) { ForEach(done) { ReminderRow(item: $0) } } } }
        }
        listFooter
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
        .font(T.caption).foregroundStyle(Theme.ink3).padding(.horizontal, 6).padding(.top, 6)
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
    @State private var text = ""
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
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill").font(.system(size: 17)).foregroundStyle(tint)
            TextField("Add a reminder, e.g. “Renew domain next friday”", text: $text)
                .textFieldStyle(.plain).font(T.body).focused($focused).onSubmit(add)
            if let due {
                let label = DueText.describe(due.date, hasTime: due.hasTime, now: store.clock)
                Text(label.text).font(.system(size: 12, weight: .semibold)).foregroundStyle(label.color)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(label.color.opacity(0.12), in: Capsule())
                    .help(pickedDue == nil ? "Recognised from what you typed" : "Chosen date")
            }
            IconButton(icon: "calendar", help: "Choose a date", size: 29, tint: pickedDue == nil ? Theme.ink2 : tint) { choosing = true }
                .popover(isPresented: $choosing, arrowEdge: .bottom) {
                    DueChooser(due: $pickedDue, hasTime: $pickedHasTime, close: { choosing = false })
                }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? tint.opacity(0.6) : Theme.border))
    }

    func add() {
        let title = pickedDue == nil ? parsed.title : text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        reminders.add(title, due: due?.date, hasTime: due?.hasTime ?? false, to: projectID, in: store)
        text = ""; pickedDue = nil; pickedHasTime = false
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
                Button { store.lastSection[project.id] = .reminders; navigate(.project(project.id)) } label: {
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
