import Foundation

/// A watched claim (server/zeus/monitors.ts): Olo re-checks it on a schedule and says
/// when the evidence moves. Created from an answer (monitors.watch with the claim's
/// graph id), listed and stopped on the Watching panel.
public struct Monitor: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var claimId: String
    public var claim: String
    /// "supported", "contradicted" or "unsupported" when the watch began.
    public var baselineVerdict: String
    public var baselineConfidence: Double?
    public var intervalDays: Int
    public var active: Bool
    public var lastChecked: String?
    public var nextCheck: String?
    public var changedAt: String?
    public var changeNote: String?

    public init(id: String, claimId: String, claim: String, baselineVerdict: String, baselineConfidence: Double? = nil, intervalDays: Int = 30,
                active: Bool = true, lastChecked: String? = nil, nextCheck: String? = nil, changedAt: String? = nil, changeNote: String? = nil) {
        self.id = id; self.claimId = claimId; self.claim = claim; self.baselineVerdict = baselineVerdict; self.baselineConfidence = baselineConfidence
        self.intervalDays = intervalDays; self.active = active; self.lastChecked = lastChecked; self.nextCheck = nextCheck
        self.changedAt = changedAt; self.changeNote = changeNote
    }

    enum CodingKeys: String, CodingKey {
        case id, claimId, claim, baselineVerdict, baselineConfidence, intervalDays, active, lastChecked, nextCheck, changedAt, changeNote
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        claimId = (try? c.decode(String.self, forKey: .claimId)) ?? ""
        claim = (try? c.decode(String.self, forKey: .claim)) ?? ""
        baselineVerdict = (try? c.decode(String.self, forKey: .baselineVerdict)) ?? "unsupported"
        baselineConfidence = try? c.decodeIfPresent(Double.self, forKey: .baselineConfidence)
        intervalDays = (try? c.decode(Int.self, forKey: .intervalDays)) ?? 30
        active = (try? c.decode(Bool.self, forKey: .active)) ?? true
        lastChecked = try? c.decodeIfPresent(String.self, forKey: .lastChecked)
        nextCheck = try? c.decodeIfPresent(String.self, forKey: .nextCheck)
        changedAt = try? c.decodeIfPresent(String.self, forKey: .changedAt)
        changeNote = try? c.decodeIfPresent(String.self, forKey: .changeNote)
    }

    /// The evidence moved since the person last looked.
    public var hasChanged: Bool { changedAt != nil }

    /// "every 3 days", "every 30 days".
    public var intervalLine: String { "every \(intervalDays) day\(intervalDays == 1 ? "" : "s")" }
}

/// One change monitors.checkNow reported.
public struct MonitorChange: Codable, Equatable, Sendable {
    public var monitorId: String
    public var claim: String
    public var from: String?
    public var to: String?
    public var note: String

    enum CodingKeys: String, CodingKey { case monitorId, claim, from, to, note }

    public init(monitorId: String, claim: String, from: String? = nil, to: String? = nil, note: String) {
        self.monitorId = monitorId; self.claim = claim; self.from = from; self.to = to; self.note = note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        monitorId = (try? c.decode(String.self, forKey: .monitorId)) ?? ""
        claim = (try? c.decode(String.self, forKey: .claim)) ?? ""
        from = try? c.decodeIfPresent(String.self, forKey: .from)
        to = try? c.decodeIfPresent(String.self, forKey: .to)
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
    }
}

/// What monitors.checkNow did.
public struct MonitorCheck: Codable, Equatable, Sendable {
    public var checked: Int
    public var changed: [MonitorChange]
    public var notified: Int

    public init(checked: Int, changed: [MonitorChange] = [], notified: Int = 0) {
        self.checked = checked; self.changed = changed; self.notified = notified
    }

    enum CodingKeys: String, CodingKey { case checked, changed, notified }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checked = (try? c.decode(Int.self, forKey: .checked)) ?? 0
        changed = (try? c.decode([MonitorChange].self, forKey: .changed)) ?? []
        notified = (try? c.decode(Int.self, forKey: .notified)) ?? 0
    }

    /// The sentence the panels show, the same on every client.
    public var summary: String {
        if checked == 0 { return "Nothing to check right now." }
        if changed.isEmpty { return "Checked \(checked). Nothing has changed." }
        return "\(changed.count) of \(checked) changed. \(changed[0].note)"
    }
}

/// The person's webhook: a POST to it re-checks their watched claims.
public struct MonitorHook: Codable, Equatable, Sendable {
    public var token: String
    /// A path on helius-olo.io: "/api/monitors/hook/<token>".
    public var url: String
    public var fires: Int
    public var lastFired: String?
    public var createdAt: String?

