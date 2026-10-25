import Foundation

/// The helius-olo.io API: the same account, conversations and answers as the web
/// and iPhone apps. Every answer is written and checked in the cloud (Anthropic,
/// then OpenAI, then open models on Cloudflare; Zeus checks each sentence); the
/// Mac only sends the question and shows the stream.
public final class OloAPI: @unchecked Sendable {
    public static let defaultBase = URL(string: "https://helius-olo.io")!

    public let base: URL
    private let session: URLSession
    private let tokenLock = NSLock()
    private var _token: String?

    public init(base: URL = OloAPI.defaultBase, token: String? = nil, session: URLSession? = nil) {
        self.base = base
        self._token = token
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.waitsForConnectivity = false
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 180
            cfg.httpAdditionalHeaders = ["User-Agent": "Olo-macOS/1.0"]
            self.session = URLSession(configuration: cfg)
        }
    }

    public var token: String? {
        get { tokenLock.lock(); defer { tokenLock.unlock() }; return _token }
        set { tokenLock.lock(); _token = newValue; tokenLock.unlock() }
    }

    // MARK: tRPC helpers

    private func run<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return try TRPC.decode(T.self, data: data, status: status)
    }

    // MARK: Account

    /// A new anonymous workspace with the free allowance ("Start using Olo" on the web).
    public func createSession() async throws -> SessionResult {
        let req = try TRPC.mutationRequest(base: base, path: "auth.createSession", input: NoInput(), token: nil)
        return try await run(req, as: SessionResult.self)
    }

    public struct EmailInput: Codable { let email: String }
    public struct CodeInput: Codable { let email: String; let code: String }

    /// Sends a six digit sign-in code to the address.
    public func requestEmailCode(_ email: String) async throws {
        let req = try TRPC.mutationRequest(base: base, path: "auth.requestEmailCode", input: EmailInput(email: email), token: token)
        _ = try await run(req, as: JSONValue.self)
    }

    /// Verifies the code; the anonymous workspace (if any) moves into the account.
    public func verifyEmailCode(email: String, code: String) async throws -> SessionResult {
        let req = try TRPC.mutationRequest(base: base, path: "auth.verifyEmailCode", input: CodeInput(email: email, code: code), token: token)
        return try await run(req, as: SessionResult.self)
    }

    public struct Profile: Codable, Sendable { public var email: String? }

    public func profile() async throws -> Profile {
        try await run(try TRPC.queryRequest(base: base, path: "auth.profile", token: token), as: Profile.self)
    }

    public struct ConsentInput: Codable, Sendable {
        public let consent: Bool
        public init(consent: Bool) { self.consent = consent }
    }

    /// Records whether this person's conversations may be used to improve Olo and train
    /// Zeus (auth.setTrainingConsent). A server that does not know the procedure yet
    /// answers NOT_FOUND; the caller keeps the choice locally in that case.
    public func setTrainingConsent(_ consent: Bool) async throws {
        let req = try TRPC.mutationRequest(base: base, path: "auth.setTrainingConsent", input: ConsentInput(consent: consent), token: token)
        _ = try await run(req, as: JSONValue.self)
    }

    // MARK: Conversations

    public func listConversations() async throws -> [Conversation] {
        try await run(try TRPC.queryRequest(base: base, path: "chat.listConversations", token: token), as: [Conversation].self)
    }

    public struct ConversationInput: Codable { let conversationId: Int }

    public func messages(conversationId: Int) async throws -> [Message] {
        let req = try TRPC.queryRequest(base: base, path: "chat.getMessages", input: ConversationInput(conversationId: conversationId), token: token)
        return try await run(req, as: [Message].self)
    }

    // MARK: Asking

    public struct AskInput: Codable, Sendable {
        public var conversationId: Int?
        public var content: String
        public var tier: String = "medium"
        public var grounded: Bool = false
        public var ghost: Bool = false
        public var autoTier: Bool = true
        public var computeMode: Bool = false

        public init(conversationId: Int?, content: String, grounded: Bool = false, ghost: Bool = false) {
            self.conversationId = conversationId; self.content = content; self.grounded = grounded; self.ghost = ghost
        }
    }

    public struct StreamFailure: Error, LocalizedError, Equatable {
        public var message: String
        public var code: String?
        public var httpStatus: Int
        public init(message: String, code: String?, httpStatus: Int) {
            self.message = message; self.code = code; self.httpStatus = httpStatus
        }
        public var errorDescription: String? { message }
        /// The free allowance is used up: signing in (or a plan) is the way on.
        public var isQuota: Bool { code == "quota_exceeded" || httpStatus == 402 }
        public var isUnauthorized: Bool { httpStatus == 401 }
        /// The service (not the question) failed: worth trying the Commons instead.
        public var isServiceFailure: Bool { httpStatus >= 500 || httpStatus == 0 }
    }

    /// Asks a question and streams the answer as it is written and checked.
    public func ask(_ input: AskInput) -> AsyncThrowingStream<StreamEvent, Error> {
        let session = self.session
        let url = base.appendingPathComponent("api/chat/stream")
        let token = self.token
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 120
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("application/x-ndjson, application/json", forHTTPHeaderField: "Accept")
                    if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                    req.httpBody = try JSONEncoder().encode(input)
                    let (bytes, resp) = try await session.bytes(for: req)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if !(200..<300).contains(status) {
                        var data = Data()
                        for try await b in bytes { data.append(b); if data.count > 64_000 { break } }
                        let v = try? JSONDecoder().decode(JSONValue.self, from: data)
                        throw StreamFailure(message: v?["message"]?.stringValue ?? "helius-olo.io answered \(status).",
                                            code: v?["code"]?.stringValue, httpStatus: status)
                    }
                    for try await line in bytes.lines {
                        if let event = StreamEvent.parse(line: line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
