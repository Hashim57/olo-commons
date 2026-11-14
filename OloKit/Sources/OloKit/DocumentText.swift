import Foundation

/// A run of text in an exported document.
public struct DocRun: Equatable, Sendable {
    public var text: String
    public var bold: Bool
    public init(_ text: String, bold: Bool = false) { self.text = text; self.bold = bold }
}

/// One paragraph of an exported document: what Word, PDF and the phone's styled text are built from.
public struct DocParagraph: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case title, heading(Int), body, bullet, code, tableRow, note }
    public var kind: Kind
    public var runs: [DocRun]
    public init(_ kind: Kind, _ runs: [DocRun]) { self.kind = kind; self.runs = runs }
    public init(_ kind: Kind, text: String) { self.kind = kind; self.runs = [DocRun(text)] }
    public var text: String { runs.map(\.text).joined() }
}

/// Markdown and transcripts as paragraphs, the same reading of Markdown as the Mac's exporter:
/// headings at three sizes, bullets, bold runs, code blocks kept as written, tables as
/// tab-separated rows, everything else as body text.
public enum DocumentText {
    /// "## Title" gives (2, "Title"); nil for anything that is not a heading of level 1 to 3.
    static func heading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        var rest = Substring(line)
        while rest.first == "#" { level += 1; rest = rest.dropFirst() }
        guard (1...3).contains(level), rest.first == " " else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    /// "- item" or "* item" (indented or not) gives "item".
    static func bullet(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("- ") || t.hasPrefix("* ") else { return nil }
        return String(t.dropFirst(2))
    }

    /// The cells of a Markdown table row, or nil for the row of dashes under the header.
    static func tableCells(_ line: String) -> [String]? {
        var inner = line.trimmingCharacters(in: .whitespaces)
        inner.removeFirst()
        if inner.hasSuffix("|") { inner.removeLast() }
        let cells = inner.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { return nil }
        return cells
    }

    /// Splits on "**": every second piece is bold.
    static func runs(_ line: String, allBold: Bool = false) -> [DocRun] {
        let parts = line.components(separatedBy: "**")
        var out: [DocRun] = []
        for (i, part) in parts.enumerated() where !part.isEmpty {
            out.append(DocRun(part, bold: allBold || (i % 2 == 1 && parts.count > 1)))
        }
        return out
    }

    public static func paragraphs(markdown: String, title: String? = nil) -> [DocParagraph] {
        var out: [DocParagraph] = []
        if let title, !title.isEmpty { out.append(DocParagraph(.title, [DocRun(title, bold: true)])) }
        var inCode = false
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); continue }
            if inCode { out.append(DocParagraph(.code, text: raw)); continue }
            if let h = heading(raw) {
                out.append(DocParagraph(.heading(h.level), runs(h.text, allBold: true)))
            } else if let b = bullet(raw) {
                out.append(DocParagraph(.bullet, runs(b)))
            } else if raw.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                if let cells = tableCells(raw) { out.append(DocParagraph(.tableRow, runs(cells.joined(separator: "\t")))) }
            } else {
                out.append(DocParagraph(.body, runs(raw)))
            }
        }
        return out
    }

    /// A conversation: its title, the "Olo. Checked by Zeus." line, then each turn under its heading.
    public static func paragraphs(conversation c: LocalConversation, timeZone: TimeZone = .current) -> [DocParagraph] {
        var out: [DocParagraph] = [DocParagraph(.title, [DocRun(c.title, bold: true)]), DocParagraph(.note, text: TranscriptExport.header), DocParagraph(.body, text: "")]
        for block in TranscriptExport.blocks(c, timeZone: timeZone) {
            out.append(DocParagraph(.heading(3), [DocRun(block.heading, bold: true)]))
            out.append(contentsOf: paragraphs(markdown: block.body))
            out.append(DocParagraph(.body, text: ""))
        }
        return out
    }
}

/// A Word document (.docx) written without any library: the three parts Word needs, in a ZIP
/// archive stored without compression. Word, Pages and Google Docs open it. Nothing leaves the
/// device to make it. (The Mac uses AppKit's exporter; iOS has none.)
public enum DocxWriter {
    public static let contentType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    static let contentTypesXML = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>"

    static let relsXML = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"

