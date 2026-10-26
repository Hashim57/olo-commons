import Foundation

// Build with Olo v2: Olo writes code with you. code.edit rewrites a file (or the selected lines)
// to follow an instruction; code.complete suggests the text at the cursor; code.allowance tells
// how much of the day's Build allowance is left. Like code.review, nothing sent here is stored
// on the server, logged beyond errors, used for training or added to the brain.

/// The lines code.edit may change (1-based, inclusive).
public struct CodeEditSelection: Codable, Equatable, Sendable {
    public var startLine: Int
    public var endLine: Int

    public init(startLine: Int, endLine: Int) {
        self.startLine = max(1, startLine)
        self.endLine = max(self.startLine, endLine)
    }
}

/// code.edit's input, trimmed to the server's limits.
public struct CodeEditInput: Codable, Equatable, Sendable {
    public static let maxInstruction = 2_000
    public var path: String
    public var language: String
    public var content: String
    public var instruction: String
    public var selection: CodeEditSelection?

    public init(path: String, content: String, instruction: String, selection: CodeEditSelection? = nil, language: String? = nil) {
        self.path = String(path.suffix(300))
        self.language = String((language ?? CodeLanguage.detect(path)).prefix(40))
        self.content = String(content.prefix(CodeReviewInput.maxContent))
        self.instruction = String(instruction.trimmingCharacters(in: .whitespacesAndNewlines).prefix(CodeEditInput.maxInstruction))
        self.selection = selection
    }

    /// code.edit answers with the whole file, so a file over the limit cannot be sent cut short.
    public static func fits(_ content: String) -> Bool { content.count <= CodeReviewInput.maxContent }
}

public struct CodeEditResult: Codable, Equatable, Sendable {
    /// The whole new file.
    public var content: String
    public var explanation: String
    public var model: String

    public init(content: String, explanation: String = "", model: String = "") {
        self.content = content; self.explanation = explanation; self.model = model
    }

    enum CodingKeys: String, CodingKey { case content, explanation, model }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decode(String.self, forKey: .content)
        explanation = (try? c.decode(String.self, forKey: .explanation)) ?? ""
        model = (try? c.decode(String.self, forKey: .model)) ?? ""
    }
}

/// code.complete's input: the text around the cursor, trimmed to the server's limits (the end of
/// the prefix and the start of the suffix are the parts that matter, so those are kept).
public struct CodeCompleteInput: Codable, Equatable, Sendable {
    public static let maxPrefix = 8_000
    public static let maxSuffix = 4_000
    public var language: String
    public var path: String
    public var prefix: String
    public var suffix: String

    public init(path: String, prefix: String, suffix: String, language: String? = nil) {
        self.path = String(path.suffix(300))
        self.language = String((language ?? CodeLanguage.detect(path)).prefix(40))
        self.prefix = String(prefix.suffix(CodeCompleteInput.maxPrefix))
        self.suffix = String(suffix.prefix(CodeCompleteInput.maxSuffix))
    }
}

public struct CodeCompleteResult: Codable, Equatable, Sendable {
    public var completion: String
    public var model: String

    public init(completion: String, model: String = "") {
        self.completion = completion; self.model = model
    }

    enum CodingKeys: String, CodingKey { case completion, model }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        completion = (try? c.decode(String.self, forKey: .completion)) ?? ""
        model = (try? c.decode(String.self, forKey: .model)) ?? ""
    }
}

/// What is left of today's Build with Olo allowance (code.allowance). The server's exact shape is
/// read tolerantly: { reviews: { used, limit } } or flat { reviewsUsed, reviewsLimit }, { used, limit }
/// or { remaining, limit }, and the same for completions.
public struct BuildAllowance: Equatable, Sendable {
    /// Reviews and edits.
    public var used: Int?
    public var limit: Int?
    public var completionsUsed: Int?
    public var completionsLimit: Int?

    public init(used: Int? = nil, limit: Int? = nil, completionsUsed: Int? = nil, completionsLimit: Int? = nil) {
        self.used = used; self.limit = limit; self.completionsUsed = completionsUsed; self.completionsLimit = completionsLimit
    }

    static func number(_ value: JSONValue?, _ keys: [String]) -> Int? {
        guard let value else { return nil }
        for k in keys {
            if let n = value[k]?.intValue { return n }
        }
        return nil
    }

    /// (used, limit) from an object with used/limit or remaining/limit.
    static func pair(_ value: JSONValue?, usedKeys: [String], limitKeys: [String], remainingKeys: [String]) -> (Int?, Int?) {
        let limit = number(value, limitKeys)
        if let used = number(value, usedKeys) { return (used, limit) }
        if let remaining = number(value, remainingKeys), let limit { return (max(0, limit - remaining), limit) }
        return (nil, limit)
    }

