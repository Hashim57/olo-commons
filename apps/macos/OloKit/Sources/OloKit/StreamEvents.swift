import Foundation

/// One event of helius-olo.io's /api/chat/stream, which sends one JSON object per line.
/// Mirrors client/src/lib/chatStream.ts in olo-web, so the Mac, the web and iPhone read
/// the same stream the same way.
public enum StreamEvent: Equatable, Sendable {
    case start(conversationId: Int)
    case delta(String)
    case sources([Source])
    case status(stage: String, detail: String?)
    case notice(String)
    case verification(AnswerVerification)
    /// Who wrote the answer, where it ran and who checked it ({type:"answered_by", writer, writer_provider or provider, verifier}).
    case answeredBy(writer: String?, provider: String?, verifier: String?)
    case followUps([String])
    case cut(String)
    case answerComplete(conversationId: Int?, messageId: Int?)
    case done(conversationId: Int?, messageId: Int?)
    case error(message: String, detail: String?, code: String?)
    /// Anything this version does not use (artifacts, memories, builds): ignored, never an error.
    case other(String)

    /// Parses one line; nil for blank or malformed lines (skipped, as the web client does).
    public static func parse(line raw: String) -> StreamEvent? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let type = value["type"]?.stringValue else { return nil }
        switch type {
        case "start":
            guard let id = value["conversationId"]?.intValue else { return nil }
            return .start(conversationId: id)
        case "delta":
            guard let text = value["text"]?.stringValue else { return nil }
            return .delta(text)
        case "sources":
            return .sources(value["sources"]?.decoded(as: [Source].self) ?? [])
        case "status":
            return .status(stage: value["stage"]?.stringValue ?? "", detail: value["detail"]?.stringValue)
        case "notice":
            guard let m = value["message"]?.stringValue else { return nil }
            return .notice(m)
        case "verification":
            guard var v = value["verification"]?.decoded(as: AnswerVerification.self) else { return nil }
            // answered_by may sit beside the verification rather than inside it.
            if v.answeredBy == nil, let a = value["answered_by"].flatMap(AnsweredBy.init(json:)) { v.answeredBy = a }
            return .verification(v)
        case "answered_by":
            let a = AnsweredBy(json: value) ?? value["answered_by"].flatMap(AnsweredBy.init(json:))
            return .answeredBy(writer: a?.writer, provider: a?.provider, verifier: a?.verifier)
        case "followups":
            if case .array(let items)? = value["questions"] {
                return .followUps(items.compactMap { $0.stringValue })
            }
            return nil
        case "cut":
            return .cut(value["message"]?.stringValue ?? "The answer was cut short.")
        case "answer_complete":
            return .answerComplete(conversationId: value["conversationId"]?.intValue, messageId: value["messageId"]?.intValue)
        case "done":
            return .done(conversationId: value["conversationId"]?.intValue, messageId: value["messageId"]?.intValue)
        case "error":
            return .error(message: value["message"]?.stringValue ?? "The model call failed.",
                          detail: value["detail"]?.stringValue, code: value["code"]?.stringValue)
        default:
            return .other(type)
        }
    }
}

/// Splits arriving bytes into complete lines; keeps a partial line until its newline comes.
public struct LineBuffer: Sendable {
    private var pending = Data()
    public init() {}

    public mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<nl]
            lines.append(String(decoding: lineData, as: UTF8.self))
            pending = Data(pending[pending.index(after: nl)...])
        }
        return lines
    }

    /// Whatever is left when the stream ends (a last line without a newline).
    public mutating func finish() -> String? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}

/// What a finished (or cut) stream adds up to.
public struct StreamOutcome: Equatable, Sendable {
    public var conversationId: Int?
    public var messageId: Int?
    public var text: String = ""
    public var sources: [Source] = []
    public var verification: AnswerVerification?
    public var answeredBy: AnsweredBy?
    public var notices: [String] = []
    public var followUps: [String] = []
    public var status: String?
    /// The server said the answer is saved. A stream can end without this when the host
    /// closes long connections; the app then fetches the saved copy instead of losing it.
    public var completed = false
    public var error: StreamEvent?

    public init() {}

    public mutating func apply(_ event: StreamEvent) {
        switch event {
        case .start(let id): conversationId = id
        case .delta(let t): text += t
        case .sources(let s): sources = s
        case .status(let stage, let detail): status = detail ?? stage
        case .notice(let m): notices.append(m)
        case .verification(let v):
            verification = v
            if let a = v.answeredBy { answeredBy = a }
        case .answeredBy(let w, let p, let v):
            let a = AnsweredBy(writer: w, provider: p, verifier: v)
            if !a.isEmpty { answeredBy = a }
        case .followUps(let q): followUps = q
        case .cut(let m): notices.append(m)
        case .answerComplete(let c, let m):
            if let c { conversationId = c }
            if let m { messageId = m }
            completed = true
        case .done(let c, let m):
            if let c { conversationId = c }
            if let m { messageId = m }
        case .error: error = event
        case .other: break
        }
    }
}