    /// Text made safe for XML: the three reserved characters escaped, and control characters that
    /// XML 1.0 forbids (which make Word refuse the file) dropped.
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default:
                let v = u.value
                if v < 0x20 && v != 0x09 { continue }
                if v == 0xFFFE || v == 0xFFFF { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// Font size in half points, as Word counts.
    static func size(_ kind: DocParagraph.Kind) -> Int {
        switch kind {
        case .title: return 40
        case .heading(let level): return level == 1 ? 40 : (level == 2 ? 32 : 26)
        case .code: return 20
        default: return 22
        }
    }

    static func runXML(_ run: DocRun, kind: DocParagraph.Kind) -> String {
        var props = ""
        if kind == .code { props += "<w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\" w:cs=\"Courier New\"/>" }
        if run.bold { props += "<w:b/>" }
        if kind == .note { props += "<w:color w:val=\"666666\"/>" }
        props += "<w:sz w:val=\"\(size(kind))\"/>"
        // A tab is its own element in Word; the text between tabs keeps its spaces.
        let pieces = run.text.components(separatedBy: "\t")
        var inner = ""
        for (i, piece) in pieces.enumerated() {
            if i > 0 { inner += "<w:tab/>" }
            if !piece.isEmpty { inner += "<w:t xml:space=\"preserve\">\(escape(piece))</w:t>" }
        }
        return "<w:r><w:rPr>\(props)</w:rPr>\(inner)</w:r>"
    }

    static func paragraphXML(_ p: DocParagraph) -> String {
        var runs = p.runs
        if p.kind == .bullet { runs.insert(DocRun("\u{2022} "), at: 0) }
        let after: Int
        switch p.kind {
        case .title: after = 160
        case .heading: after = 120
        case .code, .tableRow: after = 0
        default: after = 80
        }
        return "<w:p><w:pPr><w:spacing w:after=\"\(after)\"/></w:pPr>\(runs.map { runXML($0, kind: p.kind) }.joined())</w:p>"
    }

    /// word/document.xml for the paragraphs, on A4 with 2 cm margins.
    public static func documentXML(_ paragraphs: [DocParagraph]) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>"
            + paragraphs.map(paragraphXML).joined()
            + "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1134\" w:right=\"1134\" w:bottom=\"1134\" w:left=\"1134\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>"
    }

    /// The .docx file.
    public static func data(_ paragraphs: [DocParagraph]) -> Data {
        StoredZip.archive([
            ("[Content_Types].xml", Data(contentTypesXML.utf8)),
            ("_rels/.rels", Data(relsXML.utf8)),
            ("word/document.xml", Data(documentXML(paragraphs).utf8)),
        ])
    }
}

/// A ZIP archive whose files are stored as they are (method 0), which is all a small .docx needs.
public enum StoredZip {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    /// CRC-32 as ZIP and PNG use it.
    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }

    /// 1 January 2026 at midnight in the MS-DOS form ZIP uses: the files carry no real time.
    static let dosDate = ((2026 - 1980) << 9) | (1 << 5) | 1

    public static func archive(_ files: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        for file in files {
            let name = Array(file.name.utf8)
            let crc = crc32(file.data)
            let size = UInt32(file.data.count)
            let offset = UInt32(out.count)
            var fields: [UInt8] = []
            fields += le16(20)              // version needed
            fields += le16(0)               // flags
            fields += le16(0)               // method: stored
            fields += le16(0)               // time
            fields += le16(dosDate)         // date
            fields += le32(crc)
            fields += le32(size)            // compressed size
            fields += le32(size)            // size
            fields += le16(name.count)
            fields += le16(0)               // extra length
            out.append(contentsOf: le32(0x0403_4B50))
            out.append(contentsOf: fields)
            out.append(contentsOf: name)
            out.append(file.data)
            central.append(contentsOf: le32(0x0201_4B50))
            central.append(contentsOf: le16(20))    // version made by
            central.append(contentsOf: fields)
            central.append(contentsOf: le16(0))     // comment length
            central.append(contentsOf: le16(0))     // disk number
            central.append(contentsOf: le16(0))     // internal attributes
            central.append(contentsOf: le32(0))     // external attributes
            central.append(contentsOf: le32(offset))
            central.append(contentsOf: name)
        }
        let start = UInt32(out.count)
        out.append(central)
        out.append(contentsOf: le32(0x0605_4B50))
        out.append(contentsOf: le16(0))
        out.append(contentsOf: le16(0))
        out.append(contentsOf: le16(files.count))
        out.append(contentsOf: le16(files.count))
        out.append(contentsOf: le32(UInt32(central.count)))
        out.append(contentsOf: le32(start))
        out.append(contentsOf: le16(0))
        return out
    }
}