    /// Nil when the value says nothing about an allowance.
    public static func read(_ value: JSONValue) -> BuildAllowance? {
        var a = BuildAllowance()
        if let nested = value["reviews"] ?? value["build"] {
            (a.used, a.limit) = pair(nested, usedKeys: ["used"], limitKeys: ["limit", "max"], remainingKeys: ["remaining", "left"])
        } else {
            (a.used, a.limit) = pair(value, usedKeys: ["reviewsUsed", "used"], limitKeys: ["reviewsLimit", "limit"], remainingKeys: ["reviewsRemaining", "reviewsLeft", "remaining"])
        }
        if let nested = value["completions"] {
            (a.completionsUsed, a.completionsLimit) = pair(nested, usedKeys: ["used"], limitKeys: ["limit", "max"], remainingKeys: ["remaining", "left"])
        } else {
            (a.completionsUsed, a.completionsLimit) = pair(value, usedKeys: ["completionsUsed"], limitKeys: ["completionsLimit"], remainingKeys: ["completionsRemaining", "completionsLeft"])
        }
        if a.limit == nil && a.completionsLimit == nil { return nil }
        return a
    }

    /// For the status line, for example "Build: 48 of 60 left today".
    public var summary: String? {
        var parts: [String] = []
        if let limit {
            let left = max(0, limit - (used ?? 0))
            parts.append("\(left) of \(limit) reviews and edits left today")
        }
        if let completionsLimit {
            let left = max(0, completionsLimit - (completionsUsed ?? 0))
            parts.append("\(left) of \(completionsLimit) suggestions")
        }
        return parts.isEmpty ? nil : "Build: " + parts.joined(separator: ", ")
    }
}

/// Tidies a completion before it is shown as ghost text: no Markdown fences, no repeat of what is
/// already typed on the line, no repeat of the text that follows the cursor, at most 30 lines.
public enum CompletionCleanup {
    public static let maxLines = 30

    public static func clean(_ raw: String, prefix: String, suffix: String) -> String {
        var text = stripFences(raw.replacingOccurrences(of: "\r\n", with: "\n"))

        // The model sometimes starts by repeating the line typed so far.
        let currentLine = lastLine(of: prefix)
        let typed = String(currentLine.drop(while: { $0 == " " || $0 == "\t" }))
        if !currentLine.isEmpty && text.hasPrefix(currentLine) {
            text = String(text.dropFirst(currentLine.count))
        } else if !typed.isEmpty && text.hasPrefix(typed) {
            text = String(text.dropFirst(typed.count))
        }

        var lines = text.components(separatedBy: "\n")

        // The end of the completion repeating the lines that already follow the cursor.
        let suffixLines = suffix.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let restOfLine = trim(suffixLines.first ?? "")
        let following = Array(suffixLines.dropFirst().map(trim).drop(while: { $0.isEmpty }))
        var k = min(lines.count, following.count)
        while k > 0 {
            let tail = lines.suffix(k).map(trim)
            if tail == Array(following.prefix(k)) && tail.contains(where: { !$0.isEmpty }) {
                lines.removeLast(k)
                break
            }
            k -= 1
        }

        // The last line ending with what is already after the cursor on this line.
        if !restOfLine.isEmpty, let last = lines.last, trim(last).hasSuffix(restOfLine) {
            let kept = trimTrailing(last)
            lines[lines.count - 1] = String(kept.dropLast(restOfLine.count))
        }

        if lines.count > maxLines { lines = Array(lines.prefix(maxLines)) }
        let joined = trimTrailing(lines.joined(separator: "\n"))
        return joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : joined
    }

    static func stripFences(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return text }
        var lines = trimmed.components(separatedBy: "\n")
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    static func lastLine(of text: String) -> String {
        guard let r = text.range(of: "\n", options: .backwards) else { return text }
        return String(text[r.upperBound...])
    }

    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

    static func trimTrailing(_ s: String) -> String {
        var out = Substring(s)
        while let c = out.last, c == " " || c == "\t" || c == "\n" || c == "\r" { out.removeLast() }
        return String(out)
    }
}

extension TRPC.RemoteError {
    /// The day's Build with Olo allowance is used up (TOO_MANY_REQUESTS), or the rate limit was hit.
    public var isAllowanceExhausted: Bool { code == "TOO_MANY_REQUESTS" || httpStatus == 429 }
}

extension OloAPI {
    /// Olo rewrites the file, or only the selected lines, to do what the instruction asks (code.edit).
    public func editCode(_ input: CodeEditInput) async throws -> CodeEditResult {
        var r = try TRPC.mutationRequest(base: base, path: "code.edit", input: input, token: token)
        r.timeoutInterval = 120
        return try await run(r, as: CodeEditResult.self)
    }

    /// The text to insert at the cursor (code.complete). The server answers within about 3 seconds
    /// or with an empty completion.
    public func completeCode(_ input: CodeCompleteInput) async throws -> CodeCompleteResult {
        var r = try TRPC.mutationRequest(base: base, path: "code.complete", input: input, token: token)
        r.timeoutInterval = 8
        return try await run(r, as: CodeCompleteResult.self)
    }

    /// Today's Build with Olo allowance (code.allowance), nil when the answer has no numbers.
    public func buildAllowance() async throws -> BuildAllowance? {
        let value = try await run(try TRPC.queryRequest(base: base, path: "code.allowance", token: token), as: JSONValue.self)
        return BuildAllowance.read(value)
    }
}
