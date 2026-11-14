import Foundation

/// An email Olo drafted in an answer, ready to hand to the phone's own mail composer. Olo never
/// sends mail: the person reads the draft in Mail and presses Send themselves.
public struct MailDraft: Equatable, Sendable {
    public var to: [String]
    public var subject: String
    public var body: String

    public init(to: [String] = [], subject: String = "", body: String) {
        self.to = to; self.subject = subject; self.body = body
    }

    /// The value after "Subject:" or "To:" at the start of a line, with Markdown bold removed.
    static func field(_ name: String, in line: String) -> String? {
        let plain = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").trimmingCharacters(in: .whitespaces)
        let prefix = name.lowercased() + ":"
        guard plain.lowercased().hasPrefix(prefix) else { return nil }
        return String(plain.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Addresses in a "To:" value: anything with an @ and a dot after it, without brackets or commas.
    static func addresses(in value: String) -> [String] {
        value.split(whereSeparator: { ",; <>()[]".contains($0) }).map(String.init).filter { part in
            guard let at = part.firstIndex(of: "@") else { return false }
            return part[at...].contains(".") && part.first != "@"
        }
    }

    /// Reads a draft out of an answer. With a "Subject:" line, the body is what follows it (a
    /// lead-in such as "Here is a draft:" is left out); without one, the whole answer is the body.
    public static func parse(_ text: String) -> MailDraft {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // A draft wrapped in a code fence is still a draft.
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        var to: [String] = []
        var subject = ""
        var bodyStart = 0
        var found = false
        for (i, line) in lines.enumerated() {
            if let value = field("To", in: line), to.isEmpty {
                to = addresses(in: value)
                if !to.isEmpty { bodyStart = max(bodyStart, i + 1) }
            }
            if let value = field("Subject", in: line) {
                subject = value
                bodyStart = max(bodyStart, i + 1)
                found = true
                break
            }
        }
        let kept = found ? Array(lines[bodyStart...]) : lines
        let body = kept.joined(separator: "\n")
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MailDraft(to: found ? to : [], subject: subject, body: body)
    }

    /// A mailto: link for phones with no mail account set up in Mail.
    public var mailtoURL: URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = to.joined(separator: ",")
        var items: [URLQueryItem] = []
        if !subject.isEmpty { items.append(URLQueryItem(name: "subject", value: subject)) }
        if !body.isEmpty { items.append(URLQueryItem(name: "body", value: String(body.prefix(6000)))) }
        c.queryItems = items.isEmpty ? nil : items
        // Mail reads "+" as a space unless it is escaped.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url
    }
}
