import Foundation

/// A problem the server's screen found in a skill.
public struct SkillFlag: Codable, Equatable, Sendable {
    public var rule: String
    /// "block" or "review".
    public var severity: String
    public var excerpt: String

    public init(rule: String, severity: String, excerpt: String) { self.rule = rule; self.severity = severity; self.excerpt = excerpt }

    enum CodingKeys: String, CodingKey { case rule, severity, excerpt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rule = (try? c.decode(String.self, forKey: .rule)) ?? ""
        severity = (try? c.decode(String.self, forKey: .severity)) ?? "review"
        excerpt = (try? c.decode(String.self, forKey: .excerpt)) ?? ""
    }
}

/// A skill (server/skills.ts): a named playbook Olo applies when a request calls for
/// it. There is no on/off switch on the server: a skill is active, pending review,
/// quarantined or rejected, and the panel says which.
public struct Skill: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var instructions: String
    public var triggers: [String]
    /// "private" or "shared".
    public var visibility: String
    /// "active", "pending_review", "quarantined" or "rejected".
    public var status: String
    public var flags: [SkillFlag]
    public var uses: Int
    public var createdAt: String

    public init(id: String, name: String, description: String, instructions: String, triggers: [String] = [], visibility: String = "private",
                status: String = "active", flags: [SkillFlag] = [], uses: Int = 0, createdAt: String = "") {
        self.id = id; self.name = name; self.description = description; self.instructions = instructions; self.triggers = triggers
        self.visibility = visibility; self.status = status; self.flags = flags; self.uses = uses; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, name, description, instructions, triggers, visibility, status, flags, uses, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Skill"
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        instructions = (try? c.decode(String.self, forKey: .instructions)) ?? ""
        triggers = (try? c.decode([String].self, forKey: .triggers)) ?? []
        visibility = (try? c.decode(String.self, forKey: .visibility)) ?? "private"
        status = (try? c.decode(String.self, forKey: .status)) ?? "active"
        flags = (try? c.decode([SkillFlag].self, forKey: .flags)) ?? []
        uses = (try? c.decode(Int.self, forKey: .uses)) ?? 0
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
    }

    public var isActive: Bool { status == "active" }

    /// The status in plain words.
    public var statusLabel: String {
        switch status {
        case "active": return "Active"
        case "pending_review": return "Waiting for review"
        case "quarantined": return "Quarantined"
        case "rejected": return "Rejected"
        default: return status
        }
    }

    /// Limits the server enforces on a new skill.
    public static let nameRange = 2...60
    public static let descriptionRange = 4...240
    public static let instructionsRange = 10...4000
}

/// skills.create: the saved skill and a sentence saying what happened to it.
public struct SkillCreated: Codable, Equatable, Sendable {
    public var skill: Skill
    public var message: String

    public init(skill: Skill, message: String) { self.skill = skill; self.message = message }

    enum CodingKeys: String, CodingKey { case skill, message }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skill = try c.decode(Skill.self, forKey: .skill)
        message = (try? c.decode(String.self, forKey: .message)) ?? "Saved."
    }
}

// MARK: Server calls

extension OloAPI {
    public func listSkills() async throws -> [Skill] {
        try await run(try TRPC.queryRequest(base: base, path: "skills.list", token: token), as: [Skill].self)
    }

    public struct SkillCreateInput: Codable, Sendable {
        public var name: String
        public var description: String
        public var instructions: String
        public var triggers: [String]?
        public var visibility: String?
        public init(name: String, description: String, instructions: String, triggers: [String]? = nil, visibility: String? = nil) {
            self.name = name; self.description = description; self.instructions = instructions; self.triggers = triggers; self.visibility = visibility
        }
    }

    /// Saves a skill (skills.create). BAD_REQUEST carries the screen's reason.
    public func createSkill(_ input: SkillCreateInput) async throws -> SkillCreated {
        let req = try TRPC.mutationRequest(base: base, path: "skills.create", input: input, token: token)
        return try await run(req, as: SkillCreated.self)
    }

    public func deleteSkill(id: String) async throws {
        let req = try TRPC.mutationRequest(base: base, path: "skills.delete", input: IdInput(id: id), token: token)
        _ = try await run(req, as: JSONValue.self)
    }

    public struct SkillReportInput: Codable, Sendable {
        public let id: String
        public let reason: String
        public init(id: String, reason: String) { self.id = id; self.reason = reason }
    }

    public struct SentResult: Codable, Sendable { public var sent: Bool }

    /// Reports a skill to the research team (skills.report). True when the report went through.
    public func reportSkill(id: String, reason: String) async throws -> Bool {
        let req = try TRPC.mutationRequest(base: base, path: "skills.report", input: SkillReportInput(id: id, reason: reason), token: token)
        return try await run(req, as: SentResult.self).sent
    }
}
