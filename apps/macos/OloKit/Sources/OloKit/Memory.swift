import Foundation

/// One thing Olo remembers about the person (server/memory.ts). Only what the person
/// stated, never anything sensitive, and only recalled once approved: what Olo picks
/// out of a conversation is "proposed" until the person approves it.
public struct Memory: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// "profile", "preference", "project", "person" or "fact".
    public var category: String
    public var content: String
    /// "proposed" until approved; only approved memories are recalled.
    public var status: String
    public var conversationId: Int?
    public var projectId: Int?
    public var uses: Int
    public var lastUsedAt: String?
    public var createdAt: String

    public init(id: String, category: String, content: String, status: String = "approved", conversationId: Int? = nil,
                projectId: Int? = nil, uses: Int = 0, lastUsedAt: String? = nil, createdAt: String = "") {
        self.id = id; self.category = category; self.content = content; self.status = status; self.conversationId = conversationId
        self.projectId = projectId; self.uses = uses; self.lastUsedAt = lastUsedAt; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, category, content, status, conversationId, projectId, uses, lastUsedAt, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = (try? c.decode(String.self, forKey: .category)) ?? "fact"
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        // An older server has no status: everything it lists was kept, so it counts as approved.
        status = (try? c.decode(String.self, forKey: .status)) ?? "approved"
        conversationId = try? c.decodeIfPresent(Int.self, forKey: .conversationId)
        projectId = try? c.decodeIfPresent(Int.self, forKey: .projectId)
        uses = (try? c.decode(Int.self, forKey: .uses)) ?? 0
        lastUsedAt = try? c.decodeIfPresent(String.self, forKey: .lastUsedAt)
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
    }

    public var isProposed: Bool { status == "proposed" }
}

/// The categories in the order the Memory page shows them, with the same words as the web.
public enum MemoryCategory {
    public static let order = ["profile", "preference", "project", "person", "fact"]

    public static func label(_ category: String) -> String {
        switch category {
        case "profile": return "About you"
        case "preference": return "How you like answers"
        case "project": return "What you're working on"
        case "person": return "People"
        default: return "Other things"
        }
    }

    public static func blurb(_ category: String) -> String {
        switch category {
        case "profile": return "Who you are and what you do."
        case "preference": return "Tone, format, spelling, depth."
        case "project": return "Projects and the work around them."
        case "person": return "Colleagues and collaborators you mention."
        default: return "Durable details that fit nowhere else."
        }
    }

    /// Content limits the server enforces (memory.add, memory.update).
    public static let minLength = 8
    public static let maxLength = 240
}

/// memory.list: the memories, whether memory is on, and the cap ("N of 200").
public struct MemoryList: Codable, Equatable, Sendable {
    public var memories: [Memory]
    public var enabled: Bool
    public var cap: Int

    public init(memories: [Memory], enabled: Bool = true, cap: Int = 200) {
        self.memories = memories; self.enabled = enabled; self.cap = cap
    }

    enum CodingKeys: String, CodingKey { case memories, enabled, cap }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memories = (try? c.decode([Memory].self, forKey: .memories)) ?? []
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        cap = (try? c.decode(Int.self, forKey: .cap)) ?? 200
    }

    public var proposed: [Memory] { memories.filter { $0.isProposed } }
    public var approved: [Memory] { memories.filter { !$0.isProposed } }
    /// True from 90 percent of the cap: the least used are retired when the limit is reached.
    public var nearCap: Bool { memories.count >= Int((Double(cap) * 0.9).rounded(.up)) }
}

/// memory.export: everything remembered, as a file the person owns.
public struct MemoryExport: Codable, Equatable, Sendable {
    public var exportedAt: String
    public var cap: Int
    public var memories: [Memory]

    public init(exportedAt: String, cap: Int, memories: [Memory]) {
        self.exportedAt = exportedAt; self.cap = cap; self.memories = memories
    }

    enum CodingKeys: String, CodingKey { case exportedAt, cap, memories }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exportedAt = (try? c.decode(String.self, forKey: .exportedAt)) ?? ""
        cap = (try? c.decode(Int.self, forKey: .cap)) ?? 200
        memories = (try? c.decode([Memory].self, forKey: .memories)) ?? []
    }
}

