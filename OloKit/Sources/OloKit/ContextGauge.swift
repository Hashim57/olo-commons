import Foundation

/// The context gauge: "about N% of the context used". An estimate, not a count,
/// mirroring client/src/lib/contextGauge.ts: the last few turns the server replays
/// with a new message, four characters to a token, plus a fixed allowance for the
/// system prompt.
public enum ContextGauge {
    /// Tokens the model window holds (the common 128k).
    public static let modelWindowTokens = 128_000
    /// Prior turns replayed per tier, as server/capability.ts has them.
    public static let historyTurns: [String: Int] = ["low": 8, "medium": 20, "high": 40]
    /// A fixed allowance for the system prompt, persona and directives.
    public static let systemAllowanceTokens = 2_000
    public static let charsPerToken = 4
    /// Amber from here.
    public static let warnAt = 0.7
    /// Red from here.
    public static let dangerAt = 0.9

    public enum Level: String, Sendable { case ok, warn, danger }

    public struct Reading: Equatable, Sendable {
        public var tokens: Int
        /// 0 to 1, capped at 1.
        public var fraction: Double
        /// 0 to 100, rounded.
        public var percent: Int
        public var level: Level
        /// "about N% of the context used"
        public var line: String
        /// True from the amber threshold: the thread would benefit from a summary.
        public var suggestSummary: Bool
    }

    public static func estimateTokens(_ text: String) -> Int {
        Int((Double(text.count) / Double(charsPerToken)).rounded(.up))
    }

    /// `turns` are the role and text of every message in the thread, in order.
    public static func reading(turns: [(role: String, text: String)], draft: String, tier: String = "medium",
                               windowTokens: Int = modelWindowTokens, systemTokens: Int = systemAllowanceTokens) -> Reading {
        let keep = historyTurns[tier] ?? 20
        let spoken = turns.filter { $0.role == "user" || $0.role == "assistant" }
        let sent = spoken.suffix(max(0, keep))
        let tokens = systemTokens + sent.reduce(0) { $0 + estimateTokens($1.text) } + estimateTokens(draft)
        let fraction = min(1, windowTokens > 0 ? Double(tokens) / Double(windowTokens) : 1)
        let percent = Int((fraction * 100).rounded())
        let level: Level = fraction >= dangerAt ? .danger : (fraction >= warnAt ? .warn : .ok)
        return Reading(tokens: tokens, fraction: fraction, percent: percent, level: level,
                       line: "about \(percent)% of the context used", suggestSummary: fraction >= warnAt)
    }
}
