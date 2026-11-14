import Foundation

/// Edit in place (chat.editPassage): a passage of an answer and the change asked
/// for; only that passage is rewritten and the rest stays word for word. The server
/// splices the replacement and saves the message; it does not re-verify.
public struct EditPassageInput: Codable, Equatable, Sendable {
    public var conversationId: Int
    public var messageId: Int
    public var passage: String
    public var instruction: String

    /// Limits the server enforces.
    public static let maxPassage = 4000
    public static let maxInstruction = 500

    public init(conversationId: Int, messageId: Int, passage: String, instruction: String) {
        self.conversationId = conversationId; self.messageId = messageId; self.passage = passage; self.instruction = instruction
    }

    /// Why the edit cannot be sent yet, in the server's own words, or nil when it can.
    public var problem: String? {
        let p = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        let i = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.count < 3 { return "Select a few words first." }
        if p.count > EditPassageInput.maxPassage { return "That is most of the answer. Ask for a fresh one instead of editing a passage this long." }
        if i.count < 2 { return "Say what should change." }
        if i.count > EditPassageInput.maxInstruction { return "Keep the change under 500 characters." }
        return nil
    }
}

public struct EditPassageResult: Codable, Equatable, Sendable {
    public var content: String
    public var replacement: String

    public init(content: String, replacement: String) { self.content = content; self.replacement = replacement }
}

/// One change "Fix flagged sentences" made.
public struct FixChange: Codable, Equatable, Sendable {
    public var find: String
    public var replace: String

    public init(find: String, replace: String) { self.find = find; self.replace = replace }

    enum CodingKeys: String, CodingKey { case find, replace }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        find = (try? c.decode(String.self, forKey: .find)) ?? ""
        replace = (try? c.decode(String.self, forKey: .replace)) ?? ""
    }
}

/// The corrected answer from /api/chat/fix: the flagged sentences rewritten from fresh
/// research, re-checked by Zeus, with the sources it now rests on.
public struct FixResult: Codable, Equatable, Sendable {
    public var content: String
    public var changes: [FixChange]
    public var verification: AnswerVerification?
    public var sources: [Source]
    public var queries: [String]
    public var newSources: Int

    public init(content: String, changes: [FixChange] = [], verification: AnswerVerification? = nil, sources: [Source] = [], queries: [String] = [], newSources: Int = 0) {
        self.content = content; self.changes = changes; self.verification = verification; self.sources = sources; self.queries = queries; self.newSources = newSources
    }

    enum CodingKeys: String, CodingKey { case content, changes, verification, sources, queries, newSources }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decode(String.self, forKey: .content)
        changes = (try? c.decode([FixChange].self, forKey: .changes)) ?? []
        verification = try? c.decodeIfPresent(AnswerVerification.self, forKey: .verification)
        sources = (try? c.decode([Source].self, forKey: .sources)) ?? []
        queries = (try? c.decode([String].self, forKey: .queries)) ?? []
        newSources = (try? c.decode(Int.self, forKey: .newSources)) ?? 0
    }

    /// "2 sentences rewritten from 3 new sources"
    public var summary: String {
        let n = changes.count
        var s = "\(n) sentence\(n == 1 ? "" : "s") rewritten"
        if newSources > 0 { s += " from \(newSources) new source\(newSources == 1 ? "" : "s")" }
        return s
    }
}

/// One line of the /api/chat/fix stream: progress, the result, or a failure.
public enum FixEvent: Equatable, Sendable {
    case status(stage: String, detail: String?)
    case fixed(FixResult)
    case error(String)

    public static func parse(line raw: String) -> FixEvent? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let type = value["type"]?.stringValue else { return nil }
        switch type {
        case "status":
            return .status(stage: value["stage"]?.stringValue ?? "", detail: value["detail"]?.stringValue)
        case "fixed":
            guard let r = value.decoded(as: FixResult.self) else { return .error("The correction ended without a result. Try again.") }
            return .fixed(r)
        case "error":
            return .error(value["message"]?.stringValue ?? "The correction did not go through.")
        default:
            return nil
        }
    }
}

// MARK: Server calls

extension OloAPI {
    /// Rewrites one passage of a saved answer (chat.editPassage). BAD_REQUEST carries the reason in plain words.
    public func editPassage(_ input: EditPassageInput) async throws -> EditPassageResult {
        let req = try TRPC.mutationRequest(base: base, path: "chat.editPassage", input: input, token: token)
        return try await run(req, as: EditPassageResult.self)
    }

    public struct FixInput: Codable, Sendable {
        public let conversationId: Int
        public let messageId: Int
        public init(conversationId: Int, messageId: Int) { self.conversationId = conversationId; self.messageId = messageId }
    }

    /// POST /api/chat/fix: status lines while the research runs, then one "fixed" or "error".
    public func fixFlagged(conversationId: Int, messageId: Int) -> AsyncThrowingStream<FixEvent, Error> {
        let session = self.session
        let url = base.appendingPathComponent("api/chat/fix")
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
                    req.httpBody = try JSONEncoder().encode(FixInput(conversationId: conversationId, messageId: messageId))
                    let (bytes, resp) = try await session.bytes(for: req)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if !(200..<300).contains(status) {
                        var data = Data()
                        for try await b in bytes { data.append(b); if data.count > 64_000 { break } }
                        let v = try? JSONDecoder().decode(JSONValue.self, from: data)
                        throw StreamFailure(message: v?["message"]?.stringValue ?? "The correction did not go through (\(status)).",
                                            code: v?["code"]?.stringValue, httpStatus: status)
                    }
                    for try await line in bytes.lines {
                        if let event = FixEvent.parse(line: line) { continuation.yield(event) }
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
