import Foundation

/// One thing in a person's day, as the iPhone app reads it from their calendar. Plain values, so
/// everything Olo works out about a schedule is worked out here, on the device, and can be tested.
public struct PlanEvent: Codable, Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var location: String?

    public init(title: String, start: Date, end: Date, allDay: Bool = false, location: String? = nil) {
        self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.location = location
    }
}

/// A stretch of the working day with nothing in it.
public struct FreeBlock: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
    public init(start: Date, end: Date) { self.start = start; self.end = end }
}

/// What Olo makes of a calendar: today's agenda, what is next, where the gaps are, and the habits
/// it has noticed. Nothing here leaves the phone; `shareText` is the only text that is ever sent,
/// and only when the person presses the button that says so.
public enum DayPlan {
    static func clock(_ date: Date, _ calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX"); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// The events that touch `day`, all-day ones first, then by start time.
    public static func agenda(_ events: [PlanEvent], on day: Date, calendar: Calendar = .current) -> [PlanEvent] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events.filter { $0.start < end && $0.end > start }
            .sorted { a, b in a.allDay != b.allDay ? a.allDay : a.start < b.start }
    }

    /// The timed event happening now, or else the next one to start.
    public static func next(_ events: [PlanEvent], after now: Date) -> PlanEvent? {
        let timed = events.filter { !$0.allDay && $0.end > now }.sorted { $0.start < $1.start }
        return timed.first
    }

    /// Gaps of at least `minMinutes` between `startHour` and `endHour` on `day`, never in the past.
    public static func freeBlocks(_ events: [PlanEvent], on day: Date, from startHour: Int = 9, to endHour: Int = 18,
                                  minMinutes: Int = 30, now: Date? = nil, calendar: Calendar = .current) -> [FreeBlock] {
        let dayStart = calendar.startOfDay(for: day)
        guard var cursor = calendar.date(byAdding: .hour, value: startHour, to: dayStart),
              let close = calendar.date(byAdding: .hour, value: endHour, to: dayStart) else { return [] }
        if let now, now > cursor { cursor = now }
        var blocks: [FreeBlock] = []
        let busy = agenda(events, on: day, calendar: calendar).filter { !$0.allDay }.sorted { $0.start < $1.start }
        for e in busy {
            if e.start > cursor {
                let stop = min(e.start, close)
                if stop.timeIntervalSince(cursor) >= Double(minMinutes * 60) { blocks.append(FreeBlock(start: cursor, end: stop)) }
            }
            if e.end > cursor { cursor = e.end }
            if cursor >= close { break }
        }
        if close.timeIntervalSince(cursor) >= Double(minMinutes * 60) { blocks.append(FreeBlock(start: cursor, end: close)) }
        return blocks
    }

    static func normal(_ title: String) -> String {
        title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Patterns in the last few weeks: things that keep happening on the same weekday, the busiest
    /// weekday, and when the day usually starts. At most five lines, most regular first.
    public static func habits(_ past: [PlanEvent], calendar: Calendar = .current) -> [String] {
        let timed = past.filter { !$0.allDay && !normal($0.title).isEmpty }
        guard !timed.isEmpty else { return [] }
        var lines: [String] = []
        let names = calendar.weekdaySymbols // Sunday first, index weekday - 1

        var groups: [String: [PlanEvent]] = [:]
        for e in timed { groups["\(normal(e.title))|\(calendar.component(.weekday, from: e.start))", default: []].append(e) }
        let regular = groups.filter { $0.value.count >= 3 }.sorted { a, b in a.value.count != b.value.count ? a.value.count > b.value.count : a.key < b.key }
        for (_, list) in regular.prefix(3) {
            guard let first = list.first else { continue }
            let weekday = calendar.component(.weekday, from: first.start)
            let minutes = list.map { calendar.component(.hour, from: $0.start) * 60 + calendar.component(.minute, from: $0.start) }.sorted()
            let typical = minutes[minutes.count / 2]
            lines.append("\(first.title): most \(names[weekday - 1])s around \(String(format: "%02d:%02d", typical / 60, typical % 60)).")
        }

        var perDay: [Int: Int] = [:]
        for e in timed { perDay[calendar.component(.weekday, from: e.start), default: 0] += 1 }
        if let busiest = perDay.max(by: { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }), perDay.count > 1, busiest.value >= 3 {
            lines.append("\(names[busiest.key - 1]) is usually your fullest day.")
        }
        let hour = firstHour(timed, calendar: calendar)
        if let hour { lines.append("Your days usually start around \(String(format: "%02d:00", hour)).") }
        return Array(lines.prefix(5))
    }

    /// The usual hour of the first timed event of a day (the middle value), or nil with fewer than three days to go on.
    static func firstHour(_ timed: [PlanEvent], calendar: Calendar) -> Int? {
        var firstOfDay: [Date: Date] = [:]
        for e in timed {
            let d = calendar.startOfDay(for: e.start)
            if let cur = firstOfDay[d] { if e.start < cur { firstOfDay[d] = e.start } } else { firstOfDay[d] = e.start }
        }
        guard firstOfDay.count >= 3 else { return nil }
        let hours = firstOfDay.values.map { calendar.component(.hour, from: $0) }.sorted()
        return hours[hours.count / 2]
    }

    /// When the morning brief should arrive: an hour before the day usually starts, between 06:00 and 10:00; 08:00 when unknown.
    public static func briefHour(_ past: [PlanEvent], calendar: Calendar = .current) -> Int {
        guard let hour = firstHour(past.filter { !$0.allDay }, calendar: calendar) else { return 8 }
        return max(6, min(10, hour - 1))
    }

    /// The morning brief, in two or three short sentences.
    public static func brief(for day: Date, events: [PlanEvent], calendar: Calendar = .current) -> String {
        let today = agenda(events, on: day, calendar: calendar)
        let timed = today.filter { !$0.allDay }
        guard !today.isEmpty else { return "Nothing in your calendar today. The day is yours." }
        var parts: [String] = []
        parts.append(today.count == 1 ? "One thing in your calendar today." : "\(today.count) things in your calendar today.")
        if let first = timed.first { parts.append("First: \(first.title) at \(clock(first.start, calendar)).") }
        if let gap = freeBlocks(events, on: day, calendar: calendar).max(by: { $0.minutes < $1.minutes }), gap.minutes >= 60 {
            parts.append("Your longest free stretch is \(clock(gap.start, calendar)) to \(clock(gap.end, calendar)).")
        }
        return parts.joined(separator: " ")
    }

    /// Exactly what is sent to Olo when the person chooses to share their day with a question: times and titles, nothing else.
    public static func shareText(day: Date, events: [PlanEvent], calendar: Calendar = .current) -> String {
        let today = agenda(events, on: day, calendar: calendar)
        guard !today.isEmpty else { return "My calendar today is empty." }
        let lines = today.map { e in e.allDay ? "- All day: \(e.title)" : "- \(clock(e.start, calendar)) to \(clock(e.end, calendar)): \(e.title)" }
        return "My calendar today:\n" + lines.joined(separator: "\n")
    }
}