    public init(token: String, url: String, fires: Int = 0, lastFired: String? = nil, createdAt: String? = nil) {
        self.token = token; self.url = url; self.fires = fires; self.lastFired = lastFired; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case token, url, fires, lastFired, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        url = (try? c.decode(String.self, forKey: .url)) ?? "/api/monitors/hook/\(token)"
        fires = (try? c.decode(Int.self, forKey: .fires)) ?? 0
        lastFired = try? c.decodeIfPresent(String.self, forKey: .lastFired)
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
    }

    /// The full address to call.
    public func fullURL(base: URL = OloAPI.defaultBase) -> URL {
        URL(string: url, relativeTo: base)?.absoluteURL ?? base
    }
}

/// The evidence file: every claim with its provenance, as a page to print or send.
public struct EvidenceFile: Codable, Equatable, Sendable {
    public var html: String
    public var claimCount: Int
    public var sourceCount: Int

    public init(html: String, claimCount: Int, sourceCount: Int) { self.html = html; self.claimCount = claimCount; self.sourceCount = sourceCount }

    enum CodingKeys: String, CodingKey { case html, claimCount, sourceCount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        html = (try? c.decode(String.self, forKey: .html)) ?? ""
        claimCount = (try? c.decode(Int.self, forKey: .claimCount)) ?? 0
        sourceCount = (try? c.decode(Int.self, forKey: .sourceCount)) ?? 0
    }
}

// MARK: Server calls

extension OloAPI {
    public func listMonitors() async throws -> [Monitor] {
        try await run(try TRPC.queryRequest(base: base, path: "monitors.list", token: token), as: [Monitor].self)
    }

    public struct WatchInput: Codable, Sendable {
        public let claimId: String
        public var intervalDays: Int?
        public init(claimId: String, intervalDays: Int? = nil) { self.claimId = claimId; self.intervalDays = intervalDays }
    }

    /// Watches a claim by its graph id (monitors.watch). NOT_FOUND when the claim was never filed.
    public func watchClaim(claimId: String, intervalDays: Int? = nil) async throws -> Monitor {
        let req = try TRPC.mutationRequest(base: base, path: "monitors.watch", input: WatchInput(claimId: claimId, intervalDays: intervalDays), token: token)
        return try await run(req, as: Monitor.self)
    }

    public struct MonitorIdInput: Codable, Sendable {
        public var monitorId: String?
        public init(monitorId: String?) { self.monitorId = monitorId }
    }

    public func unwatch(monitorId: String) async throws {
        let req = try TRPC.mutationRequest(base: base, path: "monitors.unwatch", input: MonitorIdInput(monitorId: monitorId), token: token)
        _ = try await run(req, as: JSONValue.self)
    }

    public func acknowledgeChange(monitorId: String) async throws {
        let req = try TRPC.mutationRequest(base: base, path: "monitors.acknowledge", input: MonitorIdInput(monitorId: monitorId), token: token)
        _ = try await run(req, as: JSONValue.self)
    }

    /// Re-checks one monitor, or all of them when nil.
    public func checkMonitorsNow(monitorId: String? = nil) async throws -> MonitorCheck {
        let req = try TRPC.mutationRequest(base: base, path: "monitors.checkNow", input: MonitorIdInput(monitorId: monitorId), token: token)
        return try await run(req, as: MonitorCheck.self)
    }

    /// The webhook, or nil when none has been made.
    public func monitorHook() async throws -> MonitorHook? {
        try await run(try TRPC.queryRequest(base: base, path: "monitors.hook", token: token), as: MonitorHook?.self)
    }

    public func rotateMonitorHook() async throws -> MonitorHook {
        try await run(try TRPC.mutationRequest(base: base, path: "monitors.rotateHook", token: token), as: MonitorHook.self)
    }

    public func revokeMonitorHook() async throws {
        _ = try await run(try TRPC.mutationRequest(base: base, path: "monitors.revokeHook", token: token), as: JSONValue.self)
    }

    public struct EvidenceInput: Codable, Sendable {
        public var title: String?
        public init(title: String?) { self.title = title }
    }

    public func evidenceFile(title: String = "Evidence file") async throws -> EvidenceFile {
        let req = try TRPC.mutationRequest(base: base, path: "monitors.evidenceFile", input: EvidenceInput(title: title), token: token)
        return try await run(req, as: EvidenceFile.self)
    }
}
