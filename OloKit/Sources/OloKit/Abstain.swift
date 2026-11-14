import Foundation

/// Abstain by default: an answer shows only the sentences whose claim Zeus marked
/// supported. Contradicted, not covered and unmatched sentences are kept, but behind
/// a button, so a reader sees what was checked before what was merely written.
public enum Abstain {
    /// Shown when not one sentence of the answer could be verified.
    public static let nothingVerified = "Olo could not verify this answer from its sources. The unverified draft is below."

    /// The verdict given to a sentence no claim matched.
    public static let unmatched = "unverified"

    /// The share of a claim's content words a sentence must contain to count as that claim.
    public static let threshold = 0.6

    /// Splits the answer into sentences and sorts each by the verdict of the claim it
    /// matches. A sentence is matched to the claim sharing the most content words, and
    /// only when it has at least 60 percent of that claim's content words; otherwise it
    /// is "unverified". `hidden` keeps the answer's order and pairs each sentence with
    /// its verdict ("contradicted", "unsupported" or "unverified").
    public static func splitShown(text: String, claims: [ClaimVerdict]) -> (shown: [String], hidden: [(String, String)]) {
        let claimWords: [Set<String>] = claims.map { Set(Tokenizer.tokens($0.claim)) }
        var shown: [String] = []
        var hidden: [(String, String)] = []
        for sentence in sentences(of: text) {
            let words = Set(Tokenizer.tokens(sentence))
            var best: Int?
            var bestOverlap = 0
            for (i, cw) in claimWords.enumerated() where !cw.isEmpty {
                let overlap = cw.intersection(words).count
                guard overlap > 0, Double(overlap) / Double(cw.count) >= threshold else { continue }
                if overlap > bestOverlap { bestOverlap = overlap; best = i }
            }
            if let best {
                if claims[best].verdict == "supported" {
                    shown.append(sentence)
                } else {
                    hidden.append((sentence, claims[best].verdict))
                }
            } else {
                hidden.append((sentence, unmatched))
            }
        }
        return (shown, hidden)
    }

    /// Sentences line by line, so list items and headings never run into the sentence after them.
    public static func sentences(of text: String) -> [String] {
        var out: [String] = []
        for line in text.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: true) {
            out += Sentences.split(String(line))
        }
        return out
    }

    /// A plain label for a hidden sentence's verdict.
    public static func label(for verdict: String) -> String {
        switch verdict {
        case "contradicted": return "Contradicted by its sources"
        case "unsupported", "not_covered": return "Not covered by its sources"
        default: return "Not checked"
        }
    }
}

/// Who answered: the model that wrote, where it ran, and which verifier checked it.
/// Sent by the stream as {type:"answered_by", writer, writer_provider or provider,
/// verifier}, or inside the verification payload; the Commons answer carries the same.
public struct AnsweredBy: Codable, Equatable, Sendable {
    public var writer: String?
    public var provider: String?
    public var verifier: String?

    public init(writer: String?, provider: String?, verifier: String?) {
        self.writer = writer; self.provider = provider; self.verifier = verifier
    }

    enum CodingKeys: String, CodingKey { case writer, provider, writerProvider = "writer_provider", verifier }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        writer = AnsweredBy.text(c, .writer)
        provider = AnsweredBy.text(c, .writerProvider) ?? AnsweredBy.text(c, .provider)
        verifier = AnsweredBy.text(c, .verifier)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(writer, forKey: .writer)
        try c.encodeIfPresent(provider, forKey: .provider)
        try c.encodeIfPresent(verifier, forKey: .verifier)
    }

    private static func text(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        guard let s = try? c.decodeIfPresent(String.self, forKey: key) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Reads {writer, writer_provider or provider, verifier} from any JSON object.
    public init?(json: JSONValue) {
        guard case .object = json else { return nil }
        let writer = json["writer"]?.stringValue
        let provider = json["writer_provider"]?.stringValue ?? json["provider"]?.stringValue
        let verifier = json["verifier"]?.stringValue
        guard writer != nil || provider != nil || verifier != nil else { return nil }
        self.init(writer: writer, provider: provider, verifier: verifier)
    }

    public var isEmpty: Bool { writer == nil && provider == nil && verifier == nil }

    /// "Answered by <writer> via <provider>, checked by <verifier>", leaving out what is unknown.
    public var line: String? {
        var s = ""
        if let writer { s = "Answered by \(writer)" }
        if let provider { s += s.isEmpty ? "Answered via \(provider)" : " via \(provider)" }
        if let verifier { s += s.isEmpty ? "Checked by \(verifier)" : ", checked by \(verifier)" }
        return s.isEmpty ? nil : s
    }
}

/// How many independent publishers stand behind an answer: distinct hostnames of its sources.
public enum Publishers {
    public static func hosts(of sources: [Source]) -> [String] {
        var seen: [String] = []
        for s in sources {
            guard let host = URL(string: s.url)?.host?.lowercased(), !host.isEmpty else { continue }
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if !seen.contains(bare) { seen.append(bare) }
        }
        return seen
    }

    /// "3 sources from 2 independent publishers"; nil when there are no sources with a web address.
    public static func summary(of sources: [Source]) -> String? {
        let hosts = hosts(of: sources)
        guard !sources.isEmpty, !hosts.isEmpty else { return nil }
        let n = sources.count, m = hosts.count
        return "\(n) source\(n == 1 ? "" : "s") from \(m) independent publisher\(m == 1 ? "" : "s")"
    }
}
