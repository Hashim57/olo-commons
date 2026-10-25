import Foundation

/// Any JSON value, for the parts of the API whose shape is open (superjson meta,
/// stored verification blobs).
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Re-decodes this value as a typed model; nil when it does not fit.
    public func decoded<T: Decodable>(as type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int? { if case .number(let n) = self { return Int(n) }; return nil }
}

public struct SessionUser: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var email: String?
    public var role: String?
    public var createdAt: String?

    public init(id: String, name: String? = nil, email: String? = nil, role: String? = nil, createdAt: String? = nil) {
        self.id = id; self.name = name; self.email = email; self.role = role; self.createdAt = createdAt
    }

    /// Anonymous workspaces have ids starting "usr_"; accounts claimed by email do not.
    public var isAnonymous: Bool { email == nil && id.hasPrefix("usr_") }
}

public struct SessionResult: Codable, Sendable {
    public var token: String
    public var user: SessionUser
}

public struct Conversation: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var folder: String?
    public var isPinned: Bool
    public var createdAt: String
    public var updatedAt: String

    public init(id: Int, title: String, folder: String? = nil, isPinned: Bool = false, createdAt: String, updatedAt: String) {
        self.id = id; self.title = title; self.folder = folder; self.isPinned = isPinned; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case id, title, folder, isPinned, createdAt, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "New conversation"
        folder = try? c.decodeIfPresent(String.self, forKey: .folder)
        isPinned = (try? c.decodeIfPresent(Bool.self, forKey: .isPinned)) ?? false
        createdAt = (try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? ""
        updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt)) ?? createdAt
    }
}

public struct Source: Codable, Equatable, Hashable, Sendable {
    public var index: Int
    public var title: String
    public var url: String
    public var reliability: Double?

    public init(index: Int, title: String, url: String, reliability: Double? = nil) {
        self.index = index; self.title = title; self.url = url; self.reliability = reliability
    }
}

public struct ClaimVerdict: Codable, Equatable, Sendable {
    /// "supported", "contradicted" or "unsupported" (not covered).
    public var claim: String
    public var verdict: String
    public var citedBy: [Int]
    public var rationale: String
    public var excerpt: String?
    public var confidence: Double?

    public init(claim: String, verdict: String, citedBy: [Int] = [], rationale: String = "", excerpt: String? = nil, confidence: Double? = nil) {
        self.claim = claim; self.verdict = verdict; self.citedBy = citedBy; self.rationale = rationale; self.excerpt = excerpt; self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey { case claim, verdict, citedBy, rationale, excerpt, confidence }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claim = (try? c.decode(String.self, forKey: .claim)) ?? ""
        verdict = (try? c.decode(String.self, forKey: .verdict)) ?? "unsupported"
        citedBy = (try? c.decode([Int].self, forKey: .citedBy)) ?? []
        rationale = (try? c.decode(String.self, forKey: .rationale)) ?? ""
        excerpt = try? c.decodeIfPresent(String.self, forKey: .excerpt)
        confidence = try? c.decodeIfPresent(Double.self, forKey: .confidence)
    }
}

public struct AnswerVerification: Codable, Equatable, Sendable {
    public var claims: [ClaimVerdict]
    public var supported: Int
    public var unsupported: Int
    public var contradicted: Int
    public var score: Double
    /// Who wrote and who checked, when the server puts it inside the verification payload.
    public var answeredBy: AnsweredBy?

    public init(claims: [ClaimVerdict], answeredBy: AnsweredBy? = nil) {
        self.claims = claims
        supported = claims.filter { $0.verdict == "supported" }.count
        contradicted = claims.filter { $0.verdict == "contradicted" }.count
        unsupported = claims.count - supported - contradicted
        score = claims.isEmpty ? 0 : Double(supported) / Double(claims.count)
        self.answeredBy = answeredBy
    }

    enum CodingKeys: String, CodingKey { case claims, supported, unsupported, contradicted, score, answeredBy = "answered_by" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        claims = (try? c.decode([ClaimVerdict].self, forKey: .claims)) ?? []
        supported = (try? c.decode(Int.self, forKey: .supported)) ?? claims.filter { $0.verdict == "supported" }.count
        contradicted = (try? c.decode(Int.self, forKey: .contradicted)) ?? claims.filter { $0.verdict == "contradicted" }.count
        unsupported = (try? c.decode(Int.self, forKey: .unsupported)) ?? (claims.count - supported - contradicted)
        score = (try? c.decode(Double.self, forKey: .score)) ?? 0
        answeredBy = try? c.decodeIfPresent(AnsweredBy.self, forKey: .answeredBy)
        if answeredBy?.isEmpty == true { answeredBy = nil }
    }
}

/// A message as helius-olo.io stores it (chat.getMessages).
public struct Message: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var conversationId: Int
    public var role: String
    public var content: String
    public var verification: AnswerVerification?
    public var sources: [Source]?
    public var createdAt: String

    public init(id: Int, conversationId: Int, role: String, content: String, verification: AnswerVerification? = nil, sources: [Source]? = nil, createdAt: String = "") {
        self.id = id; self.conversationId = conversationId; self.role = role; self.content = content
        self.verification = verification; self.sources = sources; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, conversationId, role, content, verification, sources, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        conversationId = (try? c.decode(Int.self, forKey: .conversationId)) ?? 0
        role = (try? c.decode(String.self, forKey: .role)) ?? "assistant"
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        // Older rows keep these as JSON text or in other shapes: read what fits, never fail the list.
        verification = Message.flexible(c, .verification, as: AnswerVerification.self)
        sources = Message.flexible(c, .sources, as: [Source].self)
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
    }

    private static func flexible<T: Decodable>(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, as: T.Type) -> T? {
        if let v = try? c.decodeIfPresent(T.self, forKey: key) { return v }
        if let s = try? c.decodeIfPresent(String.self, forKey: key), let data = s.data(using: .utf8) {
            return try? JSONDecoder().decode(T.self, from: data)
        }
        return nil
    }
}
