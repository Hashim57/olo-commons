import Foundation

/// Olo is a tool to improve lives, not to replace the people in them. The app keeps a rough count
/// of the minutes spent with it today and, at a few thresholds, says so once: a walk, a call, a
/// start-up community meetup or building with your team will do more than one more prompt. No
/// limit is enforced here; the plans' hour limits live on the server.
public enum Wellbeing {
    /// A gap between two asks longer than this is not counted as time with Olo.
    public static let sessionGapMinutes = 10

    /// Minutes to add when an ask happens `gap` minutes after the previous one.
    public static func minutesToAdd(gapMinutes: Double) -> Double {
        gapMinutes >= 0 && gapMinutes <= Double(sessionGapMinutes) ? gapMinutes : 1
    }

    /// The note for a day's total, or nil below the first threshold or when that threshold was already noted.
    public static func note(minutesToday: Double, lastNotedMinutes: Double) -> String? {
        let thresholds: [(Double, String)] = [
            (120, "Two hours with Olo today. A break, a walk or a conversation will do more now than another prompt. Olo is a tool to improve your life, not to replace the people in it."),
            (300, "Five hours with Olo today. The best start-ups are built by teams: share what you have made with a co-founder, a mentor or a start-up community, and come back with their questions."),
            (600, "Ten hours with Olo today. That is where Olo's daily hours end on every plan, by design. Rest, and let the people around you into the work."),
        ]
        for (limit, text) in thresholds.reversed() where minutesToday >= limit && lastNotedMinutes < limit {
            return text
        }
        return nil
    }
}
