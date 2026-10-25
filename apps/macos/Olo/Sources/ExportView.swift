import AppKit
import SwiftUI
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

    /// Prints the transcript to a PDF file the person chooses. NSPrintOperation lays the text
    /// out over as many pages as it needs.
    @MainActor
    static func savePDF(_ c: LocalConversation) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = TranscriptExport.safeFilename(c.title) + ".pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

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
        textView.textStorage?.setAttributedString(attributed(c))
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.sizeToFit()

        let op = NSPrintOperation(view: textView, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        if !op.run() { AppModel.shared.banner = "The PDF could not be written." }
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
        .help("Save the conversation as a file, or copy a link anyone can read")
    }
}
