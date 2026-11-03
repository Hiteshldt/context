import Foundation
import EventKit

/// One reminder from Apple Reminders, copied into a plain value for display.
struct ReminderItem: Identifiable, Equatable {
    let id: String
    var listID: String
    var title: String
    var notes = ""
    var due: Date?
    var hasTime = false
    var repeats: RepeatOption = .never
    var isCompleted = false
    var completedAt: Date?
    var createdAt: Date?
    /// The map box the reminder belongs to, if any.
    var boxID: UUID?

    init(id: String = UUID().uuidString, listID: String, title: String, notes: String = "", due: Date? = nil, hasTime: Bool = false,
         repeats: RepeatOption = .never, isCompleted: Bool = false, completedAt: Date? = nil, createdAt: Date? = nil, boxID: UUID? = nil) {
        self.id = id; self.listID = listID; self.title = title; self.notes = notes; self.due = due; self.hasTime = hasTime
        self.repeats = repeats; self.isCompleted = isCompleted; self.completedAt = completedAt; self.createdAt = createdAt
        self.boxID = boxID
    }

    init(_ reminder: EKReminder) {
        let parts = reminder.dueDateComponents
        self.init(id: reminder.calendarItemIdentifier, listID: reminder.calendar?.calendarIdentifier ?? "",
                  title: reminder.title ?? "", notes: reminder.notes ?? "",
                  due: parts.flatMap { ($0.calendar ?? .current).date(from: $0) }, hasTime: parts?.hour != nil,
                  repeats: RepeatOption(rules: reminder.recurrenceRules), isCompleted: reminder.isCompleted,
                  completedAt: reminder.completionDate, createdAt: reminder.creationDate, boxID: Self.boxID(from: reminder.url))
    }

    /// A reminder made on a map box keeps a link back to it in Apple Reminders (its URL), so it shows on that box
    /// wherever it syncs, and clicking the link in Apple Reminders opens the box in Context.
    static func boxURL(_ id: UUID) -> URL { URL(string: "context://box/\(id.uuidString)")! }

    static func boxID(from url: URL?) -> UUID? {
        guard let url, url.scheme?.lowercased() == "context", url.host()?.lowercased() == "box" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    func isOverdue(now: Date = Date()) -> Bool {
        guard !isCompleted, let due else { return false }
        return hasTime ? due < now : due < Calendar.current.startOfDay(for: now)
    }

    /// Overdue or due today.
    func needsAttention(now: Date = Date()) -> Bool {
        guard !isCompleted, let due else { return false }
        return due < Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
    }

    /// Dated reminders first, soonest first; then undated ones, oldest first.
    static func order(_ a: ReminderItem, _ b: ReminderItem) -> Bool {
        switch (a.due, b.due) {
        case let (x?, y?): return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return (a.createdAt ?? .distantPast) < (b.createdAt ?? .distantPast)
        }
    }
}

struct ReminderList: Identifiable, Equatable {
    let id: String
    let title: String
}

/// How often a reminder repeats, matching the choices in Apple Reminders.
enum RepeatOption: String, CaseIterable, Identifiable {
    case never = "Never", daily = "Every Day", weekdays = "Every Weekday", weekly = "Every Week"
    case monthly = "Every Month", yearly = "Every Year", custom = "Custom"
    var id: String { rawValue }
    /// What the picker offers. `custom` describes a rule made in Apple Reminders that Context leaves untouched.
    static let choices: [RepeatOption] = [.never, .daily, .weekdays, .weekly, .monthly, .yearly]

    init(rules: [EKRecurrenceRule]?) {
        guard let rules, let rule = rules.first else { self = .never; return }
        guard rules.count == 1, rule.interval == 1, rule.recurrenceEnd == nil,
              rule.daysOfTheMonth == nil, rule.monthsOfTheYear == nil, rule.setPositions == nil else { self = .custom; return }
        let days = Set((rule.daysOfTheWeek ?? []).map { $0.dayOfTheWeek.rawValue })
        switch rule.frequency {
        case .daily: self = days.isEmpty ? .daily : .custom
        case .weekly: self = days.isEmpty || days.count == 1 ? .weekly : (days == Set(2...6) ? .weekdays : .custom)
        case .monthly: self = days.isEmpty ? .monthly : .custom
        case .yearly: self = days.isEmpty ? .yearly : .custom
        @unknown default: self = .custom
        }
    }

    /// The rule to save. `never` and `custom` have none (a custom rule is only ever kept, never written).
    var rule: EKRecurrenceRule? {
        switch self {
        case .never, .custom: return nil
        case .daily: return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case .weekly: return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        case .monthly: return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case .yearly: return EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        case .weekdays:
            let days = [EKWeekday.monday, .tuesday, .wednesday, .thursday, .friday].map { EKRecurrenceDayOfWeek($0) }
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, daysOfTheWeek: days, daysOfTheMonth: nil,
                                    monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil)
        }
    }

    /// The closest Apple Reminders rule for a task from an earlier version of Context.
    static func rule(for legacy: RepeatRule) -> EKRecurrenceRule? {
        switch legacy.kind {
        case .none, .afterCompletion: return nil
        case .daily: return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case .everyNDays: return EKRecurrenceRule(recurrenceWith: .daily, interval: max(1, legacy.interval), end: nil)
        case .weekly:
            let days = legacy.weekdays.compactMap(EKWeekday.init(rawValue:)).map { EKRecurrenceDayOfWeek($0) }
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: max(1, legacy.interval), daysOfTheWeek: days.isEmpty ? nil : days,
                                    daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil)
        }
    }
}

/// A reminder typed in one line, e.g. "Renew domain next friday" or "Call Riya tomorrow 5pm".
struct QuickReminder: Equatable {
    var title: String
    var due: Date?
    var hasTime = false
}

enum QuickReminderParser {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    private static let timeWords = try! NSRegularExpression(
        pattern: #"\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)|\d{1,2}:\d{2}|\b(noon|midnight|morning|afternoon|evening|tonight)\b"#,
        options: [.caseInsensitive])
    private static let connector = try! NSRegularExpression(pattern: #"\s+(on|at|by|due|for)\s*$"#, options: [.caseInsensitive])

    /// Pulls a date out of the text. The date words are removed from the title; the title is never left empty.
    static func parse(_ text: String) -> QuickReminder {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = detector?.firstMatch(in: trimmed, options: [], range: full), let date = match.date,
              let range = Range(match.range, in: trimmed) else { return QuickReminder(title: trimmed) }
        let phrase = String(trimmed[range])
        var rest = trimmed.replacingCharacters(in: range, with: " ")
        rest = rest.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let restRange = NSRange(rest.startIndex..., in: rest)
        rest = connector.stringByReplacingMatches(in: rest, range: restRange, withTemplate: "")
        rest = rest.trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: ",.-–—")))
        guard !rest.isEmpty else { return QuickReminder(title: trimmed) }
        let hasTime = timeWords.firstMatch(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)) != nil
        return QuickReminder(title: rest, due: hasTime ? date : Calendar.current.startOfDay(for: date), hasTime: hasTime)
    }
}

extension DateComponents {
    /// The due-date components Apple Reminders expects: a floating day, or a day and time in the current timezone.
    static func reminderDue(_ date: Date, hasTime: Bool, calendar: Calendar = .current) -> DateComponents {
        var parts = calendar.dateComponents(hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: date)
        parts.calendar = calendar
        if hasTime { parts.timeZone = calendar.timeZone }
        return parts
    }
}
