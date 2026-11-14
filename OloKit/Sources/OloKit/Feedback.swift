import Foundation

/// A flag on one sentence of an answer: the verdict Zeus gave, what the reader says
/// it should be, and the passages it was checked against. Never the question, never
/// who asked. See docs/FEEDBACK.md: a reviewer confirms each flag before Zeus learns
/// from it.
public enum FeedbackRequest {
    public static let endpoint = URL(string: "https://bfldflbkebyapfagsxnr.supabase.co/functions/v1/olo-feedback")!

    /// The reader's choices, in the order the menu shows them.
    public static let userChoices: [(label: String, value: String)] = [
        ("Supported", "supported"),
        ("Contradicted", "contradicted"),
        ("Not covered", "not_covered"),
        ("Wrong source", "wrong_source"),
        ("Unclear", "unclear"),
    ]

    public struct PassageRef: Codable, Equatable, Sendable {
        public var url: String
        public var quote: String?
        public init(url: String, quote: String? = nil) { self.url = url; self.quote = quote }
    }

    public struct Body: Codable, Equatable, Sendable {
        public var client: String
        public var answerSource: String
        public var claim: String
        public var verdictGiven: String
        public var verdictUser: String
        public var passages: [PassageRef]
        public var note: String?

        enum CodingKeys: String, CodingKey {
            case client, claim, passages, note
            case answerSource = "answer_source"
            case verdictGiven = "verdict_given"
            case verdictUser = "verdict_user"
        }
    }

    /// The service's names for verdicts: the Mac says "unsupported" where it says "not_covered".
    public static func givenVerdict(_ verdict: String) -> String {
        switch verdict {
        case "supported": return "supported"
        case "contradicted": return "contradicted"
        default: return "not_covered"
        }
    }

    /// The passages a claim was checked against: its cited sources, with the excerpt as the quote.
    public static func passages(for claim: ClaimVerdict, sources: [Source]) -> [PassageRef] {
        let cited = sources.filter { claim.citedBy.contains($0.index) && !$0.url.isEmpty }
        let quote = claim.excerpt?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cited.map { PassageRef(url: $0.url, quote: (quote?.isEmpty ?? true) ? nil : quote) }
    }

    public static func body(answerSource: AnswerOrigin, claim: ClaimVerdict, sources: [Source], userVerdict: String, note: String?) -> Body {
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Body(client: "macos",
                    answerSource: answerSource.rawValue,
                    claim: String(claim.claim.prefix(600)),
                    verdictGiven: givenVerdict(claim.verdict),
                    verdictUser: userVerdict,
                    passages: passages(for: claim, sources: sources),
                    note: (trimmedNote?.isEmpty ?? true) ? nil : String(trimmedNote!.prefix(500)))
    }

    /// The POST to olo-feedback, ready to send.
    public static func build(answerSource: AnswerOrigin, claim: ClaimVerdict, sources: [Source], userVerdict: String, note: String?) throws -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        req.httpBody = try encoder.encode(body(answerSource: answerSource, claim: claim, sources: sources, userVerdict: userVerdict, note: note))
        return req
    }

    public static let sent = "Thanks, a reviewer will check it"
    public static let tooMany = "Too many flags for now"
    public static let failed = "Could not send the flag"

    /// What to tell the reader for a given HTTP status (0 when nothing came back).
    public static func message(forStatus status: Int) -> String {
        if (200..<300).contains(status) { return sent }
        if status == 429 { return tooMany }
        return failed
    }

    /// Sends the flag and returns the short note to show.
    public static func send(_ req: URLRequest, session: URLSession = .shared) async -> String {
        do {
            let (_, resp) = try await session.data(for: req)
            return message(forStatus: (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return failed
        }
    }
}
