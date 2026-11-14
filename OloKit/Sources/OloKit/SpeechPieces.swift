import Foundation

/// The pieces Olo's voice reads one after another.
///
/// The first piece is short (a sentence or two) so the voice starts within about a second; the rest are
/// larger so there are few joins. Every cut lands at the end of a sentence, or at a comma or a space when
/// one sentence is longer than a piece, never inside a word. The server is sent the neighbouring pieces
/// with each request, so ElevenLabs keeps the same pace and tone across the joins. Mirrors
/// speechPieces.ts in olo-web and the iPhone app.
public enum SpeechPieces {
    public static let firstPieceChars = 180
    public static let pieceChars = 500

    /// The prose of an answer as it should be heard: no markdown, no code, no citation marks.
    public static func plain(_ raw: String) -> String {
        var t = raw
        func sub(_ pattern: String, _ with: String, _ options: NSRegularExpression.Options = []) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: with)
        }
        sub("```chart[\\s\\S]*?```", "")
        sub("```[\\s\\S]*?```", " Code omitted. ")
        sub("<!--[\\s\\S]*?-->", "")
        sub("\\[Attached: [^\\]]+\\]", "")
        sub("!\\[[^\\]]*\\]\\([^)]*\\)", "")
        sub("\\[([^\\]]+)\\]\\([^)]*\\)", "$1")
        sub("\\[\\d+\\]", "")
        sub("^#{1,6}\\s+(.*)$", "$1.", [.anchorsMatchLines])
        sub("^\\s*[-*•]\\s+", "", [.anchorsMatchLines])
        sub("^\\s*\\d+\\.\\s+", "", [.anchorsMatchLines])
        sub("\\*\\*([^*]+)\\*\\*", "$1")
        sub("\\*([^*]+)\\*", "$1")
        sub("`([^`]+)`", "$1")
        sub("\\|", ", ")
        sub("[ \\t]+", " ")
        sub("\\n{2,}", ". ")
        sub("\\n", " ")
        sub("\\.\\s*\\.", ".")
        sub("\\s+([.,;:!?])", "$1")
        sub("\\s+", " ")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sentences, split after . ! or ? followed by a space.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            cur.append(c)
            if ".!?".contains(c), i + 1 < chars.count, chars[i + 1] == " " {
                out.append(cur)
                cur = ""
                i += 2
                continue
            }
            i += 1
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// One sentence longer than a piece, cut at commas, or at spaces, never inside a word.
    static func splitLong(_ sentence: String, limit: Int) -> [String] {
        var out: [String] = []
        var rest = sentence
        while rest.count > limit {
            let window = String(rest.prefix(limit))
            var cut = window.range(of: ", ", options: .backwards).map { window.distance(from: window.startIndex, to: $0.lowerBound) } ?? -1
            if cut < limit / 3 { cut = window.range(of: " ", options: .backwards).map { window.distance(from: window.startIndex, to: $0.lowerBound) } ?? -1 }
            if cut <= 0 { cut = limit }
            let idx = rest.index(rest.startIndex, offsetBy: cut)
            let keepComma = rest[idx] == ","
            let piece = String(rest[..<(keepComma ? rest.index(after: idx) : idx)]).trimmingCharacters(in: .whitespaces)
            out.append(piece)
            rest = String(rest[idx...]).drop(while: { $0 == "," || $0 == " " }).description
        }
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    public static func split(_ text: String, firstChars: Int = firstPieceChars, pieceChars: Int = pieceChars) -> [String] {
        let plainText = plain(text)
        if plainText.isEmpty { return [] }
        let parts = sentences(plainText).flatMap { splitLong($0, limit: pieceChars) }
        var out: [String] = []
        var buffer = ""
        for sentence in parts {
            let limit = out.isEmpty ? firstChars : pieceChars
            if !buffer.isEmpty, buffer.count + 1 + sentence.count > limit {
                out.append(buffer)
                buffer = sentence
            } else {
                buffer = buffer.isEmpty ? sentence : buffer + " " + sentence
            }
        }
        if !buffer.isEmpty { out.append(buffer) }
        return out
    }
}
