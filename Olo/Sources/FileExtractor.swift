import AppKit
import PDFKit
import UniformTypeIdentifiers
import OloKit

/// Reads the text of a file with what macOS already has: PDFKit for PDFs, the
/// system text importers for Word, RTF and OpenDocument, plain reading for text
/// and code. Nothing is uploaded until you send a question with the file attached.
enum FileExtractor {
    static let plainExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "xml", "log", "tex", "ini", "toml", "conf",
        "swift", "py", "js", "mjs", "ts", "tsx", "jsx", "java", "kt", "go", "rs", "rb", "php", "c", "h", "cc", "cpp", "hpp",
        "m", "mm", "cs", "sh", "zsh", "sql", "css", "scss", "vue", "svelte", "r", "lua", "pl", "dart", "scala", "ex", "exs",
    ]
    static let markupExtensions: Set<String> = ["html", "htm", "xhtml"]
    static let richExtensions: Set<String> = ["rtf", "rtfd", "doc", "docx", "odt", "wordml"]
    static let maxBytes = 40 * 1024 * 1024

    static func canRead(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "pdf" || plainExtensions.contains(ext) || markupExtensions.contains(ext) || richExtensions.contains(ext)
    }

    static func attachment(for url: URL) -> Attachment? {
        guard let text = text(of: url), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Attachment(kind: .file, name: url.lastPathComponent, text: text)
    }

    /// The file's text, or nil when it is not a kind Olo reads or is too large.
    static func text(of url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maxBytes { return nil }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            return PDFDocument(url: url)?.string
        }
        if richExtensions.contains(ext) {
            return try? NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        }
        if markupExtensions.contains(ext) {
            // Tags stripped by hand: the HTML importer needs the main thread and WebKit, which a background index should not use.
            guard let raw = readPlain(url) else { return nil }
            return stripTags(raw)
        }
        if plainExtensions.contains(ext) || (UTType(filenameExtension: ext)?.conforms(to: .text) ?? false) {
            return readPlain(url)
        }
        return nil
    }

    private static func readPlain(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        return String(data: data, encoding: .isoLatin1)
    }

    static func stripTags(_ html: String) -> String {
        var s = html
        for pattern in ["(?is)<script.*?</script>", "(?is)<style.*?</style>", "(?s)<[^>]+>"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    }
}
