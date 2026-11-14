import Foundation

/// The block structure of a Markdown answer, so the app can draw headings, lists, tables and
/// code as such instead of showing the raw marks. Inline marks (bold, italic, code, links)
/// stay in each block's text for the view to style. Pure, so the shapes are tested.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// Items of a bulleted list; each item's own text (inline marks kept).
    case bullets([String])
    /// Items of a numbered list, in order; the numbers are redrawn by the view.
    case numbered([String])
    case quote(String)
    case code(language: String, text: String)
    /// A table: the header row and the body rows, cells trimmed.
    case table(header: [String], rows: [[String]])
    case rule
}

public enum MarkdownBlocks {
    /// Splits text into blocks. Unknown shapes become paragraphs, so nothing is ever lost.
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var para: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var quote: [String] = []
        var table: [[String]] = []
        var code: (language: String, lines: [String])?

        func flushPara() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] } }
        func flushLists() {
            if !bullets.isEmpty { out.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { out.append(.numbered(numbered)); numbered = [] }
        }
        func flushQuote() { if !quote.isEmpty { out.append(.quote(quote.joined(separator: " "))); quote = [] } }
        func flushTable() {
            if let header = table.first {
                out.append(.table(header: header, rows: Array(table.dropFirst())))
            }
            table = []
        }
        func flushAll() { flushPara(); flushLists(); flushQuote(); flushTable() }

        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var c = code {
                if line.hasPrefix("```") { out.append(.code(language: c.language, text: c.lines.joined(separator: "\n"))); code = nil }
                else { c.lines.append(raw); code = c }
                continue
            }
            if line.hasPrefix("```") {
                flushAll()
                code = (language: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), lines: [])
                continue
            }
            if line.isEmpty { flushAll(); continue }
            if let cells = tableCells(line) {
                flushPara(); flushLists(); flushQuote()
                if isSeparatorRow(cells) { continue }
                table.append(cells)
                continue
            } else if !table.isEmpty { flushTable() }
            if let (level, rest) = heading(line) { flushAll(); out.append(.heading(level: level, text: rest)); continue }
            if isRule(line) { flushAll(); out.append(.rule); continue }
            if line.hasPrefix(">") {
                flushPara(); flushLists(); flushTable()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)); continue
            } else { flushQuote() }
            if let item = bullet(line) {
                flushPara(); flushTable()
                if !numbered.isEmpty { out.append(.numbered(numbered)); numbered = [] }
                bullets.append(item); continue
            }
            if let item = numberedItem(line) {
                flushPara(); flushTable()
                if !bullets.isEmpty { out.append(.bullets(bullets)); bullets = [] }
                numbered.append(item); continue
            }
            // A continuation line of a list item (indented) joins the item.
            if raw.hasPrefix("  "), !bullets.isEmpty { bullets[bullets.count - 1] += " " + line; continue }
            if raw.hasPrefix("  "), !numbered.isEmpty { numbered[numbered.count - 1] += " " + line; continue }
            flushLists()
            para.append(line)
        }
        if let c = code { out.append(.code(language: c.language, text: c.lines.joined(separator: "\n"))) }
        flushAll()
        return out
    }

    /// True when the text has any structure worth drawing (a heading, list, table or code block).
    public static func isStructured(_ text: String) -> Bool {
        parse(text).contains { b in
            switch b {
            case .paragraph, .quote, .rule: return false
            default: return true
            }
        }
    }

    /// The first heading, for a document's title; nil when there is none.
    public static func title(of text: String) -> String? {
        for b in parse(text) { if case .heading(_, let t) = b { return strip(t) } }
        return nil
    }

    /// Inline marks removed: for titles and filenames.
    public static func strip(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
        if let r = t.range(of: #"\[([^\]]+)\]\([^)]*\)"#, options: .regularExpression) {
            let inner = t[r].drop { $0 == "[" }.prefix { $0 != "]" }
            t.replaceSubrange(r, with: String(inner))
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Line shapes

    static func heading(_ line: String) -> (Int, String)? {
        var level = 0
        var i = line.startIndex
        while i < line.endIndex, line[i] == "#", level < 6 { level += 1; i = line.index(after: i) }
        guard level > 0, i < line.endIndex, line[i] == " " else { return nil }
        let rest = line[i...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)
        return rest.isEmpty ? nil : (level, rest)
    }

    static func bullet(_ line: String) -> String? {
        for mark in ["- ", "* ", "+ ", "\u{2022} "] where line.hasPrefix(mark) {
            let rest = line.dropFirst(mark.count).trimmingCharacters(in: .whitespaces)
            // "- [ ] task" and "- [x] task" keep their box as a symbol.
            if rest.hasPrefix("[ ] ") { return "\u{2610} " + String(rest.dropFirst(4)) }
            if rest.lowercased().hasPrefix("[x] ") { return "\u{2611} " + String(rest.dropFirst(4)) }
            return rest
        }
        return nil
    }

    static func numberedItem(_ line: String) -> String? {
        guard let r = line.range(of: #"^\d{1,3}[.)] "#, options: .regularExpression) else { return nil }
        return line[r.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    static func isRule(_ line: String) -> Bool {
        let set = Set(line.replacingOccurrences(of: " ", with: ""))
        return line.count >= 3 && (set == ["-"] || set == ["*"] || set == ["_"])
    }

    static func tableCells(_ line: String) -> [String]? {
        guard line.hasPrefix("|"), line.count > 1 else { return nil }
        var inner = line
        inner.removeFirst()
        if inner.hasSuffix("|") { inner.removeLast() }
        let cells = inner.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.count >= 2 || !cells[0].isEmpty ? cells : nil
    }

    static func isSeparatorRow(_ cells: [String]) -> Bool {
        cells.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }
    }
}
