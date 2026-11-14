import Foundation

// Build with Olo: the Mac watches a project folder, and each saved source file is
// reviewed by helius-olo.io (code.review). Code is never stored there, never logged
// beyond errors, never sent to the brain or to training. Everything in this file is
// pure: models, the request, and applying fixes to an array of lines.

/// A suggested change: lines startLine..endLine (1-based, inclusive) become `replacement`
/// (several lines, or empty to delete them). startLine one past the last line inserts at the end;
/// endLine below startLine inserts before startLine.
public struct CodeFix: Codable, Equatable, Hashable, Sendable {
    public var startLine: Int
    public var endLine: Int
    public var replacement: String

    public init(startLine: Int, endLine: Int, replacement: String) {
        self.startLine = startLine; self.endLine = endLine; self.replacement = replacement
    }

    enum CodingKeys: String, CodingKey { case startLine, endLine, replacement }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startLine = try c.decode(Int.self, forKey: .startLine)
        endLine = (try? c.decode(Int.self, forKey: .endLine)) ?? startLine
        replacement = (try? c.decode(String.self, forKey: .replacement)) ?? ""
    }
}

public struct CodeIssue: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var line: Int
    public var endLine: Int
    /// "error", "warning" or "info".
    public var severity: String
    /// "bug", "security", "performance", "style" or "correctness".
    public var category: String
    public var message: String
    public var fix: CodeFix?

    public init(id: String, line: Int, endLine: Int? = nil, severity: String, category: String, message: String, fix: CodeFix? = nil) {
        self.id = id; self.line = line; self.endLine = max(line, endLine ?? line); self.severity = severity
        self.category = category; self.message = message; self.fix = fix
    }

    enum CodingKeys: String, CodingKey { case id, line, endLine, severity, category, message, fix }

    /// Tolerant: a missing id, endLine, severity or category takes a sensible default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        line = max(1, (try? c.decode(Int.self, forKey: .line)) ?? 1)
        endLine = max(line, (try? c.decode(Int.self, forKey: .endLine)) ?? line)
        let sev = ((try? c.decode(String.self, forKey: .severity)) ?? "info").lowercased()
        severity = ["error", "warning", "info"].contains(sev) ? sev : "info"
        category = ((try? c.decode(String.self, forKey: .category)) ?? "correctness").lowercased()
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
        fix = try? c.decodeIfPresent(CodeFix.self, forKey: .fix)
        id = (try? c.decode(String.self, forKey: .id)) ?? "\(line)-\(category)-\(message.prefix(40))"
    }

    /// Safe to apply in bulk ("Apply all safe fixes"): informational or style only.
    public var isSafe: Bool { fix != nil && (severity == "info" || category == "style") }

    /// What "Fix as I save" may apply by itself (after the countdown): errors that are bugs or security holes.
    public var autoFixable: Bool { fix != nil && severity == "error" && (category == "bug" || category == "security") }

    /// Lower sorts first: errors, then warnings, then information.
    public var severityRank: Int {
        switch severity { case "error": return 0; case "warning": return 1; default: return 2 }
    }
}

public struct CodeReviewResult: Codable, Equatable, Sendable {
    public var issues: [CodeIssue]
    public var summary: String
    public var model: String

    public init(issues: [CodeIssue], summary: String = "", model: String = "") {
        self.issues = issues; self.summary = summary; self.model = model
    }

    enum CodingKeys: String, CodingKey { case issues, summary, model }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        issues = (try? c.decode([CodeIssue].self, forKey: .issues)) ?? []
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        model = (try? c.decode(String.self, forKey: .model)) ?? ""
    }

    /// Issues sorted the way the pane lists them: by line, errors first on the same line.
    public var sorted: [CodeIssue] {
        issues.sorted { ($0.line, $0.severityRank) < ($1.line, $1.severityRank) }
    }
}

/// code.review's input, trimmed to the server's limits.
public struct CodeReviewInput: Codable, Equatable, Sendable {
    public static let maxContent = 60_000
    public var path: String
    public var language: String
    public var content: String
    public var previous: String?
    public var focus: String?