/// The exported memory as a Markdown document, grouped by category, proposed ones marked.
public enum MemoryMarkdown {
    public static func render(_ export: MemoryExport) -> String {
        var lines: [String] = ["# What Olo remembers", ""]
        lines.append("Exported \(export.exportedAt.isEmpty ? "now" : export.exportedAt). \(export.memories.count) of \(export.cap) memories.")
        lines.append("")
        lines.append("Only what you stated yourself, never health, money, politics, religion or similar details. Proposed memories are marked and are not recalled until approved.")
        for category in MemoryCategory.order {
            let items = export.memories.filter { $0.category == category }
            guard !items.isEmpty else { continue }
            lines.append("")
            lines.append("## \(MemoryCategory.label(category))")
            lines.append("")
            for m in items {
                var line = "- \(m.content)"
                if m.isProposed { line += " (proposed, not yet approved)" }
                if m.uses > 0 { line += " [used \(m.uses) time\(m.uses == 1 ? "" : "s")]" }
                lines.append(line)
            }
        }
        let known = Set(MemoryCategory.order)
        let others = export.memories.filter { !known.contains($0.category) }
        if !others.isEmpty {
            lines.append("")
            lines.append("## Other")
            lines.append("")
            for m in others { lines.append("- \(m.content)") }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// "olo-memory-2026-10-25.md"
    public static func filename(on date: Date = Date(), extension ext: String = "md") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return "olo-memory-\(f.string(from: date)).\(ext)"
    }
}

// MARK: Server calls

extension OloAPI {
    public func listMemories() async throws -> MemoryList {
        try await run(try TRPC.queryRequest(base: base, path: "memory.list", token: token), as: MemoryList.self)
    }

    /// Keeps a memory Olo proposed. Until this, it is never recalled.
    public func approveMemory(id: String) async throws {
        let req = try TRPC.mutationRequest(base: base, path: "memory.approve", input: IdInput(id: id), token: token)
        _ = try await run(req, as: JSONValue.self)
    }

    public func exportMemories() async throws -> MemoryExport {
        try await run(try TRPC.mutationRequest(base: base, path: "memory.export", token: token), as: MemoryExport.self)
    }

    public struct MemoryAddInput: Codable, Sendable {
        public let category: String
        public let content: String
        public init(category: String, content: String) { self.category = category; self.content = content }
    }

    /// Adds a memory by hand; it is approved at once. The server refuses sensitive content with BAD_REQUEST.
    public func addMemory(category: String, content: String) async throws -> Memory {
        let req = try TRPC.mutationRequest(base: base, path: "memory.add", input: MemoryAddInput(category: category, content: content), token: token)
        return try await run(req, as: Memory.self)
    }

    public struct MemoryUpdateInput: Codable, Sendable {
        public let id: String
        public let content: String
        public init(id: String, content: String) { self.id = id; self.content = content }
    }

    public func updateMemory(id: String, content: String) async throws {
        let req = try TRPC.mutationRequest(base: base, path: "memory.update", input: MemoryUpdateInput(id: id, content: content), token: token)
        _ = try await run(req, as: JSONValue.self)
    }

    /// Deletes a memory; also how a proposed memory is rejected.
    public func deleteMemory(id: String) async throws {
        let req = try TRPC.mutationRequest(base: base, path: "memory.delete", input: IdInput(id: id), token: token)
        _ = try await run(req, as: JSONValue.self)
    }

    public func clearMemories() async throws {
        _ = try await run(try TRPC.mutationRequest(base: base, path: "memory.clear", token: token), as: JSONValue.self)
    }

    public struct EnabledInput: Codable, Sendable {
        public let enabled: Bool
        public init(enabled: Bool) { self.enabled = enabled }
    }

    public func setMemoryEnabled(_ enabled: Bool) async throws {
        let req = try TRPC.mutationRequest(base: base, path: "memory.setEnabled", input: EnabledInput(enabled: enabled), token: token)
        _ = try await run(req, as: JSONValue.self)
    }
}
