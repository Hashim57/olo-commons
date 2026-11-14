import Foundation

/// A conservative check for a person writing about harming themselves, in the first
/// person. It trips on phrases like "I want to die" or "kill myself" and stays quiet
/// on "suicide rates in the UK", "kill the process" or "die on this hill". When it
/// trips, the app shows a calm banner with helplines above the answer. It never
/// blocks or changes the answer.
public enum Crisis {
    public struct Helpline: Equatable, Sendable {
        public let name: String
        public let detail: String
    }

    public static let title = "If you are having a hard time right now, you are not alone"

    public static let helplines: [Helpline] = [
        Helpline(name: "Samaritans", detail: "call 116 123, free, any time (UK and Ireland)"),
        Helpline(name: "Shout", detail: "text SHOUT to 85258 (UK)"),
        Helpline(name: "In the EU", detail: "116 123 reaches an emotional support line where the number is in service"),
    ]

    public static let emergency = "If you are in immediate danger call 999 or 112."

    /// First-person phrases about self-harm that are clear wherever they appear. Matched
    /// after the text is lower cased, apostrophes removed and punctuation set apart, so
    /// "I don't" and "I dont" both match.
    static let phrases: [String] = [
        "kill myself", "killing myself",
        "end my life", "ending my life", "end my own life",
        "take my own life", "taking my own life",
        "hurt myself", "harm myself", "harming myself",
        "i self harm", "i self-harm", "been self harming", "been self-harming",
        "i want to be dead", "i wish i was dead", "i wish i were dead",
        "i dont want to be alive", "i do not want to be alive",
        "i dont want to be here anymore", "i dont want to be here any more", "i dont want to wake up",
        "i am suicidal", "im suicidal", "i feel suicidal", "feeling suicidal", "i have been suicidal", "ive been suicidal",
        "no reason to live", "nothing to live for", "better off dead", "want to end it all", "going to end it all",
    ]

    /// Phrases that mean self-harm only when the sentence ends there ("I don't want to
    /// live" yes, "I don't want to live in London" no), or goes on with one of `continuations`.
    static let sentenceEndPhrases: [String] = [
        "i want to die", "i wanna die",
        "i dont want to live", "i do not want to live",
        "i cant go on", "i cannot go on",
        "i cant do this anymore", "i cant do this any more",
    ]

    static let continuations: [String] = ["and", "so", "because", "but", "right now", "today", "tonight", "anymore", "any more", "sometimes", "i"]

    /// Idioms that contain one of the phrases but mean something else.
    static let idioms: [String] = [
        "kill myself laughing", "killing myself laughing", "killed myself laughing",
        "die of embarrassment", "die laughing", "could kill myself for",
    ]

    /// True when the text reads as the writer speaking about harming themselves.
    public static func detect(_ text: String) -> Bool {
        var t = normalise(text)
        guard !t.isEmpty else { return false }
        for idiom in idioms { t = t.replacingOccurrences(of: idiom, with: " ") }
        let padded = " " + t + " "
        for p in phrases where padded.contains(" " + p + " ") { return true }
        for p in sentenceEndPhrases {
            var search = padded.startIndex
            while let r = padded.range(of: " " + p + " ", range: search..<padded.endIndex) {
                let rest = padded[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if rest.isEmpty || rest.hasPrefix(".") || rest.hasPrefix(",") { return true }
                if continuations.contains(where: { rest == $0 || rest.hasPrefix($0 + " ") }) { return true }
                search = padded.index(after: r.lowerBound)
            }
        }
        return false
    }

    /// Lower case, no apostrophes, punctuation as its own token, single spaces.
    static func normalise(_ text: String) -> String {
        var s = text.lowercased()
        for ch in ["\u{2019}", "\u{2018}", "'", "`"] { s = s.replacingOccurrences(of: ch, with: "") }
        var out = ""
        var lastSpace = true
        for c in s {
            if c.isLetter || c.isNumber || c == "-" {
                out.append(c); lastSpace = false
            } else if c == "." || c == "," || c == "!" || c == "?" || c == ";" {
                if !lastSpace { out.append(" ") }
                out.append(c == "," ? "," : ".")
                out.append(" "); lastSpace = true
            } else if !lastSpace {
                out.append(" "); lastSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
