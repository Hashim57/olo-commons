import Foundation

/// One turn as the Mac shows and keeps it.
public struct Turn: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id: UUID
    public var role: Role
    public var text: String
    public var origin: AnswerOrigin?
    public var verification: AnswerVerification?
    public var sources: [Source]
    public var notices: [String]
    public var followUps: [String]
    public var attachments: [String]
    public var serverMessageId: Int?
    public var createdAt: Date
    /// Who answered (added in 1.1): the writing model, where it ran, and the verifier.
    /// Optional, so conversations saved by 1.0 still decode (the synthesised decoder
    /// uses decodeIfPresent for optionals).
    public var writer: String?
    public var provider: String?
    public var verifier: String?

    public init(role: Role, text: String, origin: AnswerOrigin? = nil, verification: AnswerVerification? = nil, sources: [Source] = [],
                notices: [String] = [], followUps: [String] = [], attachments: [String] = [], serverMessageId: Int? = nil,
                createdAt: Date = Date(), id: UUID = UUID(), writer: String? = nil, provider: String? = nil, verifier: String? = nil) {
        self.id = id; self.role = role; self.text = text; self.origin = origin; self.verification = verification; self.sources = sources
        self.notices = notices; self.followUps = followUps; self.attachments = attachments; self.serverMessageId = serverMessageId; self.createdAt = createdAt
        self.writer = writer; self.provider = provider; self.verifier = verifier
    }

    /// A stored helius-olo.io message as a turn.
    public init(message m: Message) {
        let a = m.verification?.answeredBy
        self.init(role: m.role == "user" ? .user : .assistant, text: m.content, origin: m.role == "user" ? nil : .olo,
                  verification: m.verification, sources: m.sources ?? [], serverMessageId: m.id,
                  createdAt: ISO8601.parse(m.createdAt) ?? Date(), writer: a?.writer, provider: a?.provider, verifier: a?.verifier)
    }

    public var answeredBy: AnsweredBy? {
        let a = AnsweredBy(writer: writer, provider: provider, verifier: verifier)
        return a.isEmpty ? nil : a
    }

    public mutating func setAnsweredBy(_ a: AnsweredBy?) {
        guard let a, !a.isEmpty else { return }
        if let w = a.writer { writer = w }
        if let p = a.provider { provider = p }
        if let v = a.verifier { verifier = v }
    }
}

/// A conversation on this Mac: a copy of one on helius-olo.io (serverId set), or one
/// started offline that is sent when the connection returns.
public struct LocalConversation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var serverId: Int?
    public var title: String
    public var updatedAt: Date
    public var turns: [Turn]
    public var isPinned: Bool

    public init(serverId: Int? = nil, title: String, updatedAt: Date = Date(), turns: [Turn] = [], isPinned: Bool = false, id: UUID = UUID()) {
        self.id = id; self.serverId = serverId; self.title = title; self.updatedAt = updatedAt; self.turns = turns; self.isPinned = isPinned
    }

    public static func title(for question: String) -> String {
        let one = question.split(whereSeparator: \.isNewline).first.map(String.init) ?? question
        let t = one.trimmingCharacters(in: .whitespaces)
        return t.count > 60 ? String(t.prefix(57)) + "..." : (t.isEmpty ? "New conversation" : t)
    }
}

public enum ISO8601 {
    public static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Everything Olo keeps on the Mac, as small JSON files in the app's own container
/// (Application Support inside the sandbox): conversations for reading offline,
/// questions waiting for a connection, and the Commons snapshot.
public final class LocalStore: @unchecked Sendable {
    public let root: URL
    private let queue = DispatchQueue(label: "olo.localstore")

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public static func appSupport() -> LocalStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return LocalStore(root: base.appendingPathComponent("Olo", isDirectory: true))
    }

    private func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    private func read<T: Decodable>(_ name: String, as: T.Type) -> T? {
        queue.sync { () -> T? in
            guard let data = try? Data(contentsOf: url(name)) else { return nil }
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            return try? d.decode(T.self, from: data)
        }
    }

    private func write<T: Encodable>(_ name: String, _ value: T) {
        queue.sync { () -> Void in
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
            guard let data = try? e.encode(value) else { return }
            try? data.write(to: url(name), options: [.atomic])
        }
    }

    public func conversations() -> [LocalConversation] { read("conversations.json", as: [LocalConversation].self) ?? [] }
    public func saveConversations(_ list: [LocalConversation]) {
        // Keep the most recent 300 so the file stays small.
        write("conversations.json", Array(list.sorted { $0.updatedAt > $1.updatedAt }.prefix(300)))
    }

    public func pending() -> [PendingQuestion] { read("pending.json", as: [PendingQuestion].self) ?? [] }
    public func savePending(_ list: [PendingQuestion]) { write("pending.json", list) }

    public var snapshotURL: URL { url("commons.json") }

    public func snapshotData() -> Data? { queue.sync { () -> Data? in try? Data(contentsOf: snapshotURL) } }

    public func saveSnapshot(_ data: Data) { queue.sync { try? data.write(to: snapshotURL, options: [.atomic]) } }

    public func snapshotAge(now: Date = Date()) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: snapshotURL.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return now.timeIntervalSince(modified)
    }

    /// Removes everything Olo saved on this Mac (Settings > Account > Remove local data).
    public func eraseAll() {
        queue.sync {
            for name in ["conversations.json", "pending.json", "commons.json"] { try? FileManager.default.removeItem(at: url(name)) }
        }
    }
}
