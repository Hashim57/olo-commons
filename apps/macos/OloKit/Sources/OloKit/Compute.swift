import Foundation

/// One stage of an analysis job.
public struct ComputeStage: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    /// "pending", "running", "done" or "failed".
    public var status: String
    public var detail: String?
    public var startedAt: String?
    public var finishedAt: String?

    public init(id: String, label: String, status: String = "pending", detail: String? = nil, startedAt: String? = nil, finishedAt: String? = nil) {
        self.id = id; self.label = label; self.status = status; self.detail = detail; self.startedAt = startedAt; self.finishedAt = finishedAt
    }

    enum CodingKeys: String, CodingKey { case id, label, status, detail, startedAt, finishedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        label = (try? c.decode(String.self, forKey: .label)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? "pending"
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        startedAt = try? c.decodeIfPresent(String.self, forKey: .startedAt)
        finishedAt = try? c.decodeIfPresent(String.self, forKey: .finishedAt)
    }
}

/// A heavy analysis run in the background (server/compute.ts): compute.start returns
/// at once with the job, and the client polls compute.get for progress.
public struct ComputeJob: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var conversationId: Int?
    public var prompt: String
    /// "queued", "running", "succeeded", "failed" or "cancelled".
    public var status: String
    /// 0 to 1 (the server also sends 0 to 100 on some rows; `fraction` reads either).
    public var progress: Double
    public var stages: [ComputeStage]
    public var result: String?
    public var error: String?
    public var cancelRequested: Bool
    public var createdAt: String
    public var updatedAt: String

    public init(id: String, conversationId: Int? = nil, prompt: String, status: String = "queued", progress: Double = 0, stages: [ComputeStage] = [],
                result: String? = nil, error: String? = nil, cancelRequested: Bool = false, createdAt: String = "", updatedAt: String = "") {
        self.id = id; self.conversationId = conversationId; self.prompt = prompt; self.status = status; self.progress = progress; self.stages = stages
        self.result = result; self.error = error; self.cancelRequested = cancelRequested; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case id, conversationId, prompt, status, progress, stages, result, error, cancelRequested, createdAt, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        conversationId = try? c.decodeIfPresent(Int.self, forKey: .conversationId)
        prompt = (try? c.decode(String.self, forKey: .prompt)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? "queued"
        progress = (try? c.decode(Double.self, forKey: .progress)) ?? 0
        stages = (try? c.decode([ComputeStage].self, forKey: .stages)) ?? []
        result = try? c.decodeIfPresent(String.self, forKey: .result)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        cancelRequested = (try? c.decode(Bool.self, forKey: .cancelRequested)) ?? false
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
        updatedAt = (try? c.decode(String.self, forKey: .updatedAt)) ?? createdAt
    }

    public var isFinished: Bool { status == "succeeded" || status == "failed" || status == "cancelled" }
    public var isRunning: Bool { status == "queued" || status == "running" }

    /// Progress as 0 to 1 whether the server sent a fraction or a percentage.
    public var fraction: Double {
        if progress > 1 { return min(1, progress / 100) }
        return max(0, progress)
    }

    /// "Running: reading sources" or "Succeeded".
    public var statusLine: String {
        let running = stages.first { $0.status == "running" }
        switch status {
        case "queued": return "Queued"
        case "running": return running.map { "Running: \($0.label)" } ?? "Running"
        case "succeeded": return "Finished"
        case "failed": return "Failed" + (error.map { ": \($0)" } ?? "")
        case "cancelled": return "Cancelled"
        default: return status
        }
    }
}

// MARK: Server calls

extension OloAPI {
    public struct ComputeStartInput: Codable, Sendable {
        public let prompt: String
        public var conversationId: Int?
        public init(prompt: String, conversationId: Int? = nil) { self.prompt = prompt; self.conversationId = conversationId }
    }

    /// Starts an analysis (compute.start). FORBIDDEN when the plan's analyses are used up.
    public func startCompute(prompt: String, conversationId: Int? = nil) async throws -> ComputeJob {
        let req = try TRPC.mutationRequest(base: base, path: "compute.start", input: ComputeStartInput(prompt: prompt, conversationId: conversationId), token: token)
        return try await run(req, as: ComputeJob.self)
    }

    public struct JobIdInput: Codable, Sendable {
        public let jobId: String
        public init(jobId: String) { self.jobId = jobId }
    }

    public func computeJob(id: String) async throws -> ComputeJob {
        let req = try TRPC.queryRequest(base: base, path: "compute.get", input: JobIdInput(jobId: id), token: token)
        return try await run(req, as: ComputeJob.self)
    }

    public func listComputeJobs() async throws -> [ComputeJob] {
        try await run(try TRPC.queryRequest(base: base, path: "compute.list", token: token), as: [ComputeJob].self)
    }

    public func cancelCompute(id: String) async throws {
        let req = try TRPC.mutationRequest(base: base, path: "compute.cancel", input: JobIdInput(jobId: id), token: token)
        _ = try await run(req, as: JSONValue.self)
    }
}
