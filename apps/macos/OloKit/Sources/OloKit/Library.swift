import Foundation

/// A hit of chat.search: full text search across every thread.
public struct SearchHit: Codable, Equatable, Identifiable, Sendable {
    public var conversationId: Int
    public var conversationTitle: String
    public var messageId: Int
    public var role: String
    public var snippet: String
    public var createdAt: String

    public var id: Int { messageId }

    public init(conversationId: Int, conversationTitle: String, messageId: Int, role: String, snippet: String, createdAt: String = "") {
        self.conversationId = conversationId; self.conversationTitle = conversationTitle; self.messageId = messageId
        self.role = role; self.snippet = snippet; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case conversationId, conversationTitle, messageId, role, snippet, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationId = try c.decode(Int.self, forKey: .conversationId)
        conversationTitle = (try? c.decode(String.self, forKey: .conversationTitle)) ?? "Conversation"
        messageId = (try? c.decode(Int.self, forKey: .messageId)) ?? 0
        role = (try? c.decode(String.self, forKey: .role)) ?? "assistant"
        snippet = (try? c.decode(String.self, forKey: .snippet)) ?? ""
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
    }
}

/// A project (server/projects.ts): standing instructions and reference files that go
/// with every question asked inside it.
public struct Project: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var description: String?
    public var instructions: String?
    /// "general", "coding", "research" or "writing".
    public var kind: String
    public var color: String?
    public var isArchived: Bool
    public var createdAt: String
    public var updatedAt: String

    public init(id: Int, name: String, description: String? = nil, instructions: String? = nil, kind: String = "general",
                color: String? = nil, isArchived: Bool = false, createdAt: String = "", updatedAt: String = "") {
        self.id = id; self.name = name; self.description = description; self.instructions = instructions; self.kind = kind
        self.color = color; self.isArchived = isArchived; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case id, name, description, instructions, kind, color, isArchived, createdAt, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Project"
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        instructions = try? c.decodeIfPresent(String.self, forKey: .instructions)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "general"
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        isArchived = (try? c.decode(Bool.self, forKey: .isArchived)) ?? false
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
        updatedAt = (try? c.decode(String.self, forKey: .updatedAt)) ?? createdAt
    }
}

/// A reference file inside a project. `content` is left out of listings the Mac keeps.
public struct ProjectFile: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var projectId: Int
    public var name: String
    public var fileType: String
    public var sizeBytes: Int
    public var isIncluded: Bool
    public var createdAt: String

    enum CodingKeys: String, CodingKey { case id, projectId, name, fileType, sizeBytes, isIncluded, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        projectId = (try? c.decode(Int.self, forKey: .projectId)) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? "File"
        fileType = (try? c.decode(String.self, forKey: .fileType)) ?? "text"
        sizeBytes = (try? c.decode(Int.self, forKey: .sizeBytes)) ?? 0
        isIncluded = (try? c.decode(Bool.self, forKey: .isIncluded)) ?? true
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
    }
}

/// projects.context: what the model will see for a project, for a usage line.
public struct ProjectContext: Codable, Equatable, Sendable {
    public var filesIncluded: Int
    public var filesSkipped: Int
    public var charactersUsed: Int
    public var budget: Int
    public var truncated: Bool

    public init(filesIncluded: Int, filesSkipped: Int, charactersUsed: Int, budget: Int, truncated: Bool) {
        self.filesIncluded = filesIncluded; self.filesSkipped = filesSkipped; self.charactersUsed = charactersUsed
        self.budget = budget; self.truncated = truncated
    }
}

/// Unfinished work surfaced on return (server/nudges.ts): a build that finished, a
/// watched claim that changed, an idle thread. Shown in the app; the server has no
/// push token type for a Mac.
public struct Nudge: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// "build_ready", "build_failed", "project_idle", "thread_idle" or "claim_changed".
    public var kind: String
    public var subjectId: String?
    public var title: String
    public var body: String
    public var suggestion: String?
    public var status: String
    public var createdAt: String

    public init(id: String, kind: String, subjectId: String? = nil, title: String, body: String, suggestion: String? = nil,
                status: String = "pending", createdAt: String = "") {
        self.id = id; self.kind = kind; self.subjectId = subjectId; self.title = title; self.body = body
        self.suggestion = suggestion; self.status = status; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, kind, subjectId, title, body, suggestion, status, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "thread_idle"
        subjectId = try? c.decodeIfPresent(String.self, forKey: .subjectId)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        suggestion = try? c.decodeIfPresent(String.self, forKey: .suggestion)
        status = (try? c.decode(String.self, forKey: .status)) ?? "pending"
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
    }

    /// The thread a nudge points at, when it is about one (thread_idle carries the conversation id).
    public var conversationId: Int? {
        guard kind == "thread_idle", let s = subjectId else { return nil }
        return Int(s)
    }
}

// MARK: Server calls

extension OloAPI {
    // Conversations

    public func deleteConversation(id: Int) async throws {
        let req = try TRPC.mutationRequest(base: base, path: "chat.deleteConversation", input: ConversationInput(conversationId: id), token: token)
        _ = try await run(req, as: JSONValue.self)
    }

    public struct OrganizationInput: Codable, Sendable {
        public var conversationId: Int
        public var folder: String?
        public var folderColor: String?
        public var isPinned: Bool

