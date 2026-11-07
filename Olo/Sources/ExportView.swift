import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import OloKit

/// Export a conversation: Markdown or plain text as a file, PDF through the system print
/// pipeline (NSPrintOperation saving to a file, so pages break properly), or a share link.
/// The words come from OloKit's TranscriptExport, the same layout as the web's export.
enum TranscriptWriter {
    @MainActor
    static func saveMarkdown(_ c: LocalConversation) {
        save(text: TranscriptExport.markdown(c, folder: c.folder), name: TranscriptExport.safeFilename(c.title) + ".md")
    }

    @MainActor
    static func savePlainText(_ c: LocalConversation) {
        save(text: TranscriptExport.plainText(c, folder: c.folder), name: TranscriptExport.safeFilename(c.title) + ".txt")
    }

    @MainActor
    private static func save(text: String, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(text.utf8).write(to: url, options: [.atomic]) }
        catch { AppModel.shared.banner = "Could not save: \(error.localizedDescription)" }
    }

    /// The transcript as styled text: a title, then each turn with its heading in bold.
    static func attributed(_ c: LocalConversation) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let title = NSFont.boldSystemFont(ofSize: 20)
        let heading = NSFont.boldSystemFont(ofSize: 11)
        let body = NSFont.systemFont(ofSize: 11)
        let grey = NSColor.secondaryLabelColor
        out.append(NSAttributedString(string: c.title + "\n", attributes: [.font: title, .foregroundColor: NSColor.labelColor]))
        out.append(NSAttributedString(string: TranscriptExport.header + "\n\n", attributes: [.font: body, .foregroundColor: grey]))
        for block in TranscriptExport.blocks(c) {
            out.append(NSAttributedString(string: block.heading + "\n", attributes: [.font: heading, .foregroundColor: block.isUser ? NSColor.labelColor : grey]))
            out.append(NSAttributedString(string: block.body + "\n\n", attributes: [.font: body, .foregroundColor: NSColor.labelColor]))
        }
        return out
    }

    /// Prints the transcript to a PDF file the person chooses.
    @MainActor
    static func savePDF(_ c: LocalConversation) {
        DocumentWriter.savePDF(attributed(c), name: TranscriptExport.safeFilename(c.title))
    }

    /// The transcript as a Word document.
    @MainActor
    static func saveWord(_ c: LocalConversation) {
        DocumentWriter.saveWord(attributed(c), name: TranscriptExport.safeFilename(c.title))
    }

    /// The tables in the conversation's answers, as one CSV file.
    @MainActor
    static func saveCSV(_ c: LocalConversation) {
        let text = c.turns.filter { $0.role == .assistant }.map(\.text).joined(separator: "\n\n")
        DocumentWriter.saveCSV(from: text, name: TranscriptExport.safeFilename(c.title))
    }
}

/// Files people can hand to other apps, made on the Mac from an answer or an artifact: PDF
/// (through the print pipeline, so pages break properly, or from the rendered page for HTML),
/// Word (.docx, written by AppKit's Office Open XML exporter) and CSV from Markdown tables.
/// Nothing leaves the Mac to make them.
enum DocumentWriter {
    @MainActor
    static func ask(name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + "." + (type.preferredFilenameExtension ?? "txt")
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func write(_ data: Data, to url: URL, what: String) {
        do { try data.write(to: url, options: [.atomic]); AppModel.shared.banner = "Saved \(url.lastPathComponent)." }
        catch { AppModel.shared.banner = "Could not save the \(what): \(error.localizedDescription)" }
    }

    /// A Word document from styled text. The .docx type is the one Word, Pages and Google Docs open.
    @MainActor
    static func saveWord(_ text: NSAttributedString, name: String) {
        guard let url = ask(name: name, type: UTType("org.openxmlformats.wordprocessingml.document") ?? .data) else { return }
        do {
            let data = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            write(data, to: url, what: "Word document")
        } catch { AppModel.shared.banner = "Could not make the Word document: \(error.localizedDescription)" }
    }

    /// CSV from the Markdown tables in a text; says so when there is none.
    @MainActor
    static func saveCSV(from text: String, name: String) {
        guard let csv = MarkdownTables.csv(from: text) else { AppModel.shared.banner = "No table to export: ask Olo for the figures as a table first."; return }
        guard let url = ask(name: name, type: .commaSeparatedText) else { return }
        write(Data(csv.utf8), to: url, what: "CSV")
    }

    /// Styled text to a PDF the person chooses, laid out over as many A4 pages as it needs.
    @MainActor
    static func savePDF(_ text: NSAttributedString, name: String) {
        guard let url = ask(name: name, type: .pdf) else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = NSSize(width: 595, height: 842)
        info.topMargin = 56; info.bottomMargin = 56; info.leftMargin = 56; info.rightMargin = 56
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        textView.isEditable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(text)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.sizeToFit()

        let op = NSPrintOperation(view: textView, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        if op.run() { AppModel.shared.banner = "Saved \(url.lastPathComponent)." } else { AppModel.shared.banner = "The PDF could not be written." }
    }

    /// A rendered HTML page (an artifact) to PDF: loaded in an offscreen web view with
    /// JavaScript off and no network, then printed by WebKit.
    @MainActor
    static func savePDF(html: String, name: String) async {
        guard let url = ask(name: name, type: .pdf) else { return }
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123), configuration: config)
        let loader = PageLoad()
        view.navigationDelegate = loader
        view.loadHTMLString(html, baseURL: nil)
        await loader.finished()
        do {
            let data = try await view.pdf()
            write(data, to: url, what: "PDF")
        } catch { AppModel.shared.banner = "The PDF could not be written: \(error.localizedDescription)" }
    }

