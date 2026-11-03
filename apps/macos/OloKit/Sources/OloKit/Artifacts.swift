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

/// A background build (server/builds.ts BuildJob): what the "truncated" stream event hands a
/// large build to. Only the fields the Mac reads; the artifact arrives when status is "succeeded".
public struct BuildJob: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// "queued", "running", "succeeded", "failed" or "cancelled".
    public var status: String
    /// 0 to 100.
    public var progress: Int
    public var stage: String?
    public var detail: String?
    public var summary: String?
    public var artifact: Artifact?
    public var error: String?
    /// "artifact" builds a file; "answer" (v62 servers) finishes a cut prose answer, whose whole text is `summary`.
    public var mode: String
    public var messageId: Int?
    /// What the build has done so far, in order (v63 servers keep every step; older ones send none).
    public var steps: [BuildStep] = []
    /// When the run began and when the row was made (ISO 8601), for the elapsed clock.
    public var startedAt: String?
    public var createdAt: String?
    /// Who is writing or wrote the file (v63): "Olo", or "Olo's backup model" via a provider.
    public var answeredBy: AnsweredBy?

    public init(id: String, status: String, progress: Int = 0, stage: String? = nil, detail: String? = nil,
                summary: String? = nil, artifact: Artifact? = nil, error: String? = nil, mode: String = "artifact", messageId: Int? = nil) {
        self.id = id; self.status = status; self.progress = progress; self.stage = stage; self.detail = detail
        self.summary = summary; self.artifact = artifact; self.error = error; self.mode = mode; self.messageId = messageId
    }

    enum CodingKeys: String, CodingKey { case id, status, progress, stage, detail, summary, artifact, error, mode, messageId, steps, startedAt, createdAt, answeredBy }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        status = (try? c.decode(String.self, forKey: .status)) ?? "queued"
        if let p = try? c.decode(Int.self, forKey: .progress) { progress = p }
        else if let p = try? c.decode(Double.self, forKey: .progress) { progress = Int(p <= 1 ? p * 100 : p) }
        else { progress = 0 }
        stage = try? c.decodeIfPresent(String.self, forKey: .stage)
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        artifact = try? c.decodeIfPresent(Artifact.self, forKey: .artifact)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        mode = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? "artifact"
        messageId = try? c.decodeIfPresent(Int.self, forKey: .messageId)
        steps = ((try? c.decodeIfPresent([BuildStep].self, forKey: .steps)) ?? nil) ?? []
        startedAt = try? c.decodeIfPresent(String.self, forKey: .startedAt)
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        answeredBy = try? c.decodeIfPresent(AnsweredBy.self, forKey: .answeredBy)
        // Servers without the answered_by column carry the record on the finished artifact.
        if answeredBy == nil, let a = try? c.decodeIfPresent(ArtifactAnsweredBy.self, forKey: .artifact)?.answeredBy { answeredBy = a }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(status, forKey: .status); try c.encode(progress, forKey: .progress)
        try c.encodeIfPresent(stage, forKey: .stage); try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(summary, forKey: .summary); try c.encodeIfPresent(artifact, forKey: .artifact)
        try c.encodeIfPresent(error, forKey: .error); try c.encode(mode, forKey: .mode); try c.encodeIfPresent(messageId, forKey: .messageId)
        try c.encode(steps, forKey: .steps); try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(createdAt, forKey: .createdAt); try c.encodeIfPresent(answeredBy, forKey: .answeredBy)
    }

    public var isRunning: Bool { status == "queued" || status == "running" }

    /// Seconds since the run began (or the row was made), for the card's clock.
    public func elapsed(now: Date = Date()) -> TimeInterval? {
        guard let s = startedAt ?? createdAt, let d = BuildJob.date(s) else { return nil }
        return max(0, now.timeIntervalSince(d))
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// The card's rows: each step once (a live counter recorded twice folds into one), the last one
    /// current while the build runs, failed when it failed; notices (a backup writer, a pause) marked.
    public var timeline: [BuildTimelineRow] {
        var rows: [BuildTimelineRow] = []
        let first = steps.first.flatMap { BuildJob.date($0.at) }
        for (i, step) in steps.enumerated() {
            if rows.last?.label == step.detail { continue }
            let at = BuildJob.date(step.at)
            let offset = (first != nil && at != nil) ? max(0, at!.timeIntervalSince(first!)) : nil
            rows.append(BuildTimelineRow(index: i, label: step.detail, offset: offset, state: .done, notice: BuildTimelineRow.isNotice(step.detail)))
        }
        if !rows.isEmpty {
            if isRunning { rows[rows.count - 1].state = .current }
            else if status == "failed" || status == "cancelled" { rows[rows.count - 1].state = .failed }
        }
        return rows
    }

    /// The card's heading for the job's state.
    public var headline: String {
        let answer = mode == "answer"
        switch status {
        case "queued": return answer ? "Finishing the answer in the background" : "Starting the build"
        case "running": return answer ? "Finishing the answer in the background" : "Building in the background"
        case "succeeded": return answer ? "Olo finished the answer" : artifact.map { "Olo built \($0.suggestedFilename)" } ?? "Olo finished the build"
        case "cancelled": return answer ? "Cancelled before the answer was finished" : "Cancelled before the file was finished"
        default: return answer ? "The answer could not be finished" : "The build did not finish"
        }
    }

    /// The finished answer of an answer job, when it succeeded.
    public var finishedAnswer: String? {
        guard mode == "answer", status == "succeeded", let s = summary, !s.isEmpty else { return nil }
        return s
    }

    public var isFinished: Bool { status == "succeeded" || status == "failed" || status == "cancelled" }

    /// "Writing the page (40%)": the stage or detail the server recorded, with the progress.
    public var statusLine: String {
        let what = (detail?.isEmpty == false ? detail : stage) ?? "Building in the background"
        return "\(what) (\(max(0, min(100, progress)))%)"
    }
}

