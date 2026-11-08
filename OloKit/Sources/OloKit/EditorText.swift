import Foundation

// Pure helpers for Build with Olo's editor: indentation and a small syntax tokeniser. The app
// draws with them; nothing here touches AppKit.

/// Indentation: what Tab inserts and what Return inserts.
public enum CodeIndent {
    static let twoSpaceLanguages: Set<String> = ["javascript", "typescript", "json", "yaml", "html", "css", "scss", "sass", "less", "vue", "svelte"]
    static let openers: Set<Character> = ["{", "(", "[", ":"]
    static let closers: [Character: Character] = ["{": "}", "(": ")", "[": "]"]

    /// The spaces Tab inserts: 2 for JavaScript, TypeScript, JSON, YAML, HTML and CSS, otherwise 4.
    public static func unit(for path: String) -> String {
        twoSpaceLanguages.contains(CodeLanguage.detect(path)) ? "  " : "    "
    }

    /// The spaces and tabs a line starts with.
    public static func leadingWhitespace(_ line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    /// What Return inserts, given the text before the cursor on its line and the text after it on
    /// the same line: a newline plus the line's indentation, one unit more after { ( [ or :, and,
    /// when the cursor sits between a bracket and its partner, the partner moves to its own line.
    /// `caret` is where the cursor goes, in UTF-16 units from the start of the inserted text.
    public static func newline(before: String, after: String, unit: String) -> (text: String, caret: Int) {
        let base = leadingWhitespace(before)
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, openers.contains(last) else {
            let text = "\n" + base
            return (text, text.utf16.count)
        }
        let inner = "\n" + base + unit
        if let close = closers[last], after.trimmingCharacters(in: .whitespaces).first == close {
            return (inner + "\n" + base, inner.utf16.count)
        }
        return (inner, inner.utf16.count)
    }

    /// One indentation step less: removes up to `unit` worth of leading spaces, or one tab.
    public static func outdented(_ line: String, unit: String) -> String {
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        var dropped = 0
        var rest = Substring(line)
        while dropped < unit.count, rest.first == " " {
            rest = rest.dropFirst()
            dropped += 1
        }
        return String(rest)
    }
}

public enum SyntaxKind: String, Sendable {
    case keyword, string, comment, number
}

/// A highlighted run. `range` is in UTF-16 units, ready for NSString and NSTextView.
public struct SyntaxToken: Equatable, Sendable {
    public var kind: SyntaxKind
    public var range: NSRange

    public init(kind: SyntaxKind, range: NSRange) {
        self.kind = kind; self.range = range
    }
}

/// Families of languages that highlight alike.
public enum SyntaxFamily: String, CaseIterable, Sendable {
    /// C, C++, Java, JavaScript, TypeScript, Go, Kotlin, C#, PHP, Dart, Solidity...
    case cLike
    /// Swift and Rust: like cLike, but a single quote is a character at most (Rust lifetimes, Swift has none).
    case cLikeStrictQuotes
    case python
    /// Shell, Ruby, Perl, YAML, TOML, R, Elixir, Makefiles, Dockerfiles: # comments.
    case hash
    case sql
    /// Lua and Haskell: -- comments.
    case dash
    case markup
    case css
    case json
    case plain

    public static func of(language: String) -> SyntaxFamily {
        switch language {
        case "swift", "rust": return .cLikeStrictQuotes
        case "c", "cpp", "objective-c", "objective-cpp", "javascript", "typescript", "go", "java", "kotlin", "scala", "csharp", "fsharp",
             "php", "dart", "solidity", "move", "zig", "groovy", "protobuf", "vue", "svelte", "scss", "less", "sass":
            return .cLike
        case "python", "vyper", "nim", "julia": return .python
        case "shell", "ruby", "perl", "yaml", "toml", "r", "elixir", "makefile", "dockerfile", "terraform", "hcl", "graphql", "powershell":
            return .hash
        case "sql": return .sql
        case "lua", "haskell", "erlang": return .dash
        case "html", "xml", "markdown": return .markup
        case "css": return .css
        case "json": return .json
        default: return .plain
        }
    }

