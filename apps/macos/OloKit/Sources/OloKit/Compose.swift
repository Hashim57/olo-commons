import Foundation

/// Text from a file, a selection or a folder search that goes with a question.
public struct Attachment: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, selection, folderPassage }
    public var id: UUID
    public var kind: Kind
    public var name: String
    public var text: String

    public init(kind: Kind, name: String, text: String, id: UUID = UUID()) {
        self.id = id; self.kind = kind; self.name = name; self.text = text
    }
}

/// Builds the message helius-olo.io receives. Attached text goes before the
/// question in clearly fenced blocks, trimmed to a budget so a large PDF never
/// becomes an enormous, slow or expensive request.
public enum MessageComposer {
    public static let totalBudget = 60_000
    public static let perAttachmentBudget = 30_000

    public static func compose(question: String, attachments: [Attachment]) -> (content: String, trimmed: [String]) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attachments.isEmpty else { return (q, []) }
        var blocks: [String] = []
        var trimmed: [String] = []
        var remaining = totalBudget
        for a in attachments {
            guard remaining > 200 else { trimmed.append(a.name); continue }
            let limit = min(perAttachmentBudget, remaining)
            var body = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.count > limit {
                body = String(body.prefix(limit)) + "\n[... the rest of \(a.name) was left out to keep the question short ...]"
                trimmed.append(a.name)
            }
            remaining -= body.count
            let label: String
            switch a.kind {
            case .selection: label = "Selected text"
            case .file: label = "Attached: \(a.name)"
            case .folderPassage: label = "From my files: \(a.name)"
            }
            blocks.append("--- \(label) ---\n\(body)\n--- End of \(a.kind == .selection ? "selected text" : a.name) ---")
        }
        let question = q.isEmpty ? "Explain this." : q
        return (blocks.joined(separator: "\n\n") + "\n\n" + question, trimmed)
    }
}

/// Which links stay in Olo and which open in your browser.
public enum LinkPolicy {
    public static let apiHosts: Set<String> = ["helius-olo.io", "www.helius-olo.io"]

    /// Only web and mail links are ever opened; anything else (file:, javascript:, custom schemes) is refused.
    public static func isSafeExternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http" || scheme == "mailto"
    }

    /// olo://ask?q=... opens Quick Ask with the question; olo://chat/42 opens a conversation.
    public enum DeepLink: Equatable { case ask(String); case conversation(Int); case home }

    public static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == "olo" else { return nil }
        let host = url.host?.lowercased() ?? ""
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch host {
        case "ask":
            let q = comps?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
            return .ask(String(q.prefix(4000)))
        case "chat", "conversation":
            if let id = Int(url.lastPathComponent) { return .conversation(id) }
            return .home
        default:
            return .home
        }
    }
}

/// Questions asked with no connection, kept until Olo can answer them properly.
public struct PendingQuestion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var question: String
    public var content: String
    public var askedAt: Date
    public var localConversation: UUID

    public init(question: String, content: String, localConversation: UUID, askedAt: Date = Date(), id: UUID = UUID()) {
        self.id = id; self.question = question; self.content = content; self.askedAt = askedAt; self.localConversation = localConversation
    }
}

/// Where an answer came from, shown under it so nobody mistakes one kind for another.
public enum AnswerOrigin: String, Codable, Sendable {
    /// helius-olo.io: written by cloud models, sentences checked by Zeus.
    case olo
    /// Olo Commons' own service, when helius-olo.io was unreachable.
    case commons
    /// No connection: quoted from what is saved on this Mac, unchecked.
    case offline

    public var label: String {
        switch self {
        case .olo: return "Answered by Olo"
        case .commons: return "Answered by Olo Commons (helius-olo.io was unreachable)"
        case .offline: return "Offline: quoted from sources saved on this Mac, not checked yet"
        }
    }
}
