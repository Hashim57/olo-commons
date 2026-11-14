import MessageUI
import OloKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A file written for the share sheet.
struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Files people can hand to other apps, made on the phone from a conversation, an answer or an
/// artifact: PDF, Word (.docx), Markdown, plain text and CSV, the same set as the Mac. Nothing
/// leaves the phone to make them; the share sheet decides where they go.
enum DocumentExporter {
    /// A fresh folder in the temporary directory, so two exports with one name never collide.
    static func write(_ data: Data, name: String, ext: String) -> ExportedFile? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("olo-export-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(TranscriptExport.safeFilename(name, fallback: "olo") + "." + ext)
            try data.write(to: url, options: [.atomic])
            return ExportedFile(url: url)
        } catch {
            return nil
        }
    }

    static func markdown(_ c: LocalConversation) -> ExportedFile? {
        write(Data(TranscriptExport.markdown(c).utf8), name: c.title, ext: "md")
    }

    static func plainText(_ c: LocalConversation) -> ExportedFile? {
        write(Data(TranscriptExport.plainText(c).utf8), name: c.title, ext: "txt")
    }

    static func word(_ paragraphs: [DocParagraph], name: String) -> ExportedFile? {
        write(DocxWriter.data(paragraphs), name: name, ext: "docx")
    }

    static func pdf(_ paragraphs: [DocParagraph], name: String) -> ExportedFile? {
        write(pdfData(styled(paragraphs)), name: name, ext: "pdf")
    }

    /// The tables in a text as one CSV file, or nil when there is none.
    static func csv(from text: String, name: String) -> ExportedFile? {
        guard let csv = MarkdownTables.csv(from: text) else { return nil }
        return write(Data(csv.utf8), name: name, ext: "csv")
    }

    /// Paragraphs as styled text, black on white whatever the phone's appearance.
    static func styled(_ paragraphs: [DocParagraph]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for p in paragraphs {
            let size: CGFloat
            switch p.kind {
            case .title: size = 20
            case .heading(let level): size = level == 1 ? 20 : (level == 2 ? 16 : 13)
            case .code: size = 10
            default: size = 11
            }
            let colour: UIColor = p.kind == .note ? UIColor.darkGray : UIColor.black
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = (p.kind == .code || p.kind == .tableRow) ? 0 : 5
            var runs = p.runs
            if p.kind == .bullet { runs.insert(DocRun("\u{2022} "), at: 0) }
            for run in runs {
                let font: UIFont
                if p.kind == .code { font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular) }
                else if run.bold { font = UIFont.boldSystemFont(ofSize: size) }
                else { font = UIFont.systemFont(ofSize: size) }
                out.append(NSAttributedString(string: run.text, attributes: [.font: font, .foregroundColor: colour, .paragraphStyle: style]))
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: UIFont.systemFont(ofSize: size), .paragraphStyle: style]))
        }
        return out
    }

    /// Styled text laid out over as many A4 pages as it needs, with 2 cm margins.
    static func pdfData(_ text: NSAttributedString) -> Data {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(UISimpleTextPrintFormatter(attributedText: text), startingAtPageAt: 0)
        renderer.setValue(NSValue(cgRect: page), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: page.insetBy(dx: 56, dy: 56)), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        let pages = renderer.numberOfPages
        if pages == 0 { UIGraphicsBeginPDFPage() }
        for i in 0..<pages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }
}

/// The system share sheet for a file or some text.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The Export menu in the conversation's toolbar, with the Mac's choices.
struct ExportMenu: View {
    @EnvironmentObject var model: AppModel
    @State private var file: ExportedFile?

    private var hasTable: Bool { model.items.contains { $0.role == "assistant" && MarkdownTables.hasTable($0.text) } }

