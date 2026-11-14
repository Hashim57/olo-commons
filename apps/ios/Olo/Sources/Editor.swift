import OloKit
import SwiftUI
import UIKit

/// Olo's editor on the phone: one file, coloured as you type by OloKit's scanner (the same one as
/// the Mac). Olo reviews the file (code.review), changes it when asked and shows what it would
/// change before anything is replaced (code.edit), and shows the page an HTML or SVG file makes.
/// Code is sent only to be reviewed or written: the server never stores it, never trains on it
/// and never adds it to the brain.
struct CodeEditorScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let url: URL
    var closable = false
    @State private var text = ""
    @State private var saved = ""
    @State private var loaded = false
    @State private var note: String?
    @State private var asking = false
    @State private var reviewing = false
    @State private var previewing = false
    @State private var file: ExportedFile?
    @State private var proposal: CodeEditResult?
    @State private var review: CodeReviewResult?
    @State private var busy: String?

    private var name: String { url.lastPathComponent }
    private var language: String { CodeLanguage.detect(name) }
    private var artifact: Artifact { BuildStore.artifact(name: name, text: text) }

    var body: some View {
        VStack(spacing: 0) {
            if let note {
                Text(note).font(.footnote).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.18)).onTapGesture { self.note = nil }
            }
            if let busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy).font(.footnote).foregroundStyle(.secondary) }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            CodeTextView(text: $text, language: language)
            HStack(spacing: 18) {
                Button { asking = true } label: { Label("Ask Olo", systemImage: "wand.and.stars") }
                Button { Task { await runReview() } } label: { Label("Review", systemImage: "checkmark.shield") }
                if artifact.isPreviewable { Button { previewing = true } label: { Label("Preview", systemImage: "play.rectangle") } }
                Spacer()
                Text(text == saved ? "Saved" : "Edited").font(.caption).foregroundStyle(.secondary)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.bar)
            .disabled(busy != nil)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if closable {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { save(); dismiss() } }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Save") { save() }
                    Button("Share the file") { save(); file = ExportedFile(url: url) }
                    Button("Export as PDF") { export(DocumentExporter.pdf(paragraphs, name: name)) }
                    Button("Export as Word (.docx)") { export(DocumentExporter.word(paragraphs, name: name)) }
                    Button("Copy all") { UIPasteboard.general.string = text }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $asking) {
            AskOloToWriteSheet(fileName: name) { instruction in Task { await askToWrite(instruction) } }
        }
        .sheet(item: $file) { f in ActivityView(items: [f.url]) }
        .sheet(isPresented: $previewing) {
            NavigationStack {
                EditorPreview(artifact: artifact)
                    .navigationTitle("Preview").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { previewing = false } } }
            }
        }
        .sheet(isPresented: Binding(get: { proposal != nil }, set: { if !$0 { proposal = nil } })) {
            if let p = proposal {
                ProposalSheet(old: text, proposal: p, accept: { text = p.content; save(); proposal = nil; note = "Olo's change is in. Undo it by asking Olo, or edit by hand." }, reject: { proposal = nil })
            }
        }
        .sheet(isPresented: $reviewing) {
            if let r = review {
                ReviewSheet(result: r, apply: { issue in applyFix(issue) }, close: { reviewing = false })
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            text = BuildStore.shared.read(url)
            saved = text
        }
        .onDisappear { save() }
    }

    private var paragraphs: [DocParagraph] {
        if language == "markdown" { return DocumentText.paragraphs(markdown: text, title: name) }
        return [DocParagraph(.title, [DocRun(name, bold: true)])] + text.components(separatedBy: "\n").map { DocParagraph(.code, text: $0) }
    }

    private func save() {
        guard loaded, text != saved else { return }
        if BuildStore.shared.write(text, to: url) { saved = text } else { note = "The file could not be saved." }
    }

    private func export(_ made: ExportedFile?) {
        if let made { file = made } else { note = "The file could not be written." }
    }

    /// Olo rewrites the file to follow the instruction; the change is shown before it replaces anything.
    private func askToWrite(_ instruction: String) async {
        guard CodeEditInput.fits(text) else { note = "This file is too long for Olo to rewrite in one go."; return }
        busy = "Olo is writing"
        defer { busy = nil }
        do {
            try await model.ensureSession()
            let result = try await model.api.editCode(CodeEditInput(path: name, content: text, instruction: instruction))
            if result.content == text { note = result.explanation.isEmpty ? "Olo left the file as it is." : result.explanation } else { proposal = result }
        } catch let e as TRPC.RemoteError where e.isAllowanceExhausted {
            note = "Today's Build with Olo allowance is used up. It refills tomorrow, or a plan gives more."
        } catch let e as TRPC.RemoteError where e.isNotFound {
            note = "This server cannot edit code yet."
        } catch {
            note = error.localizedDescription
        }
    }

    private func runReview() async {
        busy = "Olo is reviewing"
        defer { busy = nil }
        do {
            try await model.ensureSession()
            review = try await model.api.reviewCode(CodeReviewInput(path: name, content: text))
            reviewing = true
        } catch let e as TRPC.RemoteError where e.isAllowanceExhausted {
            note = "Today's Build with Olo allowance is used up. It refills tomorrow, or a plan gives more."
        } catch let e as TRPC.RemoteError where e.isNotFound {
            note = "This server cannot review code yet."
        } catch {
            note = error.localizedDescription
        }
    }

    /// Puts one suggested fix into the text and moves the remaining issues to their new lines.
    private func applyFix(_ issue: CodeIssue) {
        guard let fix = issue.fix, let current = review else { return }
        let lines = text.components(separatedBy: "\n")
        text = FixApplier.apply(fix, to: lines).joined(separator: "\n")
        let rest = current.issues.filter { $0.id != issue.id }
        review = CodeReviewResult(issues: FixApplier.rebase(rest, after: fix, count: lines.count), summary: current.summary, model: current.model)
        save()
    }
}