/// The text of a reply that may hold a file: whether it stops inside an open code fence (half a
/// file, from a cut stream), and the prose before that fence.
public enum ReplyFile {
    public static func endsInsideFence(_ text: String) -> Bool {
        text.components(separatedBy: "```").count % 2 == 0
    }

    public static func proseBeforeOpenFence(_ text: String) -> String {
        guard endsInsideFence(text), let r = text.range(of: "```", options: .backwards) else { return text }
        return String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Only the answeredBy record that a v63 server puts on a background build's artifact.
struct ArtifactAnsweredBy: Decodable { var answeredBy: AnsweredBy? }

/// One recorded step of a background build.
public struct BuildStep: Codable, Equatable, Sendable {
    public var stage: String
    public var detail: String
    public var at: String
    public init(stage: String, detail: String, at: String) { self.stage = stage; self.detail = detail; self.at = at }
}

/// A row of the build card's timeline.
public struct BuildTimelineRow: Equatable, Sendable, Identifiable {
    public enum State: Sendable { case done, current, failed }
    public var index: Int
    public var label: String
    /// Seconds after the first step.
    public var offset: TimeInterval?
    public var state: State
    public var notice: Bool
    public var id: Int { index }

    static func isNotice(_ s: String) -> Bool {
        let l = s.lowercased()
        return ["main model is unavailable", "trying once more", "asking once more", "carrying on", "paused", "token ceiling", "stopped early"].contains { l.contains($0) }
    }

    /// "0:48", "4:12".
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// Which builds go straight to the background, the same rule as the server's
/// shouldRunInBackground (server/builds.ts): a whole product (a site, an app, a guide) always does,
/// a short request for a small piece (a component, a function) streams, everything else made goes
/// to the background, where being wrong costs seconds rather than a cut file.
public enum BuildRouting {
    static let verbs: Set<String> = ["build", "create", "make", "write", "generate", "design", "code", "implement", "develop", "produce"]
    static let sites: Set<String> = ["website", "site", "page", "landing", "dashboard", "app", "webapp", "tool", "game", "portal",
                                     "catalogue", "catalog", "directory", "guide", "encyclopedia", "encyclopaedia"]
    static let small: Set<String> = ["component", "function", "snippet", "regex", "query", "button", "form", "card", "modal", "hook",
                                     "class", "script", "util", "helper", "endpoint", "schema", "type", "interface", "test"]

    public static func runsInBackground(_ prompt: String) -> Bool {
        let words = prompt.lowercased().split { !$0.isLetter }.map(String.init)
        let hasVerb = words.contains { verbs.contains($0) } || prompt.lowercased().contains("put together")
        guard hasVerb else { return false }
        if words.contains(where: { sites.contains($0) }) || prompt.lowercased().contains("web site") || prompt.lowercased().contains("web app") { return true }
        if prompt.count <= 180 && words.contains(where: { small.contains($0) }) { return false }
        return true
    }
}

extension OloAPI {
    public struct StartBuildInput: Codable, Sendable {
        public let prompt: String
        public let tier: String?
        public let conversationId: Int?
        public let projectId: Int?
        public init(prompt: String, tier: String? = nil, conversationId: Int? = nil, projectId: Int? = nil) {
            self.prompt = prompt; self.tier = tier; self.conversationId = conversationId; self.projectId = projectId
        }
    }

    /// Starts a background build (builds.start), as the web does for a large build: the job runs on
    /// the server for up to fifteen minutes and is followed with builds.get.
    public func startBuild(_ input: StartBuildInput) async throws -> BuildJob {
        let req = try TRPC.mutationRequest(base: base, path: "builds.start", input: input, token: token)
        return try await run(req, as: BuildJob.self)
    }

    /// Starts the run of a job that is still queued (POST /api/build/run). The server starts it when the
    /// job is made, but that start is sent from a function that can be frozen before it leaves; the
    /// run claims the job once, so a second start is answered 409 and nothing runs twice.
    public func kickBuild(id: String) async {
        var req = URLRequest(url: base.appendingPathComponent("api/build/run"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        TRPC.authorise(&req, token)
        req.httpBody = try? JSONEncoder().encode(JobIdInput(jobId: id))
        _ = try? await session.data(for: req)
    }

    /// Asks the server to stop a background build (builds.cancel); the model stops at its next check.
    public func cancelBuild(id: String) async throws {
        let req = try TRPC.mutationRequest(base: base, path: "builds.cancel", input: JobIdInput(jobId: id), token: token)
        _ = try await run(req, as: JSONValue.self)
    }

    /// One background build by id (builds.get).
    public func buildJob(id: String) async throws -> BuildJob {
        let req = try TRPC.queryRequest(base: base, path: "builds.get", input: JobIdInput(jobId: id), token: token)
        return try await run(req, as: BuildJob.self)
    }
}
