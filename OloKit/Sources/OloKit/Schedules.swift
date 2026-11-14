import Foundation

/// A scheduled task (olo-web server/schedules.ts): a question Olo asks on a schedule, in the
/// person's own time zone, answered and checked like a typed one, kept in one conversation,
/// and announced by a nudge, a push and (if chosen) an email. Same procedures as the web.
public struct ScheduledTask: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var title: String
    public var prompt: String
    /// "daily", "weekdays" or "weekly".
    public var cadence: String
    public var hour: Int
    public var minute: Int
    /// 0 Sunday to 6 Saturday; weekly only.
    public var weekday: Int?
    public var timeZone: String
    public var grounded: Bool
    public var email: Bool
    public var enabled: Bool
    public var conversationId: Int?
    public var nextRunAt: String
    public var lastRunAt: String?
    /// "ok", "quota" or "error".
    public var lastStatus: String?
    public var lastSummary: String?
    public var runs: Int
    /// The server's own wording, "Weekdays at 08:00".
    public var label: String

    public init(id: Int, title: String, prompt: String, cadence: String = "daily", hour: Int = 8, minute: Int = 0, weekday: Int? = nil,
                timeZone: String = "UTC", grounded: Bool = true, email: Bool = false, enabled: Bool = true, conversationId: Int? = nil,
                nextRunAt: String = "", lastRunAt: String? = nil, lastStatus: String? = nil, lastSummary: String? = nil, runs: Int = 0, label: String = "") {
        self.id = id; self.title = title; self.prompt = prompt; self.cadence = cadence; self.hour = hour; self.minute = minute
        self.weekday = weekday; self.timeZone = timeZone; self.grounded = grounded; self.email = email; self.enabled = enabled
        self.conversationId = conversationId; self.nextRunAt = nextRunAt; self.lastRunAt = lastRunAt; self.lastStatus = lastStatus
        self.lastSummary = lastSummary; self.runs = runs; self.label = label
    }

    enum CodingKeys: String, CodingKey {
        case id, title, prompt, cadence, hour, minute, weekday, timeZone, grounded, email, enabled, conversationId
        case nextRunAt, lastRunAt, lastStatus, lastSummary, runs, label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        prompt = (try? c.decode(String.self, forKey: .prompt)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? prompt
        cadence = (try? c.decode(String.self, forKey: .cadence)) ?? "daily"
        hour = (try? c.decode(Int.self, forKey: .hour)) ?? 8
        minute = (try? c.decode(Int.self, forKey: .minute)) ?? 0
        weekday = try? c.decodeIfPresent(Int.self, forKey: .weekday)
        timeZone = (try? c.decode(String.self, forKey: .timeZone)) ?? "UTC"
        grounded = (try? c.decode(Bool.self, forKey: .grounded)) ?? true
        email = (try? c.decode(Bool.self, forKey: .email)) ?? false
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        conversationId = try? c.decodeIfPresent(Int.self, forKey: .conversationId)
        nextRunAt = (try? c.decode(String.self, forKey: .nextRunAt)) ?? ""
        lastRunAt = try? c.decodeIfPresent(String.self, forKey: .lastRunAt)
        lastStatus = try? c.decodeIfPresent(String.self, forKey: .lastStatus)
        lastSummary = try? c.decodeIfPresent(String.self, forKey: .lastSummary)
        runs = (try? c.decode(Int.self, forKey: .runs)) ?? 0
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
    }

    /// The schedule in words, when the server did not send its own.
    public var scheduleLine: String {
        if !label.isEmpty { return label }
        let time = String(format: "%02d:%02d", hour, minute)
        let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        switch cadence {
        case "weekdays": return "Weekdays at \(time)"
        case "weekly": return "\(days[max(0, min(6, weekday ?? 1))])s at \(time)"
        default: return "Every day at \(time)"
        }
    }

    /// What the last run left, in words: the summary, or why it did not run.
    public var lastLine: String? {
        guard let summary = lastSummary, !summary.isEmpty else { return nil }
        switch lastStatus {
        case "quota": return "Not run: message allowance used. \(summary)"
        case "error": return "Last run failed: \(summary)"
        default: return summary
        }
    }
}

/// What a new scheduled task asks for.
public struct ScheduleInput: Codable, Equatable, Sendable {
    public var prompt: String
    public var cadence: String
    public var hour: Int
    public var minute: Int
    public var weekday: Int?
    public var timeZone: String
    public var email: Bool

    public init(prompt: String, cadence: String, hour: Int, minute: Int, weekday: Int? = nil, timeZone: String = TimeZone.current.identifier, email: Bool = false) {
        self.prompt = prompt; self.cadence = cadence; self.hour = hour; self.minute = minute
        self.weekday = cadence == "weekly" ? weekday : nil; self.timeZone = timeZone; self.email = email
    }
}

// MARK: Server calls

extension OloAPI {
    public func listSchedules() async throws -> [ScheduledTask] {
        try await run(try TRPC.queryRequest(base: base, path: "schedules.list", token: token), as: [ScheduledTask].self)
    }

    public func createSchedule(_ input: ScheduleInput) async throws -> ScheduledTask {
        try await run(try TRPC.mutationRequest(base: base, path: "schedules.create", input: input, token: token), as: ScheduledTask.self)
    }

    public struct ScheduleUpdate: Codable, Sendable {
        public var id: Int
        public var enabled: Bool?
        public var email: Bool?
        public init(id: Int, enabled: Bool? = nil, email: Bool? = nil) { self.id = id; self.enabled = enabled; self.email = email }
    }

    public func updateSchedule(_ update: ScheduleUpdate) async throws -> ScheduledTask {
        try await run(try TRPC.mutationRequest(base: base, path: "schedules.update", input: update, token: token), as: ScheduledTask.self)
    }

    public struct ScheduleId: Codable, Sendable {
        public var id: Int
        public init(id: Int) { self.id = id }
    }

    public func deleteSchedule(id: Int) async throws {
        _ = try await run(try TRPC.mutationRequest(base: base, path: "schedules.delete", input: ScheduleId(id: id), token: token), as: JSONValue.self)
    }

    /// Due at once; the server's runner answers it within a minute or two.
    public func runScheduleNow(id: Int) async throws {
        _ = try await run(try TRPC.mutationRequest(base: base, path: "schedules.runNow", input: ScheduleId(id: id), token: token), as: JSONValue.self)
    }

    public struct SuggestionInput: Codable, Sendable {
        public var text: String
        public var client: String
        public init(text: String, client: String = "macos") { self.text = text; self.client = client }
    }

    /// "Send a suggestion" in Settings: emailed to the Olo team (feedback.suggest).
    public func sendSuggestion(_ text: String) async throws {
        _ = try await run(try TRPC.mutationRequest(base: base, path: "feedback.suggest", input: SuggestionInput(text: text), token: token), as: JSONValue.self)
    }
}
