import Foundation

/// One source behind a claim in the Zeus graph.
public struct EvidenceEdge: Codable, Equatable, Sendable {
    public var url: String
    public var domain: String
    public var title: String?
    public var provider: String
    /// "supports" or "contradicts".
    public var stance: String

    public init(url: String = "", domain: String, title: String? = nil, provider: String = "", stance: String) {
        self.url = url; self.domain = domain; self.title = title; self.provider = provider; self.stance = stance
    }

    enum CodingKeys: String, CodingKey { case url, domain, title, provider, stance }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        domain = (try? c.decode(String.self, forKey: .domain)) ?? ""
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        provider = (try? c.decode(String.self, forKey: .provider)) ?? ""
        stance = (try? c.decode(String.self, forKey: .stance)) ?? "supports"
    }
}

/// A claim Zeus verified and filed (server/zeus/graph.ts ClaimNode, with its evidence).
public struct ClaimNode: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var claim: String
    /// "supported", "contradicted" or "unsupported".
    public var verdict: String
    public var confidence: Double
    public var supporting: Int
    public var contradicting: Int
    /// "stable", "slow" or "volatile".
    public var volatility: String?
    public var verifiedAt: String?
    public var expiresAt: String?
    /// How often a later answer reused this verdict instead of re-checking.
    public var hitCount: Int
    public var evidence: [EvidenceEdge]

    public init(id: String, claim: String, verdict: String, confidence: Double = 0, supporting: Int = 0, contradicting: Int = 0,
                volatility: String? = nil, verifiedAt: String? = nil, expiresAt: String? = nil, hitCount: Int = 0, evidence: [EvidenceEdge] = []) {
        self.id = id; self.claim = claim; self.verdict = verdict; self.confidence = confidence; self.supporting = supporting
        self.contradicting = contradicting; self.volatility = volatility; self.verifiedAt = verifiedAt; self.expiresAt = expiresAt
        self.hitCount = hitCount; self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey { case id, claim, verdict, confidence, supporting, contradicting, volatility, verifiedAt, expiresAt, hitCount, evidence }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        claim = (try? c.decode(String.self, forKey: .claim)) ?? ""
        verdict = (try? c.decode(String.self, forKey: .verdict)) ?? "unsupported"
        confidence = (try? c.decode(Double.self, forKey: .confidence)) ?? 0
        supporting = (try? c.decode(Int.self, forKey: .supporting)) ?? 0
        contradicting = (try? c.decode(Int.self, forKey: .contradicting)) ?? 0
        volatility = try? c.decodeIfPresent(String.self, forKey: .volatility)
        verifiedAt = try? c.decodeIfPresent(String.self, forKey: .verifiedAt)
        expiresAt = try? c.decodeIfPresent(String.self, forKey: .expiresAt)
        hitCount = (try? c.decode(Int.self, forKey: .hitCount)) ?? 0
        evidence = (try? c.decode([EvidenceEdge].self, forKey: .evidence)) ?? []
    }
}

/// zeus.graph: what Zeus knows, private to this person (workspaceId null).
public struct ZeusGraph: Codable, Equatable, Sendable {
    public struct Conflict: Codable, Equatable, Sendable {
        public var a: String
        public var b: String
        public var similarity: Double
        public init(a: String, b: String, similarity: Double) { self.a = a; self.b = b; self.similarity = similarity }
    }

    public struct SourceReputation: Codable, Equatable, Identifiable, Sendable {
        public var domain: String
        public var reputation: Double
        public var total: Int
        public var id: String { domain }
        public init(domain: String, reputation: Double, total: Int) { self.domain = domain; self.reputation = reputation; self.total = total }
    }