    public init(path: String, content: String, previous: String? = nil, focus: String? = nil, language: String? = nil) {
        self.path = String(path.suffix(300))
        self.language = String((language ?? CodeLanguage.detect(path)).prefix(40))
        self.content = String(content.prefix(CodeReviewInput.maxContent))
        // The previous version is only context: left out when it would not fit whole.
        if let previous, previous.count <= CodeReviewInput.maxContent, previous != content { self.previous = previous } else { self.previous = nil }
        if let focus, ["all", "security", "bugs"].contains(focus) { self.focus = focus } else { self.focus = nil }
    }
}

/// The language name sent with a review, from the file name.
public enum CodeLanguage {
    static let byExtension: [String: String] = [
        "swift": "swift", "m": "objective-c", "mm": "objective-cpp", "h": "c", "hpp": "cpp", "c": "c", "cc": "cpp", "cpp": "cpp", "cxx": "cpp",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript", "ts": "typescript", "tsx": "typescript", "mts": "typescript",
        "py": "python", "rb": "ruby", "go": "go", "rs": "rust", "java": "java", "kt": "kotlin", "kts": "kotlin", "scala": "scala",
        "cs": "csharp", "fs": "fsharp", "php": "php", "pl": "perl", "lua": "lua", "dart": "dart", "ex": "elixir", "exs": "elixir", "erl": "erlang",
        "hs": "haskell", "clj": "clojure", "r": "r", "jl": "julia", "zig": "zig", "nim": "nim", "sol": "solidity", "move": "move", "vy": "vyper",
        "sh": "shell", "bash": "shell", "zsh": "shell", "fish": "shell", "ps1": "powershell",
        "sql": "sql", "html": "html", "htm": "html", "css": "css", "scss": "scss", "sass": "sass", "less": "less", "vue": "vue", "svelte": "svelte",
        "json": "json", "yaml": "yaml", "yml": "yaml", "toml": "toml", "xml": "xml", "gradle": "groovy", "groovy": "groovy",
        "tf": "terraform", "hcl": "hcl", "proto": "protobuf", "graphql": "graphql", "gql": "graphql", "md": "markdown",
    ]
    static let byName: [String: String] = ["dockerfile": "dockerfile", "makefile": "makefile", "podfile": "ruby", "gemfile": "ruby", "package.swift": "swift"]

    public static func detect(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        if let n = byName[name] { return n }
        let ext = (name as NSString).pathExtension
        return byExtension[ext] ?? "text"
    }

    /// Whether Build with Olo reviews this file at all: a known source or config language.
    public static func isReviewable(_ path: String) -> Bool { detect(path) != "text" }
}

/// A file's text as lines, remembering its line ending and whether it ended with one, so a
/// fix changes only the lines it names.
public struct SourceText: Equatable, Sendable {
    public var lines: [String]
    public var lineEnding: String
    public var trailingNewline: Bool

    public init(_ text: String) {
        lineEnding = text.contains("\r\n") ? "\r\n" : "\n"
        var parts = text.components(separatedBy: lineEnding)
        if parts.count > 1, parts.last == "" { parts.removeLast(); trailingNewline = true } else { trailingNewline = false }
        if text.isEmpty { parts = [] }
        lines = parts
    }

    public init(lines: [String], lineEnding: String = "\n", trailingNewline: Bool = true) {
        self.lines = lines; self.lineEnding = lineEnding; self.trailingNewline = trailingNewline
    }

    public var text: String {
        lines.joined(separator: lineEnding) + (trailingNewline && !lines.isEmpty ? lineEnding : "")
    }
}

/// Applying fixes: pure functions on [String] lines.
public enum FixApplier {
    public enum Failure: Error, Equatable, LocalizedError {
        case overlapping
        public var errorDescription: String? { "These fixes change the same lines, so they cannot be applied together." }
    }

