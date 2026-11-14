import Foundation

/// The Olo brain: questions people chose to share, scrubbed of personal details,
/// shown as orbs on https://heliusnetwork.app/olo#brain. Only the question text
/// travels, never the answer, the name or the account. See the brain contract,
/// section 1 (olo-brain-ask) and section 3 (clients).
public enum BrainLinks {
    public static let view = URL(string: "https://heliusnetwork.app/olo#brain")!
}

/// The words the Mac shows about the brain and private chats, the same on every Olo app.
public enum BrainText {
    public static let cardTitle = "Add my questions to the Olo brain?"
    public static let cardBody = "Only the question text, scrubbed of personal details, appears as an orb in the public Olo brain. Never your answers, your name or your account. You can change this for any chat with the \"Add to Olo brain\" switch, and in Settings."
    public static let share = "Add them"
    public static let keepPrivate = "Keep private"
    public static let toggle = "Add to Olo brain"
    public static let privateChat = "Private chat"
    public static let privateExplainer = "Private chats are answered in the cloud but not saved there, not used for training and not added to the brain. The conversation is kept encrypted on this device only."
    public static let onlyOnThisMac = "Only on this Mac"
    public static let viewBrain = "View the Olo brain"

    /// The subtle note under an answer after the server (or olo-brain-ask) answered.
    public static func note(for status: String) -> String? {
        switch status {
        case "published": return "Your question was added to the Olo brain, without personal details."
        case "held": return "Your question is held for review before it can appear in the Olo brain."
        case "skipped": return "This question was not added to the Olo brain."
        default: return nil
        }
    }
}

/// Where the account's default stands: what auth.me said about brainSharing.
public enum BrainSharingState: Equatable, Sendable {
    /// The server said nothing about it (an older deployment): keep what the Mac knows.
    case unknown
    /// null: not asked yet, so the one-time card is shown.
    case notAsked
    case chosen(Bool)

    /// Reads brainSharing from auth.me's payload ({..., brainSharing}) or a nested user object.
    public static func read(_ value: JSONValue?) -> BrainSharingState {
        guard let value else { return .unknown }
        for candidate in [value, value["user"]] {
            guard case .object(let o)? = candidate, let field = o["brainSharing"] else { continue }
            switch field {
            case .bool(let b): return .chosen(b)
            case .null: return .notAsked
            default: return .unknown
            }
        }
        return .unknown
    }
}

/// olo-brain-ask, called directly when Olo Commons answered (the fallback path), since
/// helius-olo.io was not there to do it.
public enum BrainAsk {
    public static let endpoint = URL(string: "https://bfldflbkebyapfagsxnr.supabase.co/functions/v1/olo-brain-ask")!
    // No key: Olo Commons functions are deployed without JWT checks (deploy-functions.yml), and keys stay out of app code.

    public struct Body: Codable, Equatable, Sendable {
        public var question: String
        public var client: String
        public var atoms: [String]
        public var answered: Bool
    }

    public struct Result: Codable, Equatable, Sendable {
        public var status: String
        public var id: Int?
        public var reason: String?
    }

    /// The body as the function expects it: the question trimmed to 1..500 characters, at most 12 atom ids.
    /// nil when there is no question to send.
    public static func body(question: String, client: String = "macos", atoms: [String], answered: Bool) -> Body? {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        var seen = Set<String>()
        let ids = atoms.filter { !$0.isEmpty && seen.insert($0).inserted }
        return Body(question: String(q.prefix(500)), client: client, atoms: Array(ids.prefix(12)), answered: answered)
    }

    public static func request(_ body: Body) throws -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        req.httpBody = try encoder.encode(body)
        return req
    }

    /// Sends the question; nil on any failure (the answer is never affected).
    public static func send(_ body: Body, session: URLSession = .shared) async -> Result? {
        guard let req = try? request(body) else { return nil }
        guard let pair = try? await session.data(for: req) else { return nil }
        let (data, resp) = pair
        guard let status = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return nil }
        return try? JSONDecoder().decode(Result.self, from: data)
    }
}

/// A private chat is answered with nothing stored on the server, so the server sees only
/// the turn it is sent. The Mac carries a short summary of the earlier turns inside the
/// message so follow-up questions still make sense.
public enum PrivateContext {
    public static let budget = 6_000

    /// The content to send: the earlier turns (newest kept when trimming), then the new message.
    public static func compose(earlier turns: [(role: String, text: String)], content: String, budget: Int = PrivateContext.budget) -> String {
        let usable = turns.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return content }
        var lines: [String] = []
        var used = 0
        for t in usable.reversed() {
            let who = t.role == "user" ? "Me" : "Olo"
            var text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > 1_500 { text = String(text.prefix(1_500)) + " [...]" }
            let line = "\(who): \(text)"
            if used + line.count > budget { break }
            lines.insert(line, at: 0)
            used += line.count
        }
        guard !lines.isEmpty else { return content }
        return "--- Earlier in this private chat ---\n" + lines.joined(separator: "\n\n") + "\n--- End of earlier messages ---\n\n" + content
    }
}
