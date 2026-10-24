import Foundation

/// Words for search: lower case letters and digits, without the commonest English words.
public enum Tokenizer {
    static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "did", "do", "does", "for", "from", "has", "have", "how", "i",
        "in", "is", "it", "its", "of", "on", "or", "that", "the", "this", "to", "was", "were", "what", "when", "where",
        "which", "who", "whom", "why", "will", "with", "you", "your", "me", "my", "can", "about", "tell", "please",
    ]

    public static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                out.append(current); current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out.filter { $0.count >= 2 && !stopwords.contains($0) }
    }
}

/// A plain BM25 index (k1 1.2, b 0.75) with the title counted twice. It is built
/// once, on demand, and searching it costs microseconds: no model runs on the Mac.
public struct SearchIndex<Doc: Sendable>: Sendable {
    public struct Hit: Sendable { public let doc: Doc; public let score: Double }

    private var docs: [Doc] = []
    private var lengths: [Int] = []
    private var postings: [String: [(Int, Int)]] = [:]
    private var averageLength: Double = 1

    public init(_ items: [Doc], title: (Doc) -> String, text: (Doc) -> String) {
        docs = items
        lengths.reserveCapacity(items.count)
        var total = 0
        for (i, d) in items.enumerated() {
            let toks = Tokenizer.tokens(title(d)) + Tokenizer.tokens(title(d)) + Tokenizer.tokens(text(d))
            lengths.append(toks.count)
            total += toks.count
            var tf: [String: Int] = [:]
            for t in toks { tf[t, default: 0] += 1 }
            for (t, n) in tf { postings[t, default: []].append((i, n)) }
        }
        averageLength = items.isEmpty ? 1 : max(1, Double(total) / Double(items.count))
    }

    public var count: Int { docs.count }

    public func search(_ query: String, limit: Int = 8) -> [Hit] {
        let terms = Array(Set(Tokenizer.tokens(query)))
        guard !terms.isEmpty, !docs.isEmpty else { return [] }
        let n = Double(docs.count)
        var scores: [Int: Double] = [:]
        for t in terms {
            guard let list = postings[t] else { continue }
            let idf = log(1 + (n - Double(list.count) + 0.5) / (Double(list.count) + 0.5))
            for (i, tf) in list {
                let f = Double(tf)
                let norm = 1.2 * (0.25 + 0.75 * Double(lengths[i]) / averageLength)
                scores[i, default: 0] += idf * f * 2.2 / (f + norm)
            }
        }
        return scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map { Hit(doc: docs[$0.key], score: $0.value) }
    }
}

/// Sentence splitting that keeps initials ("Michael S. Hart") and common abbreviations whole.
public enum Sentences {
    static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "st", "jr", "sr", "prof", "no", "vs", "etc", "e.g", "i.e", "fig", "inc", "ltd", "co"]

    public static func split(_ text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var start = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "." || c == "!" || c == "?" {
                var j = i + 1
                while j < chars.count, "\"')]".contains(chars[j]) { j += 1 }
                guard j < chars.count, chars[j].isWhitespace else { i += 1; continue }
                var k = j
                while k < chars.count, chars[k].isWhitespace { k += 1 }
                let nextStartsSentence = k < chars.count && (chars[k].isUppercase || chars[k].isNumber || "\"'([".contains(chars[k]))
                if c == "." && nextStartsSentence {
                    // The word before the full stop: an initial or an abbreviation does not end a sentence.
                    var w = i - 1
                    while w >= start, !chars[w].isWhitespace { w -= 1 }
                    let word = String(chars[(w + 1)..<i])
                    if (word.count == 1 && word.first!.isUppercase) || abbreviations.contains(word.lowercased()) {
                        i += 1; continue
                    }
                }
                if nextStartsSentence {
                    let s = String(chars[start..<j]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { out.append(s) }
                    start = k
                    i = k
                    continue
                }
            }
            i += 1
        }
        let rest = String(chars[min(start, chars.count)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { out.append(rest) }
        return out
    }
}

/// A passage to answer from offline: a Commons atom, or a piece of one of your files.
public struct Passage: Equatable, Sendable {
    public var title: String
    public var text: String
    public var url: String
    public var origin: String

    public init(title: String, text: String, url: String, origin: String) {
        self.title = title; self.text = text; self.url = url; self.origin = origin
    }
}

/// An answer made with no model at all: the sentences of the best passages that
/// match the question, quoted word for word with their source. Clearly labelled,
/// never presented as checked.
public struct QuotedAnswer: Equatable, Sendable {
    public var text: String
    public var sources: [Source]
    public var covered: Bool

    public static let notCovered = "Nothing saved on this Mac covers this yet. It is queued and Olo will answer it when you are back online."

    public static func compose(question: String, passages: [Passage], maxSentences: Int = 3) -> QuotedAnswer {
        let q = Set(Tokenizer.tokens(question))
        guard !q.isEmpty, !passages.isEmpty else { return QuotedAnswer(text: notCovered, sources: [], covered: false) }
        struct Scored { let sentence: String; let passage: Int; let score: Double; let order: Int }
        var scored: [Scored] = []
        var order = 0
        for (pi, p) in passages.enumerated() {
            let titleWords = Set(Tokenizer.tokens(p.title))
            for s in Sentences.split(p.text) where s.count >= 20 && s.count <= 600 {
                let words = Set(Tokenizer.tokens(s))
                let overlap = Double(words.intersection(q).count) + 0.4 * Double(titleWords.intersection(q).count)
                if overlap > 0 {
                    // Earlier passages rank higher; the search already ordered them.
                    scored.append(Scored(sentence: s, passage: pi, score: overlap - 0.05 * Double(pi), order: order))
                }
                order += 1
            }
        }
        let picked = scored.sorted { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }.prefix(maxSentences)
        guard !picked.isEmpty else { return QuotedAnswer(text: notCovered, sources: [], covered: false) }
        var numbering: [Int: Int] = [:]
        var sources: [Source] = []
        var lines: [String] = []
        for s in picked.sorted(by: { $0.order < $1.order }) {
            if numbering[s.passage] == nil {
                numbering[s.passage] = sources.count + 1
                let p = passages[s.passage]
                sources.append(Source(index: sources.count + 1, title: p.title.isEmpty ? p.origin : p.title, url: p.url))
            }
            lines.append("\"\(s.sentence)\" [\(numbering[s.passage]!)]")
        }
        return QuotedAnswer(text: lines.joined(separator: "\n\n"), sources: sources, covered: true)
    }
}

/// Cuts a long text into overlapping pieces of about `size` characters at sentence
/// boundaries, so a search over your files finds the right part of a long document.
public enum Chunker {
    public static func chunks(_ text: String, size: Int = 900) -> [String] {
        let sentences = Sentences.split(text.replacingOccurrences(of: "\r", with: ""))
        var out: [String] = []
        var current = ""
        for s in sentences {
            if current.count + s.count + 1 > size, !current.isEmpty {
                out.append(current)
                // Carry the last sentence over, so an answer that spans the cut is still found.
                let last = Sentences.split(current).last ?? ""
                current = last.count < size / 2 ? last : ""
            }
            current += current.isEmpty ? s : " " + s
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append(current) }
        return out
    }
}