    /// The fix's range on a file of `count` lines, clamped: lower is the first line replaced (1-based),
    /// upper the last; upper == lower - 1 means an insertion before `lower`.
    public static func clampedRange(_ fix: CodeFix, count: Int) -> (lower: Int, upper: Int) {
        let lower = min(max(fix.startLine, 1), count + 1)
        let upper = min(max(fix.endLine, lower - 1), count)
        return (lower, upper)
    }

    /// The replacement as lines: empty text deletes; one trailing newline does not add a blank line.
    public static func replacementLines(_ replacement: String) -> [String] {
        if replacement.isEmpty { return [] }
        let normalised = replacement.replacingOccurrences(of: "\r\n", with: "\n")
        var parts = normalised.components(separatedBy: "\n")
        if parts.count > 1, parts.last == "" { parts.removeLast() }
        return parts
    }

    /// Lines after one fix. Out of range line numbers are clamped to the file.
    public static func apply(_ fix: CodeFix, to lines: [String]) -> [String] {
        let r = clampedRange(fix, count: lines.count)
        var out = lines
        out.replaceSubrange((r.lower - 1)..<r.upper, with: replacementLines(fix.replacement))
        return out
    }

    /// Whether any two fixes touch the same line (after clamping). Two insertions at the same
    /// place also count, since their order would be a guess.
    public static func overlaps(_ fixes: [CodeFix], count: Int) -> Bool {
        let ranges = fixes.map { clampedRange($0, count: count) }.sorted { ($0.lower, $0.upper) < ($1.lower, $1.upper) }
        guard ranges.count > 1 else { return false }
        for i in 1..<ranges.count {
            let prev = ranges[i - 1], next = ranges[i]
            if next.lower <= prev.upper { return true }
            let prevInsert = prev.upper < prev.lower, nextInsert = next.upper < next.lower
            if prevInsert && nextInsert && prev.lower == next.lower { return true }
            // An insertion before a line that the previous fix replaces.
            if nextInsert && next.lower <= prev.upper { return true }
        }
        return false
    }

    /// Lines after several fixes, all against the same original lines. Overlapping fixes are rejected.
    public static func applyAll(_ fixes: [CodeFix], to lines: [String]) throws -> [String] {
        if overlaps(fixes, count: lines.count) { throw Failure.overlapping }
        // Bottom up, so the line numbers of the fixes above stay valid. On the same first line the
        // replacement goes before the insertion, so the insertion still lands before that line.
        let n = lines.count
        let ordered = fixes.sorted { a, b in
            let ra = clampedRange(a, count: n), rb = clampedRange(b, count: n)
            return (ra.lower, ra.upper) > (rb.lower, rb.upper)
        }
        var out = lines
        for f in ordered { out = apply(f, to: out) }
        return out
    }

    /// The largest set of fixes, taken top to bottom, that do not overlap.
    public static func nonOverlapping(_ fixes: [CodeFix], count: Int) -> [CodeFix] {
        let ordered = fixes.sorted { clampedRange($0, count: count).lower < clampedRange($1, count: count).lower }
        var kept: [CodeFix] = []
        for f in ordered where !overlaps(kept + [f], count: count) { kept.append(f) }
        return kept
    }

    /// The other issues after `fix` was applied to a file that had `count` lines: those touching the
    /// replaced lines are dropped (their review no longer fits), those below move by the change in length.
    public static func rebase(_ issues: [CodeIssue], after fix: CodeFix, count: Int) -> [CodeIssue] {
        let r = clampedRange(fix, count: count)
        let removed = max(0, r.upper - r.lower + 1)
        let delta = replacementLines(fix.replacement).count - removed
        return issues.compactMap { issue -> CodeIssue? in
            let ownFix = issue.fix.map { clampedRange($0, count: count) }
            let lo = min(issue.line, ownFix?.lower ?? issue.line)
            let hi = max(issue.endLine, ownFix?.upper ?? issue.endLine)
            if removed > 0 {
                if hi >= r.lower && lo <= r.upper { return nil }
                if lo < r.lower { return issue }
            } else {
                // An insertion before r.lower: an issue spanning that point no longer fits.
                if lo < r.lower && hi >= r.lower { return nil }
                if lo < r.lower { return issue }
            }
            var moved = issue
            moved.line += delta
            moved.endLine += delta
            if var f = moved.fix { f.startLine += delta; f.endLine += delta; moved.fix = f }
            return moved
        }
    }
}

