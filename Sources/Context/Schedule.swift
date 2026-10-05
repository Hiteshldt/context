import Foundation

/// A task's recurrence. Calendar rules follow the Mac's local timezone and preserve wall-clock time across
/// daylight-saving changes. `afterCompletion` schedules a follow-up relative to when work was actually finished.
struct RepeatRule: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case none = "Does not repeat", daily = "Every day", everyNDays = "Every few days"
        case weekly = "Weekly on selected days", afterCompletion = "Days after completion"
        var id: String { rawValue }
    }

    var kind: Kind = .none
    /// Days for `everyNDays` and `afterCompletion`; weeks for `weekly`.
    var interval = 1
    /// Calendar weekdays (1 = Sunday … 7 = Saturday) for `weekly`. Empty means the due date's weekday.
    var weekdays: [Int] = []
    /// Additional times of day, as minutes from midnight, for calendar rules. The due date's own time is always included.
    var extraTimes: [Int] = []

    var repeats: Bool { kind != .none }

    init(kind: Kind = .none, interval: Int = 1, weekdays: [Int] = [], extraTimes: [Int] = []) {
        self.kind = kind
        self.interval = max(1, interval)
        self.weekdays = weekdays
        self.extraTimes = extraTimes
    }

    /// Converts version-1 recurrence names.
    init(legacy: String, due: Date?, calendar: Calendar = .current) {
        switch legacy {
        case "Every day": self.init(kind: .daily)
        case "Every 3 days": self.init(kind: .everyNDays, interval: 3)
        case "Every week": self.init(kind: .weekly, weekdays: due.map { [calendar.component(.weekday, from: $0)] } ?? [])
        default: self.init()
        }
    }

    func timeSlots(anchor: Date, calendar: Calendar) -> [Int] {
        let parts = calendar.dateComponents([.hour, .minute], from: anchor)
        let base = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return Array(Set([base] + extraTimes.filter { (0..<1440).contains($0) })).sorted()
    }

    func matches(day: Date, anchorDay: Date, anchorWeekday: Int, calendar: Calendar) -> Bool {
        switch kind {
        case .none, .afterCompletion: return false
        case .daily: return true
        case .everyNDays:
            let days = calendar.dateComponents([.day], from: anchorDay, to: day).day ?? 0
            return days >= 0 && days % max(1, interval) == 0
        case .weekly:
            let selected = weekdays.isEmpty ? [anchorWeekday] : weekdays
            guard selected.contains(calendar.component(.weekday, from: day)) else { return false }
            guard interval > 1,
                  let anchorWeek = calendar.dateInterval(of: .weekOfYear, for: anchorDay)?.start,
                  let dayWeek = calendar.dateInterval(of: .weekOfYear, for: day)?.start else { return true }
            let weeks = (calendar.dateComponents([.day], from: anchorWeek, to: dayWeek).day ?? 0) / 7
            return weeks % interval == 0
        }
    }

    /// The first occurrence strictly after `date`, on the cadence defined by `anchor` (the current due occurrence).
    func occurrence(after date: Date, anchor: Date, calendar: Calendar) -> Date? {
        guard kind != .none, kind != .afterCompletion else { return nil }
        let slots = timeSlots(anchor: anchor, calendar: calendar)
        let anchorDay = calendar.startOfDay(for: anchor)
        let anchorWeekday = calendar.component(.weekday, from: anchor)
        var day = calendar.startOfDay(for: max(date, anchor))
        let seconds = calendar.component(.second, from: anchor)
        for _ in 0..<(3700 * max(1, interval)) {
            if matches(day: day, anchorDay: anchorDay, anchorWeekday: anchorWeekday, calendar: calendar) {
                for minutes in slots {
                    if let candidate = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: seconds, of: day),
                       candidate > date {
                        return candidate
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    /// For completion-relative rules: `interval` days after the completion day, at the task's usual time of day.
    func followUp(completedAt: Date, dueTime: Date, calendar: Calendar) -> Date? {
        let time = calendar.dateComponents([.hour, .minute, .second], from: dueTime)
        guard let day = calendar.date(byAdding: .day, value: max(1, interval), to: calendar.startOfDay(for: completedAt)) else { return nil }
        return calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: time.second ?? 0, of: day)
    }

    /// Up to `limit` upcoming occurrences starting at `due` (inclusive), for previews.
    func upcoming(from due: Date, limit: Int, calendar: Calendar = .current) -> [Date] {
        guard kind != .none, kind != .afterCompletion else { return [due] }
        var result = [due]
        var cursor = due
        while result.count < limit, let next = occurrence(after: cursor, anchor: due, calendar: calendar) {
            result.append(next)
            cursor = next
        }
        return result
    }

    func summary(calendar: Calendar = .current) -> String {
        let times = extraTimes.isEmpty ? "" : " · \(extraTimes.count + 1)× a day"
        switch kind {
        case .none: return "Does not repeat"
        case .daily: return "Every day" + times
        case .everyNDays: return (interval == 1 ? "Every day" : "Every \(interval) days") + times
        case .weekly:
            let symbols = calendar.shortWeekdaySymbols
            let names = weekdays.sorted().compactMap { (1...7).contains($0) ? symbols[$0 - 1] : nil }
            let every = interval == 1 ? "Weekly" : "Every \(interval) weeks"
            return (names.isEmpty ? every : "\(every) on \(names.joined(separator: ", "))") + times
        case .afterCompletion: return interval == 1 ? "1 day after completion" : "\(interval) days after completion"
        }
    }
}

extension RepeatRule {
    enum CodingKeys: String, CodingKey { case kind, interval, weekdays, extraTimes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.value(.kind, .none), interval: try c.value(.interval, 1),
                  weekdays: try c.value(.weekdays, []), extraTimes: try c.value(.extraTimes, []))
    }
}
