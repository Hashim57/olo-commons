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
    /// Files the answer produced (added in 1.3; missing in conversations saved earlier, so decoded with a default).
    public var artifacts: [Artifact]
    /// References checked in Crossref, when the stream sent them beside the verification.
    public var references: [ReferenceCheck]
    /// What Olo remembered about the person that shaped this reply.
    public var memories: [UsedMemory]
    /// The Olo brain's answer for this question ("published", "held", "skipped"), when the chat shares.
    public var brainStatus: String?

    public init(role: Role, text: String, origin: AnswerOrigin? = nil, verification: AnswerVerification? = nil, sources: [Source] = [],
                notices: [String] = [], followUps: [String] = [], attachments: [String] = [], serverMessageId: Int? = nil,
                createdAt: Date = Date(), id: UUID = UUID(), writer: String? = nil, provider: String? = nil, verifier: String? = nil,
                artifacts: [Artifact] = [], references: [ReferenceCheck] = [], memories: [UsedMemory] = [], brainStatus: String? = nil) {
        self.id = id; self.role = role; self.text = text; self.origin = origin; self.verification = verification; self.sources = sources
        self.notices = notices; self.followUps = followUps; self.attachments = attachments; self.serverMessageId = serverMessageId; self.createdAt = createdAt
        self.writer = writer; self.provider = provider; self.verifier = verifier
        self.artifacts = artifacts; self.references = references; self.memories = memories
        self.brainStatus = brainStatus
    }

    enum CodingKeys: String, CodingKey {
        case id, role, text, origin, verification, sources, notices, followUps, attachments, serverMessageId, createdAt
        case writer, provider, verifier, artifacts, references, memories, brainStatus
    }

    /// Reads turns saved by every version of the app: anything missing takes its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        role = (try? c.decode(Role.self, forKey: .role)) ?? .assistant
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        origin = try? c.decodeIfPresent(AnswerOrigin.self, forKey: .origin)
        verification = try? c.decodeIfPresent(AnswerVerification.self, forKey: .verification)
        sources = (try? c.decode([Source].self, forKey: .sources)) ?? []
        notices = (try? c.decode([String].self, forKey: .notices)) ?? []
        followUps = (try? c.decode([String].self, forKey: .followUps)) ?? []
        attachments = (try? c.decode([String].self, forKey: .attachments)) ?? []
        serverMessageId = try? c.decodeIfPresent(Int.self, forKey: .serverMessageId)
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        writer = try? c.decodeIfPresent(String.self, forKey: .writer)
        provider = try? c.decodeIfPresent(String.self, forKey: .provider)
        verifier = try? c.decodeIfPresent(String.self, forKey: .verifier)
        artifacts = (try? c.decode([Artifact].self, forKey: .artifacts)) ?? []
        references = (try? c.decode([ReferenceCheck].self, forKey: .references)) ?? []
        memories = (try? c.decode([UsedMemory].self, forKey: .memories)) ?? []
        brainStatus = try? c.decodeIfPresent(String.self, forKey: .brainStatus)
    }

    /// The references line's source: those sent with the stream, else those saved inside the verification.
    public var allReferences: [ReferenceCheck] { references.isEmpty ? (verification?.references ?? []) : references }

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
    /// The server's folder for the thread, when it is in one (optional, so 1.2 files still decode).
    public var folder: String?
    /// A private chat (1.3): sent with private: true, never synced to the server list, never added to
    /// the brain, kept only on this Mac in the encrypted PrivateStore (never in conversations.json).
    public var isPrivate: Bool
    /// This chat's "Add to Olo brain" switch; nil follows the account default.
    public var addToBrain: Bool?

    public init(serverId: Int? = nil, title: String, updatedAt: Date = Date(), turns: [Turn] = [], isPinned: Bool = false, folder: String? = nil, id: UUID = UUID(),
                isPrivate: Bool = false, addToBrain: Bool? = nil) {
        self.id = id; self.serverId = serverId; self.title = title; self.updatedAt = updatedAt; self.turns = turns; self.isPinned = isPinned; self.folder = folder
        self.isPrivate = isPrivate; self.addToBrain = addToBrain
    }

    enum CodingKeys: String, CodingKey { case id, serverId, title, updatedAt, turns, isPinned, folder, isPrivate, addToBrain }

    /// Reads conversations saved by every version: the 1.3 fields default when missing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        serverId = try? c.decodeIfPresent(Int.self, forKey: .serverId)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Conversation"
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
        turns = (try? c.decode([Turn].self, forKey: .turns)) ?? []
        isPinned = (try? c.decode(Bool.self, forKey: .isPinned)) ?? false
        folder = try? c.decodeIfPresent(String.self, forKey: .folder)
        isPrivate = (try? c.decode(Bool.self, forKey: .isPrivate)) ?? false
        addToBrain = try? c.decodeIfPresent(Bool.self, forKey: .addToBrain)
    }

    /// The role and text of every turn, for the context gauge.
    public var gaugeTurns: [(role: String, text: String)] { turns.map { (role: $0.role.rawValue, text: $0.text) } }

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
        // Private chats never land in this plain file (they live in PrivateStore, encrypted).
        // Keep the most recent 300 so the file stays small.
        write("conversations.json", Array(list.filter { !$0.isPrivate }.sorted { $0.updatedAt > $1.updatedAt }.prefix(300)))
    }

    /// Conversations from the plain file, skipping any private one an older build might have written.
    public func sharedConversations() -> [LocalConversation] { conversations().filter { !$0.isPrivate } }

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