    public struct Stats: Codable, Equatable, Sendable {
        public var claims: Int
        public var evidence: Int
        public var conflicts: Int
        public var recalled: Int
        /// Verifications avoided by recall: the graph paying for itself.
        public var saved: Int
        public init(claims: Int = 0, evidence: Int = 0, conflicts: Int = 0, recalled: Int = 0, saved: Int = 0) {
            self.claims = claims; self.evidence = evidence; self.conflicts = conflicts; self.recalled = recalled; self.saved = saved
        }
    }

    public var nodes: [ClaimNode]
    public var conflicts: [Conflict]
    public var sources: [SourceReputation]
    public var stats: Stats

    public init(nodes: [ClaimNode] = [], conflicts: [Conflict] = [], sources: [SourceReputation] = [], stats: Stats = Stats()) {
        self.nodes = nodes; self.conflicts = conflicts; self.sources = sources; self.stats = stats
    }

    enum CodingKeys: String, CodingKey { case nodes, conflicts, sources, stats }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = (try? c.decode([ClaimNode].self, forKey: .nodes)) ?? []
        conflicts = (try? c.decode([Conflict].self, forKey: .conflicts)) ?? []
        sources = (try? c.decode([SourceReputation].self, forKey: .sources)) ?? []
        stats = (try? c.decode(Stats.self, forKey: .stats)) ?? Stats(claims: nodes.count)
    }

    public var isEmpty: Bool { nodes.isEmpty }
}

/// Where each claim is drawn. A phyllotaxis spiral, as the iPhone app does: it fills a
/// circle evenly with no overlap and no iteration, and gives the same picture every time.
public enum GraphLayout {
    public struct Placed: Equatable, Identifiable, Sendable {
        public var node: ClaimNode
        public var x: Double
        public var y: Double
        /// Radius in points: 3 plus up to 11 for corroboration.
        public var r: Double
        public var id: String { node.id }
    }

    public static func place(_ nodes: [ClaimNode], size: Double, margin: Double = 30) -> [Placed] {
        let golden = Double.pi * (3 - 5.0.squareRoot())
        let count = Double(max(1, nodes.count))
        return nodes.enumerated().map { index, node in
            let radius = (size / 2 - margin) * ((Double(index) + 0.5) / count).squareRoot()
            let angle = Double(index) * golden
            return Placed(node: node,
                          x: size / 2 + radius * cos(angle),
                          y: size / 2 + radius * sin(angle),
                          r: 3 + min(11, Double(node.supporting).squareRoot() * 3))
        }
    }

    /// The placed claim under a point, nearest first, within a small slop for clicking.
    public static func hit(_ placed: [Placed], x: Double, y: Double, slop: Double = 6) -> Placed? {
        var best: Placed?
        var bestDistance = Double.infinity
        for p in placed {
            let d = ((p.x - x) * (p.x - x) + (p.y - y) * (p.y - y)).squareRoot()
            if d <= p.r + slop, d < bestDistance { best = p; bestDistance = d }
        }
        return best
    }
}

// MARK: Server calls

extension OloAPI {
    /// The private graph (zeus.graph with workspaceId null, as the iPhone app sends it).
    public func zeusGraph() async throws -> ZeusGraph {
        let input = JSONValue.object(["workspaceId": .null])
        let req = try TRPC.queryRequest(base: base, path: "zeus.graph", input: input, token: token)
        return try await run(req, as: ZeusGraph.self)
    }

    public struct LabelInput: Codable, Sendable {
        public let messageId: Int
        public let claim: String
        /// "supported", "contradicted" or "unsupported".
        public let label: String
        public init(messageId: Int, claim: String, label: String) { self.messageId = messageId; self.claim = claim; self.label = label }
    }

    public struct LabelResult: Codable, Sendable { public var matched: Bool }

    /// "Zeus was right" or "no, it was X": a training label for Olo's own verifier (zeus.label).
    public func labelClaim(_ input: LabelInput) async throws -> Bool {
        let req = try TRPC.mutationRequest(base: base, path: "zeus.label", input: input, token: token)
        return try await run(req, as: LabelResult.self).matched
    }
}