/// The page an HTML, SVG or React file makes. JavaScript stays off until the person turns it on.
struct EditorPreview: View {
    let artifact: Artifact
    @State private var scripts = false
    var body: some View {
        VStack(spacing: 0) {
            Toggle(artifact.needsScripts ? "Run scripts (loads React from unpkg.com)" : "Run scripts in the page", isOn: $scripts)
                .font(.footnote).padding(.horizontal, 14).padding(.vertical, 8)
            if artifact.needsScripts && !scripts {
                Text("Turn scripts on to see this component.").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PagePreview(html: ArtifactPreview.document(for: artifact), scripts: scripts).id(scripts)
            }
        }
    }
}

/// "Make the header sticky", "add a dark mode": what Olo should change in the file.
struct AskOloToWriteSheet: View {
    let fileName: String
    let send: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var instruction = ""

    static let examples = ["Explain what this file does in comments at the top.", "Make it work well on a small phone screen.", "Fix anything that would break and tidy the rest."]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should Olo change in \(fileName)?", text: $instruction, axis: .vertical).lineLimit(3...8)
                    ForEach(AskOloToWriteSheet.examples, id: \.self) { example in
                        Button(example) { instruction = example }.font(.footnote)
                    }
                } footer: {
                    Text("Olo shows the change before it replaces anything. The file is sent only to be rewritten: it is not stored, used for training or added to the Olo brain.")
                }
            }
            .navigationTitle("Ask Olo to write")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send(instruction); dismiss() }
                        .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// What Olo would change, line by line (OloKit's LineDiff, as on the Mac), to accept or reject.
struct ProposalSheet: View {
    let old: String
    let proposal: CodeEditResult
    let accept: () -> Void
    let reject: () -> Void

    private var rows: [DiffRow] { LineDiff.rows(old: old.components(separatedBy: "\n"), new: proposal.content.components(separatedBy: "\n")) }