        public init(conversationId: Int, folder: String?, folderColor: String?, isPinned: Bool) {
            self.conversationId = conversationId; self.folder = folder; self.folderColor = folderColor; self.isPinned = isPinned
        }

        enum CodingKeys: String, CodingKey { case conversationId, folder, folderColor, isPinned }

        /// The server wants `folder` and `folderColor` present, null when empty, so they are written explicitly.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(conversationId, forKey: .conversationId)
            try c.encode(folder, forKey: .folder)
            try c.encode(folderColor, forKey: .folderColor)
            try c.encode(isPinned, forKey: .isPinned)
        }
    }

    /// Pins or moves a conversation (chat.updateConversationOrganization).
    public func updateOrganization(_ input: OrganizationInput) async throws {
        let req = try TRPC.mutationRequest(base: base, path: "chat.updateConversationOrganization", input: input, token: token)
        _ = try await run(req, as: JSONValue.self)
    }

    public struct SearchInput: Codable, Sendable {
        public let query: String
        public init(query: String) { self.query = query }
    }

    /// Full text search across every thread (chat.search, two to 120 characters).
    public func searchMessages(_ query: String) async throws -> [SearchHit] {
        let q = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let req = try TRPC.queryRequest(base: base, path: "chat.search", input: SearchInput(query: q), token: token)
        return try await run(req, as: [SearchHit].self)
    }

    // Projects

    public func listProjects() async throws -> [Project] {
        try await run(try TRPC.queryRequest(base: base, path: "projects.list", token: token), as: [Project].self)
    }

    public struct ProjectCreateInput: Codable, Sendable {
        public var name: String
        public var description: String?
        public var instructions: String?
        public var kind: String?
        public init(name: String, description: String? = nil, instructions: String? = nil, kind: String? = nil) {
            self.name = name; self.description = description; self.instructions = instructions; self.kind = kind
        }
    }

    public func createProject(_ input: ProjectCreateInput) async throws -> Project {
        let req = try TRPC.mutationRequest(base: base, path: "projects.create", input: input, token: token)
        return try await run(req, as: Project.self)
    }

    public struct ProjectUpdateInput: Codable, Sendable {
        public var projectId: Int
        public var name: String?
        public var description: String?
        public var instructions: String?
        public var kind: String?
        public var isArchived: Bool?
        public init(projectId: Int, name: String? = nil, description: String? = nil, instructions: String? = nil, kind: String? = nil, isArchived: Bool? = nil) {
            self.projectId = projectId; self.name = name; self.description = description; self.instructions = instructions; self.kind = kind; self.isArchived = isArchived
        }
    }

    public func updateProject(_ input: ProjectUpdateInput) async throws {
        let req = try TRPC.mutationRequest(base: base, path: "projects.update", input: input, token: token)
        _ = try await run(req, as: JSONValue.self)
    }

    public struct ProjectIdInput: Codable, Sendable {
        public let projectId: Int
        public init(projectId: Int) { self.projectId = projectId }
    }

    public func deleteProject(id: Int) async throws {
        let req = try TRPC.mutationRequest(base: base, path: "projects.delete", input: ProjectIdInput(projectId: id), token: token)
        _ = try await run(req, as: JSONValue.self)
    }

    public func listProjectFiles(projectId: Int) async throws -> [ProjectFile] {
        let req = try TRPC.queryRequest(base: base, path: "projects.listFiles", input: ProjectIdInput(projectId: projectId), token: token)
        return try await run(req, as: [ProjectFile].self)
    }

    public struct ProjectFileInput: Codable, Sendable {
        public var projectId: Int
        public var name: String
        public var content: String
        public var fileType: String?
        public init(projectId: Int, name: String, content: String, fileType: String? = nil) {
            self.projectId = projectId; self.name = name; self.content = content; self.fileType = fileType
        }
    }

    public func addProjectFile(_ input: ProjectFileInput) async throws -> ProjectFile {
        let req = try TRPC.mutationRequest(base: base, path: "projects.addFile", input: input, token: token)
        return try await run(req, as: ProjectFile.self)
    }

    public struct FileIdInput: Codable, Sendable {
        public let fileId: Int
        public init(fileId: Int) { self.fileId = fileId }
    }

    public func deleteProjectFile(id: Int) async throws {
        let req = try TRPC.mutationRequest(base: base, path: "projects.deleteFile", input: FileIdInput(fileId: id), token: token)
        _ = try await run(req, as: JSONValue.self)
    }

    public func projectContext(projectId: Int) async throws -> ProjectContext {
        let req = try TRPC.queryRequest(base: base, path: "projects.context", input: ProjectIdInput(projectId: projectId), token: token)
        return try await run(req, as: ProjectContext.self)
    }

    // Nudges

    public func listNudges() async throws -> [Nudge] {
        try await run(try TRPC.queryRequest(base: base, path: "nudges.list", token: token), as: [Nudge].self)
    }

    public struct NudgeMarkInput: Codable, Sendable {
        public let id: String
        /// "seen" or "dismissed".
        public let status: String
        public init(id: String, status: String) { self.id = id; self.status = status }
    }

    public func markNudge(id: String, status: String) async throws {
        let req = try TRPC.mutationRequest(base: base, path: "nudges.mark", input: NudgeMarkInput(id: id, status: status), token: token)
        _ = try await run(req, as: JSONValue.self)
    }
}