    /// Waits for a web view to finish loading (or fail), once.
    @MainActor
    final class PageLoad: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var done = false
        func finished() async { if done { return }; await withCheckedContinuation { continuation = $0 } }
        private func settle() { done = true; continuation?.resume(); continuation = nil }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { settle() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { settle() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { settle() }
    }
}

/// Markdown as styled text for Word and PDF: headings in bold at three sizes, bullets as
/// bullets, bold runs in bold, tables as tab-separated rows, everything else as body text.
enum MarkdownStyler {
    static func attributed(_ markdown: String, title: String? = nil) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 11)
        let bold = NSFont.boldSystemFont(ofSize: 11)
        let mono = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let sizes: [Int: CGFloat] = [1: 20, 2: 16, 3: 13]
        if let title, !title.isEmpty {
            out.append(NSAttributedString(string: title + "\n\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: NSColor.labelColor]))
        }
        var inCode = false
        for raw in markdown.components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); continue }
            if inCode { out.append(NSAttributedString(string: raw + "\n", attributes: [.font: mono, .foregroundColor: NSColor.labelColor])); continue }
            var line = raw
            var font = body
            if let m = line.range(of: "^#{1,3} ", options: .regularExpression) {
                let level = line.distance(from: line.startIndex, to: m.upperBound) - 1
                line = String(line[m.upperBound...])
                font = NSFont.boldSystemFont(ofSize: sizes[level] ?? 13)
                if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: body])) }
            } else if let m = line.range(of: "^\\s*[-*] ", options: .regularExpression) {
                line = "\u{2022} " + String(line[m.upperBound...])
            } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                var inner = line.trimmingCharacters(in: .whitespaces)
                inner.removeFirst()
                if inner.hasSuffix("|") { inner.removeLast() }
                let cells = inner.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { continue }
                line = cells.joined(separator: "\t")
            }
            // **bold** runs.
            let parts = line.components(separatedBy: "**")
            for (i, part) in parts.enumerated() {
                let f = (i % 2 == 1 && parts.count > 1) ? (font == body ? bold : font) : font
                out.append(NSAttributedString(string: part, attributes: [.font: f, .foregroundColor: NSColor.labelColor]))
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        }
        return out
    }
}

/// The Export menu in a conversation's toolbar.
struct ExportMenu: View {
    let conversationId: UUID
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button("Export as Markdown...") { if let c = model.conversation(conversationId) { TranscriptWriter.saveMarkdown(c) } }
            Button("Export as Plain Text...") { if let c = model.conversation(conversationId) { TranscriptWriter.savePlainText(c) } }
            Button("Export as PDF...") { if let c = model.conversation(conversationId) { TranscriptWriter.savePDF(c) } }
            Button("Export as Word (.docx)...") { if let c = model.conversation(conversationId) { TranscriptWriter.saveWord(c) } }
            Button("Export Tables as CSV...") { if let c = model.conversation(conversationId) { TranscriptWriter.saveCSV(c) } }
                .disabled(!(model.conversation(conversationId)?.turns.contains(where: { $0.role == .assistant && MarkdownTables.hasTable($0.text) }) ?? false))
            Divider()
            Button("Copy Share Link") { Task { await model.copyShareLink(for: conversationId) } }
                .disabled(model.conversation(conversationId)?.serverId == nil)
            Button("Copy as Markdown") {
                guard let c = model.conversation(conversationId) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(TranscriptExport.markdown(c, folder: c.folder), forType: .string)
                model.banner = "Copied the conversation as Markdown."
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .help("Save the conversation as Markdown, text, PDF, Word or CSV, or copy a link anyone can read")
    }
}
