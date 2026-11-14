import Foundation

/// A conversation as a document: Markdown for the file, plain text in the layout the
/// web's export uses (client/src/lib/exportEngine.ts conversationToText), and an
/// attributed string's worth of structure for the PDF. Pure, so the wording is tested.
public enum TranscriptExport {
    public static let header = "Olo. Checked by Zeus."

    /// "24 October 2026 at 10:00"
    public static func stamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = timeZone
        f.dateFormat = "d MMMM yyyy 'at' HH:mm"
        return f.string(from: date)
    }

    /// A filename safe for the Finder and most other systems, at most 60 characters.
    public static func safeFilename(_ name: String, fallback: String = "conversation") -> String {
        var cleaned = name
        for ch in ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"] { cleaned = cleaned.replacingOccurrences(of: ch, with: " ") }
        cleaned = cleaned.components(separatedBy: .controlCharacters).joined(separator: " ")
        cleaned = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let cut = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? fallback : cut
    }

    /// The whole conversation as Markdown, with each answer's sources under it.
    public static func markdown(_ c: LocalConversation, folder: String? = nil, timeZone: TimeZone = .current) -> String {
        var lines: [String] = ["# \(c.title)", "", header]
        if let first = c.turns.first { lines.append("Started \(stamp(first.createdAt, timeZone: timeZone))") }
        if let folder, !folder.isEmpty { lines.append("Folder: \(folder)") }
        for t in c.turns {
            lines.append("")
            lines.append("---")
            lines.append("")
            lines.append("**\(t.role == .user ? "You" : "Olo")** (\(stamp(t.createdAt, timeZone: timeZone)))")
            lines.append("")
            lines.append(t.text.isEmpty ? "(no text)" : t.text)
            if !t.attachments.isEmpty { lines.append(""); lines.append("Attached: \(t.attachments.joined(separator: ", "))") }
            if t.role == .assistant {
                if let v = t.verification, !v.claims.isEmpty {
                    lines.append("")
                    lines.append("Checked by Zeus: \(v.supported) supported, \(v.contradicted) contradicted, \(v.unsupported) not covered.")
                }
                if !t.sources.isEmpty {
                    lines.append("")
                    lines.append("Sources:")
                    for s in t.sources {
                        lines.append(s.url.isEmpty ? "\(s.index). \(s.title)" : "\(s.index). [\(s.title)](\(s.url))")
                    }
                }
                if let line = t.answeredBy?.line { lines.append(""); lines.append("_\(line)_") }
                if let o = t.origin, o != .olo { lines.append(""); lines.append("_\(o.label)_") }
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Plain text in the web export's layout: a header, the title, then You / Olo blocks between rules.
    public static func plainText(_ c: LocalConversation, folder: String? = nil, timeZone: TimeZone = .current) -> String {
        var lines: [String] = [header, String(repeating: "=", count: header.count), "", c.title]
        if let first = c.turns.first { lines.append("Started \(stamp(first.createdAt, timeZone: timeZone))") }
        if let folder, !folder.isEmpty { lines.append("Folder: \(folder)") }
        let rule = String(repeating: "-", count: 60)
        lines.append(""); lines.append(rule); lines.append("")
        for t in c.turns {
            lines.append("\(t.role == .user ? "You" : "Olo"), \(stamp(t.createdAt, timeZone: timeZone))")
            lines.append("")
            lines.append(t.text)
            lines.append(""); lines.append(rule); lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// One block of the PDF: a heading line and a body, in order.
    public struct Block: Equatable, Sendable {
        public var heading: String
        public var body: String
        public var isUser: Bool
    }

    public static func blocks(_ c: LocalConversation, timeZone: TimeZone = .current) -> [Block] {
        c.turns.map { t in
            var body = t.text
            if t.role == .assistant, !t.sources.isEmpty {
                body += "\n\nSources: " + t.sources.map { "[\($0.index)] \($0.title)" }.joined(separator: "; ")
            }
            return Block(heading: "\(t.role == .user ? "You" : "Olo"), \(stamp(t.createdAt, timeZone: timeZone))", body: body, isUser: t.role == .user)
        }
    }
}

/// Markdown tables in an answer or a file, as CSV for Numbers, Excel and Google Sheets.
public enum MarkdownTables {
    /// Every table in the text, each as rows of cells (the separator row dropped).
    public static func tables(in text: String) -> [[[String]]] {
        var out: [[[String]]] = []
        var current: [[String]] = []
        func flush() { if current.count >= 1 { out.append(current) }; current = [] }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|"), line.count > 1 else { flush(); continue }
            var inner = line
            inner.removeFirst()
            if inner.hasSuffix("|") { inner.removeLast() }
            let cells = inner.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            // The header separator: |---|:--:| and the like.
            if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { continue }
            current.append(cells)
        }
        flush()
        return out.filter { $0.count >= 2 || ($0.count == 1 && $0[0].count >= 2) }
    }

    public static func hasTable(_ text: String) -> Bool { !tables(in: text).isEmpty }

    /// RFC 4180 CSV: cells with commas, quotes or line breaks are quoted; several tables are
    /// separated by a blank line. nil when there is no table.
    public static func csv(from text: String) -> String? {
        let all = tables(in: text)
        guard !all.isEmpty else { return nil }
        func cell(_ c: String) -> String {
            let cleaned = c.replacingOccurrences(of: "**", with: "")
            if cleaned.contains(",") || cleaned.contains("\"") || cleaned.contains("\n") {
                return "\"" + cleaned.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return cleaned
        }
        return all.map { t in t.map { $0.map(cell).joined(separator: ",") }.joined(separator: "\n") }.joined(separator: "\n\n") + "\n"
    }
}

/// What to tell someone who asked for a file format: the Mac exports answers and Olo's files
/// as PDF, Word and CSV itself, and says plainly what it cannot make yet.
public enum ExportHints {
    public static let canExport = "Save this as a file: Export in the toolbar gives PDF, Word (.docx), Markdown and CSV, and every file Olo builds (Artifacts) exports the same way."
    public static let noSlides = "PowerPoint and Keynote files are not made yet: export as PDF or Word, or ask for a one-page HTML deck."

    /// A hint for the answer when the question asks for a document format, else nil.
    public static func hint(for question: String) -> String? {
        let q = question.lowercased()
        let slides = ["powerpoint", "pptx", "keynote", "slide deck", "slides", "presentation"]
        if slides.contains(where: { q.contains($0) }) { return noSlides }
        let formats = ["pdf", "word doc", "docx", ".doc", "spreadsheet", "excel", "xlsx", "csv", "export", "download"]
        return formats.contains(where: { q.contains($0) }) ? canExport : nil
    }
}