    static let cKeywords = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto", "fallthrough",
        "func", "function", "fn", "let", "var", "const", "val", "class", "struct", "enum", "interface", "protocol", "extension",
        "import", "export", "from", "package", "module", "namespace", "using", "use", "mod", "crate", "pub", "mut", "impl", "trait",
        "public", "private", "protected", "internal", "fileprivate", "open", "static", "final", "override", "abstract", "virtual",
        "new", "delete", "this", "self", "Self", "super", "true", "false", "nil", "null", "undefined", "void", "typeof", "instanceof",
        "try", "catch", "throw", "throws", "rethrows", "finally", "async", "await", "yield", "in", "is", "as", "guard", "defer",
        "where", "typealias", "type", "extends", "implements", "readonly", "volatile", "inline", "extern", "operator", "template",
        "typename", "sizeof", "match", "loop", "unsafe", "dyn", "ref", "move", "go", "chan", "select", "range", "map", "lazy", "weak",
        "inout", "some", "any", "init", "deinit", "get", "set", "willSet", "didSet", "lambda", "synchronized", "contract", "modifier",
        "event", "emit", "require", "mapping", "payable", "view", "pure", "memory", "storage", "calldata",
    ]
    static let pythonKeywords = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally",
        "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True",
        "try", "while", "with", "yield", "self", "match", "case",
    ]
    static let hashKeywords = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return", "local",
        "export", "echo", "exit", "true", "false", "def", "end", "class", "module", "require", "unless", "begin", "rescue", "ensure",
        "yield", "nil", "self", "null", "yes", "no", "my", "sub", "use", "defmodule", "defp", "fn", "when", "resource", "variable",
        "output", "provider", "FROM", "RUN", "CMD", "COPY", "ADD", "ENV", "WORKDIR", "EXPOSE", "ENTRYPOINT", "ARG",
    ]
    static let sqlKeywords = [
        "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "index", "view", "drop",
        "alter", "add", "join", "left", "right", "inner", "outer", "full", "on", "as", "and", "or", "not", "null", "is", "in", "exists",
        "between", "like", "group", "by", "order", "having", "limit", "offset", "union", "all", "distinct", "case", "when", "then",
        "else", "end", "primary", "key", "foreign", "references", "default", "unique", "check", "begin", "commit", "rollback",
        "transaction", "returning", "with", "grant", "revoke", "true", "false",
    ]
    static let dashKeywords = [
        "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil", "not", "or",
        "repeat", "return", "then", "true", "until", "while", "let", "where", "data", "type", "module", "import", "case", "of",
        "class", "instance", "deriving",
    ]

    var keywords: [String] {
        switch self {
        case .cLike, .cLikeStrictQuotes: return SyntaxFamily.cKeywords
        case .python: return SyntaxFamily.pythonKeywords
        case .hash: return SyntaxFamily.hashKeywords
        case .sql: return SyntaxFamily.sqlKeywords
        case .dash: return SyntaxFamily.dashKeywords
        case .json: return ["true", "false", "null"]
        case .markup, .css, .plain: return []
        }
    }

    var commentPattern: String {
        switch self {
        case .cLike, .cLikeStrictQuotes, .css: return ##"//[^\n]*|/\*[\s\S]*?\*/"##
        case .python, .hash: return ##"#[^\n]*"##
        case .sql: return ##"--[^\n]*|/\*[\s\S]*?\*/"##
        case .dash: return ##"--[^\n]*"##
        case .markup: return ##"<!--[\s\S]*?-->"##
        case .json, .plain: return ##"(?!x)x"##
        }
    }

    var stringPattern: String {
        // Quote characters are joined on rather than written inside the raw strings, so no literal
        // starts with three quotes (which Swift would read as a multi-line string).
        let quote = "\""
        let threeQuotes = quote + quote + quote
        let double = quote + ##"(?:[^"\\\n]|\\.)*"## + quote
        let single = ##"'(?:[^'\\\n]|\\.)*'"##
        let char = ##"'(?:[^'\\\n]|\\.)'"##
        let backtick = ##"`(?:[^`\\]|\\.)*`"##
        let tripleDouble = threeQuotes + ##"[\s\S]*?"## + threeQuotes
        let tripleSingle = ##"'''[\s\S]*?'''"##
        switch self {
        case .cLike: return [tripleDouble, double, backtick, single].joined(separator: "|")
        case .cLikeStrictQuotes: return [tripleDouble, double, char].joined(separator: "|")
        case .python: return [tripleDouble, tripleSingle, double, single].joined(separator: "|")
        case .hash, .sql, .dash, .markup, .css: return [double, single].joined(separator: "|")
        case .json: return double
        case .plain: return ##"(?!x)x"##
        }
    }

    /// Comment, string, number, keyword, in that order of priority, as four capture groups.
    var pattern: String {
        let number = ##"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9]+)?)\b"##
        let words = keywords.map { NSRegularExpression.escapedPattern(for: $0) }
        let keyword = words.isEmpty ? ##"(?!x)x"## : ##"\b(?:"## + words.joined(separator: "|") + ##")\b"##
        return "(" + commentPattern + ")|(" + stringPattern + ")|(" + number + ")|(" + keyword + ")"
    }

    var regex: NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: self == .sql ? [.caseInsensitive] : [])
    }
}

/// Finds keywords, strings, comments and numbers with one regular expression per language family.
/// Pure and thread safe, so the editor runs it off the main thread.
public enum SyntaxScanner {
    static let compiled: [SyntaxFamily: NSRegularExpression] = {
        var out: [SyntaxFamily: NSRegularExpression] = [:]
        for f in SyntaxFamily.allCases {
            if let r = f.regex { out[f] = r }
        }
        return out
    }()

    public static func tokens(in text: String, language: String) -> [SyntaxToken] {
        tokens(in: text, family: SyntaxFamily.of(language: language))
    }

    public static func tokens(in text: String, family: SyntaxFamily) -> [SyntaxToken] {
        guard family != .plain, let regex = compiled[family] else { return [] }
        let kinds: [SyntaxKind] = [.comment, .string, .number, .keyword]
        var out: [SyntaxToken] = []
        let whole = NSRange(location: 0, length: text.utf16.count)
        regex.enumerateMatches(in: text, options: [], range: whole) { match, _, _ in
            guard let match else { return }
            for (i, kind) in kinds.enumerated() {
                let r = match.range(at: i + 1)
                if r.location != NSNotFound && r.length > 0 {
                    out.append(SyntaxToken(kind: kind, range: r))
                    break
                }
            }
        }
        return out
    }
}
