import OloKit
import SwiftUI
import UIKit
import WebKit

/// The files Build with Olo works on, kept on the phone in the app's Documents folder (so they
/// also show in the Files app under On My iPhone, Olo, Build). The Mac opens any folder; iOS
/// gives an app its own, so the phone keeps one flat folder of files.
@MainActor
final class BuildStore: ObservableObject {
    static let shared = BuildStore()
    @Published private(set) var files: [URL] = []
    let folder: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        folder = documents.appendingPathComponent("Build", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        func modified(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        files = found.filter { !$0.hasDirectoryPath }.sorted { modified($0) > modified($1) }
    }

    /// A name that is safe as a file name and keeps its extension; nil when nothing is left.
    static func cleanName(_ raw: String) -> String? {
        let last = raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        let cleaned = TranscriptExport.safeFilename(last, fallback: "")
        if cleaned.isEmpty || cleaned.hasPrefix(".") { return nil }
        return cleaned
    }

    /// A URL in the folder that does not exist yet: "page.html", then "page 2.html".
    private func freeURL(for name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// Writes a new file and returns where it is.
    func add(name: String, text: String) -> URL? {
        guard let clean = BuildStore.cleanName(name) else { return nil }
        let url = freeURL(for: clean)
        do {
            try Data(text.utf8).write(to: url, options: [.atomic])
            reload()
            return url
        } catch {
            return nil
        }
    }

    func read(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func write(_ text: String, to url: URL) -> Bool {
        do {
            try Data(text.utf8).write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    /// The artifact a local file stands for, so the preview and the exporters treat it like one.
    static func artifact(name: String, text: String) -> Artifact {
        let ext = (name as NSString).pathExtension.lowercased()
        let kind: String
        switch ext {
        case "html", "htm": kind = "html"
        case "svg": kind = "svg"
        case "jsx", "tsx": kind = "react"
        case "md", "markdown": kind = "markdown"
        default: kind = "code"
        }
        return Artifact(id: name, kind: kind, language: CodeLanguage.detect(name), title: name, filename: name, code: text)
    }
}

/// Build with Olo on the phone: say what to build and Olo writes the file on the server (the
/// same background builds as the Mac and the web), then it opens in Olo's editor, where Olo
/// reviews it, changes it on request and shows the page it makes.
struct BuildHomeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = BuildStore.shared
    @State private var prompt = ""
    @State private var jobId: String?
    @State private var starting = false
    @State private var problem: String?
    @State private var opened: URL?
    @State private var naming = false
    @State private var newName = ""
    @State private var allowance: BuildAllowance?

    static let examples = ["Build a one page site for a community garden with opening times.", "Make a budget tracker page I can use on my phone.", "Write a Python script that renames photos by date."]

    var body: some View {
        List {
            Section {
                TextField("What should Olo build?", text: $prompt, axis: .vertical).lineLimit(2...6)
                ForEach(BuildHomeView.examples, id: \.self) { example in
                    Button(example) { prompt = example }.font(.footnote)
                }
                Button {
                    Task { await start() }
                } label: {
                    HStack {
                        if starting { ProgressView().controlSize(.small) }
                        Text("Build it").fontWeight(.semibold)
                    }
                }
                .disabled(starting || jobId != nil || prompt.trimmingCharacters(in: .whitespacesAndNewlines).count < 4)
            } header: { Text("Ask Olo to build") } footer: {
                Text("The build runs on the server, so you can leave this screen and come back. Each build counts as one message.")
            }
            if let problem { Section { Text(problem).foregroundStyle(.red) } }
            if let jobId {
                Section("Building") {
                    BuildJobCard(jobId: jobId, finished: { job in finished(job) })
                }
            }
            Section {
                if store.files.isEmpty { Text("Nothing here yet. Files Olo builds for you appear here.").foregroundStyle(.secondary) }
                ForEach(store.files, id: \.self) { url in
                    Button { opened = url } label: {
                        HStack {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            Text(url.lastPathComponent).foregroundStyle(.primary)
                            Spacer()
                            Text(CodeLanguage.detect(url.lastPathComponent)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { store.delete(url) } }
                }
                Button { newName = ""; naming = true } label: { Label("New file", systemImage: "plus") }
            } header: { Text("Your files") } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kept on this iPhone. They also appear in the Files app under On My iPhone, Olo, Build.")
                    if let a = allowance, let used = a.used, let limit = a.limit { Text("Reviews and edits today: \(used) of \(limit).") }
                }
            }
        }
        .navigationTitle("Build with Olo")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $opened) { url in CodeEditorScreen(url: url) }
        .alert("New file", isPresented: $naming) {
            TextField("name.html", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Create") {
                if let url = store.add(name: newName, text: "") { opened = url } else { problem = "That name cannot be used for a file." }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            store.reload()
            if model.api.token != nil { allowance = try? await model.api.buildAllowance() }
        }
    }

    private func start() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        starting = true
        problem = nil
        defer { starting = false }
        do {
            try await model.ensureSession()
            let job = try await model.api.startBuild(OloAPI.StartBuildInput(prompt: text, tier: model.tier, conversationId: nil, projectId: model.activeProject?.id))
            await model.api.kickBuild(id: job.id)
            jobId = job.id
        } catch let e as TRPC.RemoteError where e.code == "PRECONDITION_FAILED" || e.isNotFound {
            problem = "This server does not run background builds. Ask for the file in the Olo tab instead."
        } catch {
            problem = error.localizedDescription
        }
    }

    private func finished(_ job: BuildJob) {
        guard job.status == "succeeded", let a = job.artifact else { return }
        if let url = store.add(name: a.suggestedFilename, text: a.code) {
            prompt = ""
            jobId = nil
            opened = url
        }
    }
}

/// A background build as it happens, the same card as the Mac: each step the server recorded, a
/// spinner on the one it is doing, the percentage, and who wrote the file once it is done.
struct BuildJobCard: View {
    @EnvironmentObject var model: AppModel
    let jobId: String
    /// In a conversation the finished file is shown on the card; Build with Olo opens it instead.
    var showsResult = false
    var finished: (BuildJob) -> Void = { _ in }
    @State private var job: BuildJob?
    @State private var announced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let job {
                HStack(spacing: 8) {
                    if job.isRunning { ProgressView().controlSize(.small) }
                    else { Image(systemName: job.status == "succeeded" ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(job.status == "succeeded" ? Color.green : Color.red) }
                    Text(job.headline).font(.subheadline.weight(.semibold))
                    Spacer()
                    if job.isRunning { Text("\(max(0, min(100, job.progress)))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                if job.isRunning { ProgressView(value: Double(max(2, min(100, job.progress))), total: 100) }
                ForEach(Array(job.timeline.suffix(5))) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: row.state == .failed ? "xmark" : (row.state == .current ? "circle.dotted" : (row.notice ? "exclamationmark.circle" : "checkmark")))
                            .font(.caption2).foregroundStyle(row.state == .failed ? Color.red : (row.notice ? Color.orange : Color.green)).frame(width: 14)
                        Text(row.label).font(.footnote).foregroundStyle(row.state == .current ? Color.primary : Color.secondary)
                    }
                }
                if job.status == "failed" { Text(job.error ?? "The build failed.").font(.footnote).foregroundStyle(.red) }
                if let line = job.finishedAnsweredBy?.line { Text(line).font(.caption).foregroundStyle(.secondary) }
                if showsResult, job.status == "succeeded", let made = job.artifact { ArtifactCard(artifact: made) }
                if job.isRunning {
                    Button("Cancel", role: .destructive) { Task { try? await model.api.cancelBuild(id: jobId) } }.font(.footnote).buttonStyle(.borderless)
                }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Starting the build").font(.subheadline) }
            }
        }
        .task(id: jobId) { await watch() }
    }

    /// Follows the job until it finishes. A job still queued after a few seconds is started from
    /// here, as the Mac does; the run is claimed once, so nothing runs twice.
    private func watch() async {
        let started = Date()
        var kicks = 0
        while !Task.isCancelled {
            if let fresh = try? await model.api.buildJob(id: jobId) {
                job = fresh
                if fresh.status == "queued", kicks < 2, Date().timeIntervalSince(started) > Double(6 * (kicks + 1)) {
                    kicks += 1
                    await model.api.kickBuild(id: jobId)
                }
                if fresh.isFinished {
                    if !announced { announced = true; finished(fresh) }
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}

/// A file an answer produced, in the conversation: read it, open it in the editor, or share it.
struct ArtifactCard: View {
    let artifact: Artifact
    @State private var opened: ExportedFile?
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(artifact.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(artifact.suggestedFilename + (artifact.repaired ? ", repaired" : "")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ForEach(Array(artifact.errors.prefix(2).enumerated()), id: \.offset) { _, issue in
                Text(issue.message).font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 14) {
                Button("Open in editor") {
                    if let url = BuildStore.shared.add(name: artifact.suggestedFilename, text: artifact.code) { opened = ExportedFile(url: url) } else { note = "The file could not be saved on this iPhone." }
                }
                ShareLink(item: artifact.code) { Text("Share") }
            }
            .font(.footnote.weight(.semibold)).buttonStyle(.borderless)
            if let note { Text(note).font(.caption).foregroundStyle(.red) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .fullScreenCover(item: $opened) { f in NavigationStack { CodeEditorScreen(url: f.url, closable: true) } }
    }
}

/// One artifact from the library: the page it makes or its text, with the Mac's exports.
struct ArtifactDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let artifact: Artifact
    var deleted: () -> Void = {}
    @State private var showCode = false
    @State private var scripts = false
    @State private var file: ExportedFile?
    @State private var opened: URL?
    @State private var note: String?
    @State private var confirmDelete = false

    private var showPreview: Bool { artifact.isPreviewable && !showCode }

    var body: some View {
        VStack(spacing: 0) {
            if let note { Text(note).font(.footnote).padding(8).frame(maxWidth: .infinity).background(Color.orange.opacity(0.18)).onTapGesture { self.note = nil } }
            if artifact.isPreviewable {
                Picker("View", selection: $showCode) { Text("Page").tag(false); Text("Code").tag(true) }
                    .pickerStyle(.segmented).padding(.horizontal, 12).padding(.vertical, 8)
            }
            if showPreview {
                if artifact.needsScripts && !scripts {
                    VStack(spacing: 10) {
                        Text("This preview runs JavaScript and loads React from unpkg.com.").font(.subheadline).multilineTextAlignment(.center)
                        Button("Run the preview") { scripts = true }.buttonStyle(.borderedProminent)
                    }
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PagePreview(html: ArtifactPreview.document(for: artifact), scripts: scripts).id(scripts)
                }
            } else {
                ScrollView {
                    Text(artifact.code).font(.footnote.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
            }
        }
        .navigationTitle(artifact.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Open in editor") {
                        if let url = BuildStore.shared.add(name: artifact.suggestedFilename, text: artifact.code) { opened = url } else { note = "The file could not be saved on this iPhone." }
                    }
                    if artifact.isPreviewable && !artifact.needsScripts {
                        Toggle("Allow scripts in the page", isOn: $scripts)
                    }
                    Divider()
                    Button("Share the file") { export(DocumentExporter.write(Data(artifact.code.utf8), name: (artifact.suggestedFilename as NSString).deletingPathExtension, ext: (artifact.suggestedFilename as NSString).pathExtension)) }
                    Button("Export as PDF") { export(DocumentExporter.pdf(paragraphs, name: artifact.title)) }
                    Button("Export as Word (.docx)") { export(DocumentExporter.word(paragraphs, name: artifact.title)) }
                    if MarkdownTables.hasTable(artifact.code) {
                        Button("Export tables as CSV") { export(DocumentExporter.csv(from: artifact.code, name: artifact.title)) }
                    }
                    Button("Copy share link") {
                        Task { note = await model.copyShareLink(subjectType: "artifact", subjectId: artifact.id, label: artifact.title) }
                    }
                    Divider()
                    Button("Delete", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(item: $file) { f in ActivityView(items: [f.url]) }
        .navigationDestination(item: $opened) { url in CodeEditorScreen(url: url) }
        .confirmationDialog("Delete this artifact from your library?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await model.api.deleteArtifact(id: artifact.id)
                        deleted()
                        dismiss()
                    } catch {
                        note = "Could not delete: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    /// Markdown reads as a document; code and pages export as their text in a fixed-width face.
    private var paragraphs: [DocParagraph] {
        if artifact.kind == "markdown" { return DocumentText.paragraphs(markdown: artifact.code, title: artifact.title) }
        return [DocParagraph(.title, [DocRun(artifact.title, bold: true)])] + artifact.code.components(separatedBy: "\n").map { DocParagraph(.code, text: $0) }
    }

    private func export(_ made: ExportedFile?) {
        if let made { file = made } else { note = "The file could not be written." }
    }
}

/// A page shown in a web view with no network access of its own choosing: JavaScript is off
/// unless the person turns it on, and links never navigate away from the preview.
struct PagePreview: UIViewRepresentable {
    let html: String
    let scripts: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = scripts
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded = ""
        @MainActor
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            // The page itself loads; a tapped link opens in the browser instead of replacing the preview.
            guard navigationAction.navigationType == .linkActivated else { return .allow }
            if let url = navigationAction.request.url, LinkPolicy.isSafeExternal(url) { _ = await UIApplication.shared.open(url) }
            return .cancel
        }
    }
}
