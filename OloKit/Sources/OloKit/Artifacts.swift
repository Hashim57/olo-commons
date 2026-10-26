import Foundation

/// A problem the server's validator found in an artifact.
public struct ArtifactIssue: Codable, Equatable, Sendable {
    /// "error" or "warning".
    public var severity: String
    public var message: String

    public init(severity: String, message: String) { self.severity = severity; self.message = message }

    enum CodingKeys: String, CodingKey { case severity, message }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        severity = (try? c.decode(String.self, forKey: .severity)) ?? "warning"
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
    }
}

/// A file an answer produced: the "artifact" stream event (client/src/lib/chatStream.ts
/// StreamArtifact) and a row of the library (server/library.ts StoredArtifact). The
/// library fields are optional because a streamed artifact has none of them yet.
public struct Artifact: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// "html", "react", "svg", "code" or "markdown".
    public var kind: String
    public var language: String
    public var title: String
    public var filename: String
    public var code: String
    public var validated: Bool
    public var repaired: Bool
    public var issues: [ArtifactIssue]
    public var conversationId: Int?
    public var projectId: Int?
    public var version: Int?
    public var createdAt: String?
    public var updatedAt: String?

    public init(id: String, kind: String, language: String = "", title: String, filename: String, code: String,
                validated: Bool = true, repaired: Bool = false, issues: [ArtifactIssue] = [], conversationId: Int? = nil,
                projectId: Int? = nil, version: Int? = nil, createdAt: String? = nil, updatedAt: String? = nil) {
        self.id = id; self.kind = kind; self.language = language; self.title = title; self.filename = filename; self.code = code
        self.validated = validated; self.repaired = repaired; self.issues = issues; self.conversationId = conversationId
        self.projectId = projectId; self.version = version; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, language, title, filename, code, validated, repaired, issues, conversationId, projectId, version, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "code"
        language = (try? c.decode(String.self, forKey: .language)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled"
        filename = (try? c.decode(String.self, forKey: .filename)) ?? "artifact.txt"
        code = (try? c.decode(String.self, forKey: .code)) ?? ""
        validated = (try? c.decode(Bool.self, forKey: .validated)) ?? false
        repaired = (try? c.decode(Bool.self, forKey: .repaired)) ?? false
        issues = (try? c.decode([ArtifactIssue].self, forKey: .issues)) ?? []
        conversationId = try? c.decodeIfPresent(Int.self, forKey: .conversationId)
        projectId = try? c.decodeIfPresent(Int.self, forKey: .projectId)
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    /// HTML, SVG and React can be shown as a page; code and Markdown are read as text.
    public var isPreviewable: Bool { kind == "html" || kind == "svg" || kind == "react" }

    /// A React preview needs scripts from unpkg.com and JavaScript; the viewer says so before turning either on.
    public var needsScripts: Bool { kind == "react" }

    public var errors: [ArtifactIssue] { issues.filter { $0.severity == "error" } }
    public var warnings: [ArtifactIssue] { issues.filter { $0.severity != "error" } }

    /// The filename to save as, always with an extension that matches the kind.
    public var suggestedFilename: String {
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name.contains(".") { return name }
        let ext: String
        switch kind {
        case "html": ext = "html"
        case "svg": ext = "svg"
        case "react": ext = "jsx"
        case "markdown": ext = "md"
        default: ext = language.isEmpty ? "txt" : language
        }
        return (name.isEmpty ? "artifact" : name) + "." + ext
    }
}

/// Wraps an artifact into a self-contained page for the preview, as server/artifacts.ts
/// buildPreviewDocument does, so the Mac shows the same thing as the web's frame.
public enum ArtifactPreview {
    public static func document(for a: Artifact) -> String {
        switch a.kind {
        case "html":
            if a.code.range(of: "<html[\\s>]", options: [.regularExpression, .caseInsensitive]) != nil { return a.code }
            return "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head><body>\(a.code)</body></html>"
        case "svg":
            return "<!doctype html><html><head><meta charset=\"utf-8\"><style>html,body{margin:0;height:100%;display:grid;place-items:center;background:#fff}svg{max-width:100%;max-height:100%}</style></head><body>\(a.code)</body></html>"
        case "react":
            let code = a.code
                .replacingOccurrences(of: "(?m)^\\s*import[^\\n]*\\n", with: "", options: .regularExpression)
                .replacingOccurrences(of: "export default ", with: "const __Preview = ")
            return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <script crossorigin src="https://unpkg.com/react@18/umd/react.production.min.js"></script>
            <script crossorigin src="https://unpkg.com/react-dom@18/umd/react-dom.production.min.js"></script>
            <script src="https://unpkg.com/@babel/standalone/babel.min.js"></script>
            </head><body><div id="root"></div>
            <script type="text/babel" data-presets="react">
            \(code)
            try {
              const Component = typeof __Preview !== "undefined" ? __Preview : null;
              if (Component) ReactDOM.createRoot(document.getElementById("root")).render(React.createElement(Component));
              else document.getElementById("root").textContent = "No default export to preview.";
            } catch (error) {
              document.getElementById("root").textContent = "Preview failed: " + error.message;
            }
            </script></body></html>
            """
        default:
            return "<!doctype html><html><head><meta charset=\"utf-8\"><style>body{margin:16px;font:13px Menlo,monospace;white-space:pre-wrap;word-break:break-word}</style></head><body>\(escape(a.code))</body></html>"
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// A share link (server/library.ts Share). Holding the link is the permission, so
/// every link can be revoked and given an expiry.
public struct Share: Codable, Equatable, Identifiable, Sendable {
    public var token: String
    /// "artifact", "project" or "conversation".
    public var subjectType: String
    public var subjectId: String
    public var label: String?
    public var revoked: Bool
    public var expiresAt: String?
    public var viewCount: Int
    public var createdAt: String?

    public var id: String { token }

    public init(token: String, subjectType: String, subjectId: String, label: String? = nil, revoked: Bool = false,
                expiresAt: String? = nil, viewCount: Int = 0, createdAt: String? = nil) {
        self.token = token; self.subjectType = subjectType; self.subjectId = subjectId; self.label = label
        self.revoked = revoked; self.expiresAt = expiresAt; self.viewCount = viewCount; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case token, subjectType, subjectId, label, revoked, expiresAt, viewCount, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        subjectType = (try? c.decode(String.self, forKey: .subjectType)) ?? "conversation"
        subjectId = (try? c.decode(String.self, forKey: .subjectId)) ?? ""
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        revoked = (try? c.decode(Bool.self, forKey: .revoked)) ?? false
        expiresAt = try? c.decodeIfPresent(String.self, forKey: .expiresAt)
        viewCount = (try? c.decode(Int.self, forKey: .viewCount)) ?? 0
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
    }

    /// The link to send: https://helius-olo.io/s/<token>, the same as the web's /s/* route.
    public func url(base: URL = OloAPI.defaultBase) -> URL {
        base.appendingPathComponent("s").appendingPathComponent(token)
    }
}

// MARK: Server calls

extension OloAPI {
    public struct ArtifactsInput: Codable, Sendable {
        public var kind: String
        public init(kind: String) { self.kind = kind }
    }

    /// Everything built, newest first (library.artifacts). `kind` is "all" or "code".
    public func listArtifacts(kind: String = "all") async throws -> [Artifact] {
        let req = try TRPC.queryRequest(base: base, path: "library.artifacts", input: ArtifactsInput(kind: kind), token: token)
        return try await run(req, as: [Artifact].self)
    }

    public struct IdInput: Codable, Sendable {
        public let id: String
        public init(id: String) { self.id = id }
    }

    public func deleteArtifact(id: String) async throws {
        let req = try TRPC.mutationRequest(base: base, path: "library.deleteArtifact", input: IdInput(id: id), token: token)
        _ = try await run(req, as: JSONValue.self)
    }

    public struct ShareInput: Codable, Sendable {
        public var subjectType: String
        public var subjectId: String
        public var label: String?
        public var expiresInDays: Int?
        public init(subjectType: String, subjectId: String, label: String? = nil, expiresInDays: Int? = nil) {
            self.subjectType = subjectType; self.subjectId = subjectId; self.label = label; self.expiresInDays = expiresInDays
        }
    }

    /// Makes a share link (library.share). The server refuses with PRECONDITION_FAILED when it has no database.
    public func createShare(_ input: ShareInput) async throws -> Share {
        let req = try TRPC.mutationRequest(base: base, path: "library.share", input: input, token: token)
        return try await run(req, as: Share.self)
    }

    public func listShares() async throws -> [Share] {
        try await run(try TRPC.queryRequest(base: base, path: "library.shares", token: token), as: [Share].self)
    }

    public struct TokenInput: Codable, Sendable {
        public let token: String
        public init(token: String) { self.token = token }
    }

    public func revokeShare(token t: String) async throws {
        let req = try TRPC.mutationRequest(base: base, path: "library.revokeShare", input: TokenInput(token: t), token: token)
        _ = try await run(req, as: JSONValue.self)
    }
}