    var body: some View {
        let shown = rows
        let counts = LineDiff.counts(shown)
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !proposal.explanation.isEmpty { Text(proposal.explanation).font(.subheadline).padding(.bottom, 10) }
                    Text("\(counts.added) added, \(counts.removed) removed").font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
                    ForEach(shown) { row in
                        if row.kind == .skipped {
                            Text("\(row.skipped) unchanged lines").font(.caption2).foregroundStyle(.secondary).padding(.vertical, 4)
                        } else {
                            Text((row.kind == .added ? "+ " : (row.kind == .removed ? "- " : "  ")) + row.text)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(row.kind == .added ? Color.green.opacity(0.16) : (row.kind == .removed ? Color.red.opacity(0.16) : Color.clear))
                        }
                    }
                }
                .padding(14)
            }
            .navigationTitle("Olo's change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Reject", role: .destructive) { reject() } }
                ToolbarItem(placement: .confirmationAction) { Button("Accept") { accept() } }
            }
        }
    }
}

/// What Olo found in the file, by line, with each suggested fix one tap away.
struct ReviewSheet: View {
    let result: CodeReviewResult
    let apply: (CodeIssue) -> Void
    let close: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if !result.summary.isEmpty { Section { Text(result.summary).font(.subheadline) } }
                if result.issues.isEmpty { Section { Text("Olo found nothing to change.").foregroundStyle(.secondary) } }
                ForEach(result.sorted) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(issue.severity.uppercased()).font(.system(size: 9, weight: .heavy)).padding(.horizontal, 6).padding(.vertical, 3)
                                .background(issue.severity == "error" ? Color.red : (issue.severity == "warning" ? Color.orange : Color(.systemGray3)), in: Capsule())
                                .foregroundStyle(issue.severity == "info" ? Color.primary : Color.white)
                            Text("Line \(issue.line), \(issue.category)").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(issue.message).font(.subheadline)
                        if issue.fix != nil {
                            Button("Apply the fix") { apply(issue) }.font(.footnote.weight(.semibold)).buttonStyle(.borderless)
                        }
                    }
                }
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { close() } } }
        }
    }
}

/// A plain text view for code: fixed-width, no autocorrection or smart punctuation, coloured by
/// OloKit's SyntaxScanner after each change.
struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    let language: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, language: language) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = Coordinator.font
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        view.text = text
        context.coordinator.highlight(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.language = language
        if view.text != text {
            view.text = text
            context.coordinator.highlight(view)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        static let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        /// Above this size the file is shown without colours, so typing stays quick.
        static let highlightLimit = 150_000
        var text: Binding<String>
        var language: String

        init(text: Binding<String>, language: String) {
            self.text = text
            self.language = language
        }

        func textViewDidChange(_ view: UITextView) {
            text.wrappedValue = view.text
            highlight(view)
        }

        func highlight(_ view: UITextView) {
            // Leave the text alone while an input method is composing a character.
            guard view.markedTextRange == nil else { return }
            let storage = view.textStorage
            let length = storage.length
            let base: [NSAttributedString.Key: Any] = [.font: Coordinator.font, .foregroundColor: UIColor.label]
            storage.beginEditing()
            storage.setAttributes(base, range: NSRange(location: 0, length: length))
            if length <= Coordinator.highlightLimit {
                for token in SyntaxScanner.tokens(in: storage.string, language: language) where NSMaxRange(token.range) <= length {
                    storage.addAttribute(.foregroundColor, value: Coordinator.colour(token.kind), range: token.range)
                }
            }
            storage.endEditing()
            view.typingAttributes = base
        }

        static func colour(_ kind: SyntaxKind) -> UIColor {
            switch kind {
            case .keyword: return UIColor.systemPurple
            case .string: return UIColor.systemRed
            case .comment: return UIColor.systemGray
            case .number: return UIColor.systemBlue
            }
        }
    }
}
