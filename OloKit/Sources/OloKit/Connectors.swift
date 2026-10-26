import Foundation

/// A connected account (server/connectors/google.ts). Tokens never leave the server;
/// the Mac only sees which account is connected and whether it still works.
public struct Connection: Codable, Equatable, Identifiable, Sendable {
    /// "google" is the only provider so far.
    public var provider: String
    public var account: String
    public var scopes: [String]
    public var brokenReason: String?
    public var lastUsedAt: String?
    public var createdAt: String

    public var id: String { provider }

    public init(provider: String, account: String, scopes: [String] = [], brokenReason: String? = nil, lastUsedAt: String? = nil, createdAt: String = "") {
        self.provider = provider; self.account = account; self.scopes = scopes; self.brokenReason = brokenReason; self.lastUsedAt = lastUsedAt; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case provider, account, scopes, brokenReason, lastUsedAt, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = (try? c.decode(String.self, forKey: .provider)) ?? "google"
        account = (try? c.decode(String.self, forKey: .account)) ?? ""
        scopes = (try? c.decode([String].self, forKey: .scopes)) ?? []
        brokenReason = try? c.decodeIfPresent(String.self, forKey: .brokenReason)
        lastUsedAt = try? c.decodeIfPresent(String.self, forKey: .lastUsedAt)
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
    }

    /// "Gmail and Calendar, read only", from the granted scopes.
    public var scopesLine: String {
        var parts: [String] = []
        if scopes.contains(where: { $0.contains("gmail") }) { parts.append("Gmail") }
        if scopes.contains(where: { $0.contains("calendar") }) { parts.append("Calendar") }
        if parts.isEmpty { return scopes.isEmpty ? "No access granted" : "\(scopes.count) permission\(scopes.count == 1 ? "" : "s")" }
        return parts.joined(separator: " and ") + ", read only"
    }
}

/// connectors.list: whether connectors work on this server, and what is connected.
public struct ConnectorList: Codable, Equatable, Sendable {
    public var available: Bool
    public var googleConfigured: Bool
    public var connections: [Connection]

    public init(available: Bool, googleConfigured: Bool, connections: [Connection] = []) {
        self.available = available; self.googleConfigured = googleConfigured; self.connections = connections
    }

    enum CodingKeys: String, CodingKey { case available, googleConfigured, connections }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = (try? c.decode(Bool.self, forKey: .available)) ?? false
        googleConfigured = (try? c.decode(Bool.self, forKey: .googleConfigured)) ?? false
        connections = (try? c.decode([Connection].self, forKey: .connections)) ?? []
    }

    public var google: Connection? { connections.first { $0.provider == "google" } }
}

// MARK: Server calls

extension OloAPI {
    public func listConnectors() async throws -> ConnectorList {
        try await run(try TRPC.queryRequest(base: base, path: "connectors.list", token: token), as: ConnectorList.self)
    }

    public struct ReturnToInput: Codable, Sendable {
        public var returnTo: String?
        public init(returnTo: String?) { self.returnTo = returnTo }
    }

    public struct URLResult: Codable, Sendable { public var url: String }

    /// Google's consent page for this person (connectors.startGoogle). The Mac opens it in the
    /// browser; after the callback the server sends the browser to olo://connected, which brings
    /// the app forward, and the app polls connectors.list until the account appears.
    public func startGoogle(returnTo: String = "olo://connected") async throws -> URL {
        let req = try TRPC.mutationRequest(base: base, path: "connectors.startGoogle", input: ReturnToInput(returnTo: returnTo), token: token)
        let r = try await run(req, as: URLResult.self)
        guard let url = URL(string: r.url), url.scheme == "https" else {
            throw TRPC.RemoteError(message: "The server sent an address that is not a web page.", code: nil, httpStatus: 0)
        }
        return url
    }

    public struct ProviderInput: Codable, Sendable {
        public let provider: String
        public init(provider: String) { self.provider = provider }
    }

    public func disconnect(provider: String = "google") async throws {
        let req = try TRPC.mutationRequest(base: base, path: "connectors.disconnect", input: ProviderInput(provider: provider), token: token)
        _ = try await run(req, as: JSONValue.self)
    }
}
