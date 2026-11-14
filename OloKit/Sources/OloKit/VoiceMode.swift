import Foundation

/// Talk to Olo: a whole conversation by voice. The pure parts, mirroring
/// voiceMode.ts in olo-web and the iPhone app: what a transcript asks for, the
/// sentences of a streaming answer as they complete, and the words Olo says
/// around a build. The panel is Olo/Sources/TalkToOlo.swift.
public enum VoiceCommand: Equatable, Sendable {
    case stop
    case ask(String)
    case build(String)
}

public enum VoiceMode {
    static let stopPhrases = try! NSRegularExpression(pattern: #"^(?:ok(?:ay)?[,.!]?\s+)?(?:olo[,.!]?\s+)?(?:stop(?: listening| talking| now)?|that'?s (?:all|enough|it)(?: for now)?|goodbye|bye(?: olo| for now)?|thank(?:s| you)[,.!]?\s*(?:olo[,.!]?\s*)?(?:bye|goodbye|that'?s all)?|end (?:the )?(?:conversation|voice mode)|exit)[.!]*$"#, options: [.caseInsensitive])
    static let buildLead = try! NSRegularExpression(pattern: #"^(?:(?:ok(?:ay)?|hey|please|olo|can you|could you|i want you to|i'd like you to|i would like you to)[,.!]?\s+)*(build|make|create|generate|design|code|write)\s+(?:me\s+|us\s+)?(?:an?\s+|the\s+)?(.+)$"#, options: [.caseInsensitive])
    static let buildThings = try! NSRegularExpression(pattern: #"\b(page|landing page|website|web ?site|site|app|application|prototype|dashboard|calculator|tool|game|form|chart|document|report|deck|presentation|spreadsheet|template|component|widget|quiz|tracker|planner|invoice|cv|resume|poster|mock-?up|portfolio|script|program)\b"#, options: [.caseInsensitive])

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// What a transcript asks for: to stop, to build something, or a question.
    public static func command(_ transcript: String) -> VoiceCommand {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if text.isEmpty { return .ask("") }
        if matches(stopPhrases, text) { return .stop }
        if let m = buildLead.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range(at: 2), in: text) {
            let thing = String(text[r])
            if matches(buildThings, thing), !thing.lowercased().hasPrefix("sure"), !thing.lowercased().hasPrefix("sense") {
                return .build(text.replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression))
            }
        }
        return .ask(text)
    }

    /// An answer as Talk to Olo's panel shows it: plain sentences, no Markdown marks (no "##", no "**",
    /// no "|" tables) and no em or en dashes. Line breaks stay, list items become "•" lines, and code and
    /// charts are left to the chat. The same rules as plainForDisplay in olo-web and the iPhone app.
    public static func plainForDisplay(_ text: String) -> String {
        func re(_ s: String, _ pattern: String, _ template: String) -> String {
            s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        var t = text
        t = re(t, #"```chart[\s\S]*?(?:```|$)"#, "")
        t = re(t, #"```[\s\S]*?(?:```|$)"#, "(Code is in the chat.)")
        t = re(t, #"<!--[\s\S]*?-->"#, "")
        t = re(t, #"!\[[^\]]*\]\([^)]*\)"#, "")
        t = re(t, #"\[([^\]]+)\]\([^)]*\)"#, "$1")
        t = re(t, #"(?m)^[ \t]*\|?[ \t]*:?-{3,}:?[ \t]*(\|[ \t]*:?-{3,}:?[ \t]*)*\|?[ \t]*\n?"#, "")
        t = tableRows(t)
        t = re(t, #"(?m)^#{1,6}[ \t]+"#, "")
        t = re(t, #"(?m)^[ \t]*>[ \t]?"#, "")
        t = re(t, #"(?m)^[ \t]*[-*+][ \t]+"#, "\u{2022} ")
        t = re(t, #"\*\*([^*\n]+)\*\*"#, "$1")
        t = re(t, #"__([^_\n]+)__"#, "$1")
        t = re(t, #"(?m)(^|[\s(])\*([^*\n]+)\*(?=[\s).,!?;:]|$)"#, "$1$2")
        t = t.replacingOccurrences(of: "**", with: "")
        t = re(t, #"`([^`\n]+)`"#, "$1")
        t = re(t, #"(\d)[ \t]*\u2013[ \t]*(\d)"#, "$1-$2")
        t = re(t, #"[ \t]*[\u2014\u2013][ \t]*(?=[.!?;:,)\n])"#, "")
        t = re(t, #",?[ \t]*\u2014[ \t]*"#, ", ")
        t = re(t, #",?[ \t]+\u2013[ \t]+"#, ", ")
        t = t.replacingOccurrences(of: "\u{2013}", with: "-")
        t = re(t, #"[ \t]+\n"#, "\n")
        t = re(t, #"\n{3,}"#, "\n\n")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "| a | b |" lines become "a, b".
    static func tableRows(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > 1, trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return line }
            return trimmed.dropFirst().dropLast().split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
        }.joined(separator: "\n")
    }

    public static let listeningWords = "Go ahead, I'm listening."
    public static let stopWords = "Okay. Talk to you later."
    public static let buildStarted = "I'm on it. I'll tell you when it's ready; you can keep asking me things meanwhile."
    public static func buildDone(summary: String?, filename: String?) -> String {
        let head = filename.map { "\($0) is ready." } ?? "It's ready."
        let body = summary.map { String(SpeechPieces.plain($0).prefix(600)) } ?? "Say open to see it, or ask for a change."
        return "\(head) \(body)"
    }
    public static func buildFailed(error: String?) -> String {
        let why = error.map { ": \(String(SpeechPieces.plain($0).prefix(200)))" } ?? ""
        return "That build did not finish\(why). Say it again with a bit more detail and I'll try once more."
    }
}

/// Turns a streaming answer into pieces to speak while it is still being written. `push(full)` takes the
/// whole answer so far and returns the sentences completed since the last call, grouped: the first alone,
/// so the voice starts within a second, later ones up to `pieceChars`. `flush(full)` returns what is left
/// when the stream ends. A sentence is complete when its end mark is followed by whitespace, so a decimal
/// point mid-stream does not end it early; a code block is never half spoken.
public final class SentenceStream {
    private var spokenRaw = 0
    private var started = false
    private var buffer = ""
    private let pieceChars: Int

    public init(pieceChars: Int = 320) { self.pieceChars = pieceChars }

    public func push(_ full: String) -> [String] {
        var out: [String] = []
        let rest = String(full.dropFirst(spokenRaw))
        let fences = rest.components(separatedBy: "```").count - 1
        if fences % 2 == 1 { return out }
        // Ranges of code blocks in `rest`, so an end mark inside one does not count.
        var blocks: [Range<String.Index>] = []
        var search = rest.startIndex
        while let open = rest.range(of: "```", range: search..<rest.endIndex) {
            guard let close = rest.range(of: "```", range: open.upperBound..<rest.endIndex) else { break }
            blocks.append(open.lowerBound..<close.upperBound)
            search = close.upperBound
        }
        var last = rest.startIndex
        var i = rest.startIndex
        while i < rest.endIndex {
            let c = rest[i]
            if ".!?".contains(c) {
                // Closing quotes or brackets may follow the mark.
                var j = rest.index(after: i)
                while j < rest.endIndex, "\"')]".contains(rest[j]) { j = rest.index(after: j) }
                if j < rest.endIndex, rest[j].isWhitespace, !blocks.contains(where: { $0.contains(i) }) {
                    let sentence = SpeechPieces.plain(String(rest[last..<j]))
                    last = j
                    i = j
                    if !sentence.isEmpty {
                        if !started {
                            out.append(sentence)
                            started = true
                        } else if !buffer.isEmpty, buffer.count + 1 + sentence.count > pieceChars {
                            out.append(buffer)
                            buffer = sentence
                        } else {
                            buffer = buffer.isEmpty ? sentence : buffer + " " + sentence
                        }
                    }
                    continue
                }
            }
            i = rest.index(after: i)
        }
        spokenRaw += rest.distance(from: rest.startIndex, to: last)
        return out
    }

    public func flush(_ full: String) -> [String] {
        var out: [String] = []
        let tail = SpeechPieces.plain(String(full.dropFirst(spokenRaw)))
        spokenRaw = full.count
        if !buffer.isEmpty, !tail.isEmpty, buffer.count + 1 + tail.count <= pieceChars {
            out.append(buffer + " " + tail)
        } else {
            if !buffer.isEmpty { out.append(buffer) }
            if !tail.isEmpty { out.append(tail) }
        }
        buffer = ""
        started = true
        return out
    }
}
