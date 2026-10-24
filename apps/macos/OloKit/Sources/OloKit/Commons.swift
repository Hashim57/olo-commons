import Foundation

/// One fact of Olo Commons, with where it came from and its licence.
public struct Atom: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var text: String
    public var url: String
    public var source: String
    public var licence: String
    public var publishedAt: String?

    public init(id: String, title: String, text: String, url: String, source: String, licence: String, publishedAt: String? = nil) {
        self.id = id; self.title = title; self.text = text; self.url = url; self.source = source; self.licence = licence; self.publishedAt = publishedAt
    }
}

/// The offline copy of the Commons (format v1, rebuilt every six hours by the
/// snapshot workflow): {v, built_at, count, licence_note, fields, atoms:[[...]]}.
public struct CommonsSnapshot: Equatable, Sendable {
    public var builtAt: String
    public var licenceNote: String
    public var atoms: [Atom]

    public static let urls = [
        URL(string: "https://cdn.jsdelivr.net/gh/Hashim57/olo-commons@snapshot/commons.json")!,
        URL(string: "https://raw.githubusercontent.com/Hashim57/olo-commons/snapshot/commons.json")!,
    ]

    public enum SnapshotError: Error { case unsupported, malformed }

    public init(builtAt: String, licenceNote: String = "", atoms: [Atom]) {
        self.builtAt = builtAt; self.licenceNote = licenceNote; self.atoms = atoms
    }

    /// Reads the published JSON. Columns are found by name, so added fields never break an older app.
    public static func decode(_ data: Data) throws -> CommonsSnapshot {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw SnapshotError.malformed }
        guard root["v"]?.intValue == 1 else { throw SnapshotError.unsupported }
        guard case .array(let fieldValues)? = root["fields"], case .array(let rows)? = root["atoms"] else { throw SnapshotError.malformed }
        let fields = fieldValues.compactMap { $0.stringValue }
        func col(_ name: String) -> Int? { fields.firstIndex(of: name) }
        guard let iId = col("id"), let iText = col("text") else { throw SnapshotError.malformed }
        let iTitle = col("title"), iUrl = col("url"), iSource = col("source"), iLicence = col("licence"), iPub = col("published_at")
        var atoms: [Atom] = []
        atoms.reserveCapacity(rows.count)
        for row in rows {
            guard case .array(let cells) = row else { continue }
            func cell(_ i: Int?) -> String? { guard let i, i < cells.count else { return nil }; return cells[i].stringValue }
            guard let id = cell(iId), let text = cell(iText), !text.isEmpty else { continue }
            atoms.append(Atom(id: id, title: cell(iTitle) ?? "", text: text, url: cell(iUrl) ?? "",
                              source: cell(iSource) ?? "", licence: cell(iLicence) ?? "", publishedAt: cell(iPub)))
        }
        return CommonsSnapshot(builtAt: root["built_at"]?.stringValue ?? "", licenceNote: root["licence_note"]?.stringValue ?? "", atoms: atoms)
    }
}

/// The Commons' own answering service (Supabase olo-answer): written by hosted open
/// models (Groq, then Cloudflare), every sentence checked by Zeus. Used when
/// helius-olo.io cannot be reached but the internet can.
public struct CommonsAnswer: Codable, Equatable, Sendable {
    public struct Evidence: Codable, Equatable, Sendable { public var passage: String; public var quote: String }
    public struct Sentence: Codable, Equatable, Sendable {
        public var text: String
        public var citations: [String]?
        public var verdict: String?
        public var evidence: [Evidence]?
        public var rationale: String?
    }
    public struct Passage: Codable, Equatable, Sendable {
        public var id: String
        public var title: String?
        public var url: String?
        public var source: String?
        public var licence: String?
    }

    public var q: String?
    public var covered: Bool?
    public var answer: String
    public var sentences: [Sentence]?
    public var passages: [Passage]?
    public var verifier: String?
    public var model: String?
    public var mode: String?
    public var notice: String?

    public static let endpoint = URL(string: "https://bfldflbkebyapfagsxnr.supabase.co/functions/v1/olo-answer")!

    /// The sources as numbered links, and the verdicts in the same shape helius-olo.io uses.
    public var asSources: [Source] {
        (passages ?? []).enumerated().map { i, p in Source(index: i + 1, title: p.title ?? p.source ?? "Source", url: p.url ?? "") }
    }

    public var asVerification: AnswerVerification? {
        guard let sentences, !sentences.isEmpty else { return nil }
        let ids = (passages ?? []).map(\.id)
        let claims = sentences.map { s -> ClaimVerdict in
            let v: String
            switch s.verdict ?? "" {
            case "supported": v = "supported"
            case "contradicted": v = "contradicted"
            default: v = "unsupported"
            }
            let cited = (s.citations ?? []).compactMap { ids.firstIndex(of: $0) }.map { $0 + 1 }
            return ClaimVerdict(claim: s.text, verdict: v, citedBy: cited, rationale: s.rationale ?? "", excerpt: s.evidence?.first?.quote)
        }
        return AnswerVerification(claims: claims)
    }

    public static func request(question: String, k: Int = 8) throws -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["q": question, "k": k] as [String: Any])
        return req
    }

    public static func ask(_ question: String, session: URLSession = .shared) async throws -> CommonsAnswer {
        let (data, resp) = try await session.data(for: try request(question: question))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw OloAPI.StreamFailure(message: "Olo Commons answered \(status).", code: nil, httpStatus: status)
        }
        return try JSONDecoder().decode(CommonsAnswer.self, from: data)
    }
}