    var body: some View {
        Menu {
            Button("Export as PDF") { export { DocumentExporter.pdf(DocumentText.paragraphs(conversation: $0), name: $0.title) } }
            Button("Export as Word (.docx)") { export { DocumentExporter.word(DocumentText.paragraphs(conversation: $0), name: $0.title) } }
            Button("Export as Markdown") { export { DocumentExporter.markdown($0) } }
            Button("Export as plain text") { export { DocumentExporter.plainText($0) } }
            Button("Export tables as CSV") {
                export { c in DocumentExporter.csv(from: c.turns.filter { $0.role == .assistant }.map(\.text).joined(separator: "\n\n"), name: c.title) }
            }
            .disabled(!hasTable)
            Divider()
            Button("Copy share link") {
                guard let id = model.conversationId else { return }
                let title = model.exportConversation.title
                Task { model.banner = await model.copyShareLink(subjectType: "conversation", subjectId: String(id), label: title) }
            }
            .disabled(model.conversationId == nil || model.isPrivate)
            Button("Copy as Markdown") {
                UIPasteboard.general.string = TranscriptExport.markdown(model.exportConversation)
                model.banner = "Copied the conversation as Markdown."
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel("Export")
        .disabled(model.items.isEmpty || model.sending)
        .sheet(item: $file) { f in ActivityView(items: [f.url]) }
    }

    private func export(_ make: (LocalConversation) -> ExportedFile?) {
        if let made = make(model.exportConversation) { file = made } else { model.banner = "The file could not be written." }
    }
}

/// The phone's own mail composer with a draft filled in. Olo never sends mail: the person reads
/// the draft and presses Send.
struct MailComposer: UIViewControllerRepresentable {
    let draft: MailDraft
    @Environment(\.dismiss) private var dismiss

    static var canSend: Bool { MFMailComposeViewController.canSendMail() }

    func makeCoordinator() -> Coordinator { Coordinator(done: { dismiss() }) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let c = MFMailComposeViewController()
        c.mailComposeDelegate = context.coordinator
        if !draft.to.isEmpty { c.setToRecipients(draft.to) }
        c.setSubject(draft.subject)
        c.setMessageBody(draft.body, isHTML: false)
        return c
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            done()
        }
    }
}

/// What can be done with one finished answer: copy it, share it, open it in Mail as a draft, or
/// save it as PDF or Word.
struct AnswerActions: View {
    @EnvironmentObject var model: AppModel
    let text: String
    @State private var file: ExportedFile?
    @State private var sharing = false
    @State private var mailing = false

    private var name: String { LocalConversation.title(for: text) }

    var body: some View {
        Menu {
            Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
            Button { sharing = true } label: { Label("Share", systemImage: "square.and.arrow.up") }
            Button { mail() } label: { Label("Open in Mail as a draft", systemImage: "envelope") }
            Divider()
            Button { save(DocumentExporter.pdf(DocumentText.paragraphs(markdown: text), name: name)) } label: { Label("Save as PDF", systemImage: "doc.richtext") }
            Button { save(DocumentExporter.word(DocumentText.paragraphs(markdown: text), name: name)) } label: { Label("Save as Word (.docx)", systemImage: "doc.text") }
            if MarkdownTables.hasTable(text) {
                Button { save(DocumentExporter.csv(from: text, name: name)) } label: { Label("Save tables as CSV", systemImage: "tablecells") }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityLabel("More for this answer")
        .sheet(item: $file) { f in ActivityView(items: [f.url]) }
        .sheet(isPresented: $sharing) { ActivityView(items: [text]) }
        .sheet(isPresented: $mailing) { MailComposer(draft: MailDraft.parse(text)).ignoresSafeArea() }
    }

    private func save(_ made: ExportedFile?) {
        if let made { file = made } else { model.banner = "The file could not be written." }
    }

    /// Mail's composer when this phone has a mail account in Mail; otherwise a mailto: link, which
    /// opens whichever mail app is the default; otherwise the share sheet.
    private func mail() {
        if MailComposer.canSend { mailing = true; return }
        if let url = MailDraft.parse(text).mailtoURL {
            Task {
                let opened = await UIApplication.shared.open(url)
                if !opened { sharing = true }
            }
        } else {
            sharing = true
        }
    }
}