/// What Build with Olo leaves alone: version control, dependencies, build output, large and
/// binary files, plus simple patterns from the project's .gitignore.
public struct ReviewIgnore: Sendable {
    public static let maxBytes = 200_000
    public static let skippedFolders: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", "bower_components", "build", "builds", "dist", "out", ".build", "DerivedData",
        "Pods", "Carthage", ".swiftpm", "target", "vendor", ".next", ".nuxt", ".svelte-kit", ".turbo", ".cache", ".parcel-cache",
        "coverage", "__pycache__", ".venv", "venv", ".tox", ".mypy_cache", ".pytest_cache", ".gradle", ".idea", ".vscode", "xcuserdata",
    ]
    public static let skippedNames: Set<String> = [".DS_Store", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Package.resolved", "Podfile.lock", "Cargo.lock", "poetry.lock", "composer.lock"]

    public var patterns: [String]

    public init(gitignore: String? = nil) {
        patterns = (gitignore ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("!") }
    }

    /// `relativePath` uses "/" and has no leading slash.
    public func ignores(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let name = parts.last else { return true }
        if parts.dropLast().contains(where: { ReviewIgnore.skippedFolders.contains($0) }) { return true }
        if ReviewIgnore.skippedNames.contains(name) || name.hasPrefix(".#") || name.hasSuffix("~") || name.hasSuffix(".swp") { return true }
        // Hidden files and folders (.env and friends often hold secrets), except .github workflows.
        if parts.contains(where: { $0.hasPrefix(".") && $0 != ".github" }) { return true }
        for p in patterns where ReviewIgnore.matches(pattern: p, path: parts) { return true }
        return false
    }

    /// One .gitignore line against a path. Supports "name", "*.ext", "dir/", "/anchored" and "a/b/*".
    static func matches(pattern raw: String, path parts: [String]) -> Bool {
        var p = raw
        let dirOnly = p.hasSuffix("/")
        if dirOnly { p.removeLast() }
        let anchored = p.hasPrefix("/")
        if anchored { p.removeFirst() }
        p = p.replacingOccurrences(of: "**/", with: "")
        guard !p.isEmpty else { return false }
        if !anchored && !p.contains("/") {
            // Any component (a folder for "dir/", any component otherwise).
            let candidates = dirOnly ? Array(parts.dropLast()) : parts
            return candidates.contains { glob(p, $0) }
        }
        let segs = p.split(separator: "/").map(String.init)
        let limit = dirOnly ? parts.count - 1 : parts.count
        guard segs.count <= limit else { return false }
        for (i, s) in segs.enumerated() where !glob(s, parts[i]) { return false }
        return true
    }

    /// "*" and "?" within one path component.
    public static func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == t[ti]) { pi += 1; ti += 1 }
            else if pi < p.count && p[pi] == "*" { star = pi; mark = ti; pi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ti = mark }
            else { return false }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Binary when a NUL byte appears in the first 8 KB, or the bytes are not UTF-8.
    public static func text(from data: Data) -> String? {
        guard data.count <= maxBytes else { return nil }
        if data.prefix(8_192).contains(0) { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension OloAPI {
    /// Reviews one file (code.review): issues with optional fixes, and a one line summary.
    public func reviewCode(_ input: CodeReviewInput) async throws -> CodeReviewResult {
        let req = try TRPC.mutationRequest(base: base, path: "code.review", input: input, token: token)
        var r = req
        // A review of a long file can take a while; the default 30 seconds is too short.
        r.timeoutInterval = 90
        return try await run(r, as: CodeReviewResult.self)
    }
}
