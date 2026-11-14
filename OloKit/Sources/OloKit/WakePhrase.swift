import Foundation

/// "Hey Olo": the wake phrase, as text.
///
/// The phone's own recogniser turns speech into words on the device; this only decides whether
/// those words contain the wake phrase and what was said after it. Pure, so it is tested.
///
/// Recognisers rarely spell a made-up name the same way twice. "Olo" comes back as "Olo", "Ollo",
/// "Oh low", "O lo" and so on, and "hey" as "hey", "hi", "hello" or "okay". The variants below are
/// the ones that matter in practice; anything looser ("hollow", "solo", "Oslo") would wake Olo
/// during ordinary conversation, which is worse than missing the odd attempt. The same lists as
/// wakePhrase.ts in the earlier iPhone app.
public enum WakePhrase {
    /// Lower case, letters and digits only, single spaces. Apostrophes are dropped, not split.
    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased().decomposedStringWithCanonicalMapping
        var scalars = String.UnicodeScalarView()
        for s in lowered.unicodeScalars where !(0x0300...0x036F).contains(s.value) && s != "'" && s.value != 0x2019 {
            scalars.append(s)
        }
        let spaced = String(scalars).replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        return spaced.trimmingCharacters(in: .whitespaces)
    }

    /// How the recogniser writes the greeting.
    static let greeting = "(?:hey|hay|hei|heh|hi|hiya|hello|hallo|hullo|okay|ok|a)"
    /// How the recogniser writes "Olo". One word or two.
    static let name = "(?:olo|ollo|oloh|olow|oloe|olos|ola|olla|alo|allo|aloe|aloh|oh low|oh lo|oh loh|o low|o lo|oh lowe|oh la|o la|oh law)"
    /// "hello olo" also arrives as "hell olo" or run together once in a while.
    static let runTogether = "(?:hell olo|helolo|heyolo|hiolo|heyola|hailo|hey lo lo)"

    static let wake: NSRegularExpression? = try? NSRegularExpression(pattern: "(?:^| )(?:\(greeting) \(name)|\(runTogether))(?= |$)")

    public struct Match: Equatable, Sendable {
        /// Where the phrase starts and ends, as character offsets in `normalized`.
        public let start: Int
        public let end: Int
        /// The normalised text the match refers to.
        public let normalized: String
        /// The phrase itself.
        public var phrase: String {
            let chars = Array(normalized)
            guard start >= 0, end <= chars.count, start <= end else { return "" }
            return String(chars[start..<end])
        }
    }

    /// The last time the wake phrase occurs in `text`, or nil. The last one, because in continuous
    /// recognition the transcript keeps growing: if someone says "hey Olo" twice, the question is
    /// what follows the second.
    public static func match(_ text: String) -> Match? {
        let normalized = normalize(text)
        guard !normalized.isEmpty, let wake else { return nil }
        // The normalised text is ASCII, so UTF-16 offsets are character offsets.
        let ns = normalized as NSString
        var last: Match?
        for m in wake.matches(in: normalized, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
            let leading = ns.substring(with: m.range).hasPrefix(" ") ? 1 : 0
            last = Match(start: m.range.location + leading, end: m.range.location + m.range.length, normalized: normalized)
        }
        return last
    }

    public static func contains(_ text: String) -> Bool { match(text) != nil }

    /// What was said after the wake phrase, in the recogniser's own words and punctuation, or ""
    /// when nothing yet. Nil when there is no wake phrase. The original text is kept (not the
    /// normalised copy) so the question reaches Olo with its capitals and question mark; the
    /// position is found by counting words, which survives the punctuation the recogniser adds.
    public static func questionAfterWake(_ text: String) -> String? {
        guard let m = match(text) else { return nil }
        let through = String(Array(m.normalized).prefix(m.end))
        let wordsThroughWake = through.split(separator: " ").count
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var seen = 0
        var index = 0
        while index < tokens.count, seen < wordsThroughWake {
            seen += normalize(tokens[index]).split(separator: " ").count
            index += 1
        }
        let rest = tokens[index...].joined(separator: " ")
        return rest.replacingOccurrences(of: "^[\\s,.;:!?\u{2026}-]+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Regions where British English is the closer recogniser when the phone's own English variant has none.
    static let gbRegions: Set<String> = [
        "GB", "IE", "DE", "AT", "CH", "FR", "BE", "NL", "LU", "IT", "ES", "PT", "DK", "SE", "NO", "FI", "IS", "PL", "CZ",
        "SK", "HU", "RO", "BG", "GR", "HR", "SI", "EE", "LV", "LT", "MT", "CY", "AI", "JM", "TT", "BB", "BS", "KY", "VG",
        "BM", "MS", "LC", "GD", "VC", "AG", "KN", "DM", "NG", "GH", "KE", "UG", "TZ", "ZW", "ZM", "HK", "MY", "SG",
    ]
    static let knownEnglish: Set<String> = ["US", "GB", "AU", "CA", "IN", "IE", "NZ", "ZA", "SG", "PH"]

    /// The language Hey Olo listens in. It follows the phone's English when the recogniser has that
    /// variant (en-US, en-GB, en-IN...). An English phone in another region (en-DE: English, Germany)
    /// has no recogniser of its own, so it falls back to British English for Europe, the Caribbean
    /// and the Commonwealth and American English elsewhere. A phone set to another language listens
    /// in English too, because the wake phrase is English. `supported` is the recogniser's own list
    /// when known; the answer is always one of them.
    public static func recognitionLanguage(deviceLocale: String?, supported: [String] = []) -> String {
        let tag = (deviceLocale ?? "").replacingOccurrences(of: "_", with: "-")
        let parts = tag.split(separator: "-").map(String.init)
        let lang = parts.first?.lowercased() ?? ""
        var region = ""
        for (i, part) in parts.enumerated() where i > 0 && part.count == 2 && part.allSatisfy({ $0.isASCII && $0.isLetter }) {
            region = part.uppercased()
            break
        }
        let offered = supported.map { $0.replacingOccurrences(of: "_", with: "-") }
        let have = Set(offered)
        if lang == "en", !region.isEmpty {
            let own = "en-\(region)"
            if have.isEmpty ? knownEnglish.contains(region) : have.contains(own) { return own }
        }
        let preferred = gbRegions.contains(region) ? ["en-GB", "en-US"] : ["en-US", "en-GB"]
        for l in preferred where have.isEmpty || have.contains(l) { return l }
        return offered.first(where: { $0.hasPrefix("en-") }) ?? "en-US"
    }

    /// Drops Olo's own "I'm listening" if the recogniser caught the end of it.
    public static func cleanQuestion(_ text: String) -> String {
        let cue = "^[\\s,.;:!?-]*(?:go ahead[\\s,.;:!?-]*)?(?:(?:i ?a?m|i'm|im|i am)\\s+listening)?[\\s,.;:!?-]*"
        guard let range = text.range(of: cue, options: [.regularExpression, .caseInsensitive]) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Hey Olo, let's talk" opens a whole conversation by voice instead of one answer.
    public static func wantsConversation(_ question: String) -> Bool {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: "^(let'?s|lets) (talk|chat|have a (chat|conversation))\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Ways into Olo's voice that are not the icon: olo://ask?listen=1 opens Quick Ask with the
/// microphone listening; olo://quickask does the same; olo://talk opens Talk to Olo. Other olo://
/// links are LinkPolicy's.
public enum VoiceEntry: Equatable, Sendable {
    case quickAsk
    case talk

    public static func parse(_ url: URL) -> VoiceEntry? {
        guard url.scheme?.lowercased() == "olo" else { return nil }
        let host = url.host?.lowercased() ?? ""
        if host == "talk" { return .talk }
        if host == "quickask" { return .quickAsk }
        if host == "ask" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let question = items.first(where: { $0.name == "q" })?.value ?? ""
            if question.isEmpty, items.first(where: { $0.name == "listen" })?.value == "1" { return .quickAsk }
        }
        return nil
    }
}

/// What Hey Olo has heard so far, kept apart from the microphone so it can be tested.
///
/// Continuous recognition keeps one growing transcript. `offset` marks how much of it has been
/// dealt with; everything after it is searched for the wake phrase, and once the phrase is found
/// the words after it are the question. Ambient talk is skipped by moving the offset forward, not
/// by restarting the session. The timers (a pause before "I'm listening", the silence that ends a
/// question) belong to the caller.
public struct WakeTracker: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case waiting, capturing, acking, afterAck, answering, done }

    public enum Event: Equatable, Sendable {
        /// The wake phrase was heard for the first time in this round.
        case woke
        /// The question so far ("" when nothing has followed the phrase yet).
        case question(String)
        /// The transcript has grown long with no wake phrase: end the session and start a fresh one.
        case recycle
    }

    public static let skipAfterChars = 300
    public static let recycleTotalChars = 2500

    public private(set) var phase: Phase = .waiting
    public private(set) var offset = 0
    public private(set) var lastTranscript = ""
    public private(set) var question = ""

    public init() {}

    /// A new recognition session: its transcript starts empty.
    public mutating func sessionStarted() {
        phase = .waiting; offset = 0; lastTranscript = ""; question = ""
    }

    /// Forget everything heard so far and wait for the wake phrase again, in the same session.
    public mutating func rearm() {
        offset = lastTranscript.count; question = ""; phase = .waiting
    }

    /// Olo stopped speaking: what it said is behind the offset, so it never hears itself.
    public mutating func speechEnded() {
        if phase == .waiting { offset = lastTranscript.count }
    }

    /// Olo is about to say "I'm listening".
    public mutating func beginAck() { phase = .acking }

    /// The cue has been said: whatever comes next is the question.
    public mutating func ackFinished() {
        offset = lastTranscript.count; question = ""; phase = .afterAck
    }

    public mutating func answering() { phase = .answering }
    public mutating func finished() { phase = .done }

    /// A new transcript from the recogniser. `deaf` is true while Olo itself is speaking.
    public mutating func heard(_ transcript: String, deaf: Bool = false, canRecycle: Bool = true) -> [Event] {
        lastTranscript = transcript
        let count = transcript.count
        // A revised (shorter) transcript means the recogniser started over.
        if count < offset { offset = 0 }
        if deaf || phase == .acking || phase == .answering || phase == .done { return [] }
        let text = String(transcript.dropFirst(offset))
        if phase == .afterAck {
            question = WakePhrase.cleanQuestion(text)
            return [.question(question)]
        }
        guard let raw = WakePhrase.questionAfterWake(text) else {
            if phase == .waiting, text.count > WakeTracker.skipAfterChars {
                if count > WakeTracker.recycleTotalChars, canRecycle { return [.recycle] }
                // Keep the last few words, in case "Hey Olo" is being said right now.
                let chars = Array(transcript)
                var i = min(count - 40, count - 1)
                while i >= 0, chars[i] != " " { i -= 1 }
                offset = max(offset, i + 1)
            }
            return []
        }
        var events: [Event] = []
        if phase == .waiting { phase = .capturing; events.append(.woke) }
        question = WakePhrase.cleanQuestion(raw)
        events.append(.question(question))
        return events
    }
}
