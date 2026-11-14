import AppKit
import SwiftUI
import WebKit
import OloKit

/// Artifacts: the files answers produce. Inside a conversation the inspector lists this
/// thread's artifacts first, then the library (library.artifacts); as a panel it lists the
/// library. HTML and SVG are shown in a WKWebView with JavaScript off and every network
/// load blocked unless the person turns scripts on for that one artifact.
struct ArtifactsView: View {
    /// The conversation whose artifacts come first, or nil for the library alone.
    let conversationId: UUID?
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    @State private var shares: [Share] = []
    @State private var loading = false

    private var thread: [Artifact] {
        guard let id = conversationId ?? model.selection, let c = model.conversation(id) else { return [] }
        var seen = Set<String>()
        var out: [Artifact] = []
        for t in c.turns.reversed() { for a in t.artifacts where !seen.contains(a.id) { seen.insert(a.id); out.append(a) } }
        let sid = c.serverId
        for a in model.libraryArtifacts where a.conversationId != nil && a.conversationId == sid && !seen.contains(a.id) { seen.insert(a.id); out.append(a) }
        return out
    }

    private var library: [Artifact] {
        let threadIds = Set(thread.map(\.id))
        return model.libraryArtifacts.filter { !threadIds.contains($0.id) }
    }

    private var all: [Artifact] { thread + library }

    var body: some View {
        GeometryReader { geo in
            // The list takes a quarter of the width between 200 and 320 points; the detail gets the rest.
            let listWidth = min(320, max(200, geo.size.width * 0.27))
            HStack(spacing: 0) {
                list.frame(width: listWidth).frame(maxHeight: .infinity).clipped()
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            }
        }
        .task {
            loading = true
            await model.refreshLibraryArtifacts()
            shares = (try? await model.api.listShares()) ?? []
            loading = false
            if let want = model.pendingArtifactSelection { selected = want; model.pendingArtifactSelection = nil }
            if selected == nil { selected = all.first?.id }
        }
        .onChange(of: model.pendingArtifactSelection) {
            if let want = model.pendingArtifactSelection { selected = want; model.pendingArtifactSelection = nil }
        }
    }

    private var list: some View {
        List(selection: $selected) {
            if !thread.isEmpty {
                Section("This conversation") { ForEach(thread) { row($0) } }
            }
            Section(conversationId == nil ? "Library" : "Elsewhere in the library") {
                if library.isEmpty && !loading {
                    Text(model.user?.email == nil ? "Sign in to keep artifacts across devices." : "Nothing built yet. Ask Olo to build a page, a chart or a document.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(library) { row($0) }
            }
            if !shares.isEmpty { sharesSection }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func row(_ a: Artifact) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(a.title).lineLimit(1)
            HStack(spacing: 6) {
                Text(a.kind.uppercased())
                if !a.validated { Text("unchecked") }
                if a.repaired { Text("repaired") }
                if let v = a.version, v > 1 { Text("v\(v)") }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .tag(a.id)
    }

    private var sharesSection: some View {
        Section("Share links") {
            ForEach(shares) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.label ?? "\(s.subjectType) \(s.subjectId)").lineLimit(1)
                        Text("\(s.viewCount) view\(s.viewCount == 1 ? "" : "s")" + (s.expiresAt.map { ", expires \($0.prefix(10))" } ?? "")).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { copy(s.url(base: model.api.base).absoluteString) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy link")
                    Button {
                        Task {
                            try? await model.api.revokeShare(token: s.token)
                            shares.removeAll { $0.token == s.token }
                        }
                    } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Revoke: the link stops working for everyone")
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selected, let a = all.first(where: { $0.id == id }) {
            ArtifactDetail(artifact: a, inLibrary: model.libraryArtifacts.contains { $0.id == a.id }) { token in
                if let token { shares.insert(token, at: 0) }
            }
            .id(a.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.richtext").font(.largeTitle).foregroundStyle(.secondary)
                Text(all.isEmpty ? "No artifacts yet" : "Choose an artifact").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        model.banner = "Link copied."
    }
}

/// One artifact: preview or code, with Copy, Save, Share Link and Delete.
struct ArtifactDetail: View {
    let artifact: Artifact
    let inLibrary: Bool
    var onShared: (Share?) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @State private var showCode = false
    @State private var allowScripts = false
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !artifact.issues.isEmpty { issues }
            if artifact.isPreviewable && !showCode {
                if artifact.needsScripts && !allowScripts {
                    scriptsNotice
                } else {
                    // A new web view for each setting: a WKWebView's configuration is fixed when it is made.
                    WebPreview(html: ArtifactPreview.document(for: artifact), allowScripts: allowScripts).id(allowScripts)
                }
            } else {
                codeView
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(artifact.title).font(.headline).lineLimit(1)
                Text(artifact.suggestedFilename).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if artifact.isPreviewable {
                Picker("", selection: $showCode) {
                    Text("Preview").tag(false)
                    Text("Code").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Toggle("Scripts", isOn: $allowScripts).toggleStyle(.checkbox).font(.caption)
                    .help("Off: JavaScript and every network request are blocked. On: the page runs as the web preview does.")
            }
            if artifact.isPreviewable {
                Button { model.openInBrowser(.artifact(artifact)) } label: { Image(systemName: "safari") }
                    .help("Run it in Olo's browser, with scripts, the network and a console, to test it as a visitor would")
            }
            Button { copyCode() } label: { Image(systemName: "doc.on.doc") }.help("Copy the code")
            ArtifactExportMenu(artifact: artifact) { Image(systemName: "square.and.arrow.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Save the file, or export it as PDF, Word or CSV")
            if inLibrary {
                Button {
                    busy = true
                    Task {
                        let share = try? await model.api.createShare(OloAPI.ShareInput(subjectType: "artifact", subjectId: artifact.id, label: artifact.title))
                        if let share {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(share.url(base: model.api.base).absoluteString, forType: .string)
                            model.banner = "Share link copied. Anyone with it can view this artifact."
                        } else {
                            model.banner = "Could not make a share link."
                        }
                        onShared(share)
                        busy = false
                    }
                } label: { Image(systemName: "link") }.help("Copy a share link").disabled(busy)
                Button(role: .destructive) {
                    Task {
                        try? await model.api.deleteArtifact(id: artifact.id)
                        await model.refreshLibraryArtifacts()
                    }
                } label: { Image(systemName: "trash") }.help("Delete from the library")
            }
        }
        .buttonStyle(.borderless)
        .padding(10)
    }

    private var issues: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(artifact.issues.enumerated()), id: \.offset) { _, i in
                Label(i.message, systemImage: i.severity == "error" ? "xmark.octagon" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(i.severity == "error" ? Color.red : Color.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var scriptsNotice: some View {
        VStack(spacing: 10) {
            Image(systemName: "curlybraces").font(.largeTitle).foregroundStyle(.secondary)
            Text("A React preview needs scripts from unpkg.com and JavaScript.").multilineTextAlignment(.center)
            Text("Turn on Scripts above to run it, or read the code.").font(.caption).foregroundStyle(.secondary)
            Button("Show Code") { showCode = true }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The file's text in an AppKit text view. It was one SwiftUI Text inside a two-way ScrollView
    /// with an infinite width: with a long file in the Olo Sample inspector, the window re-ran its
    /// constraints until AppKit stopped it ("needing another Update Constraints in Window pass").
    private var codeView: some View {
        ReadOnlyCodeView(text: artifact.code)
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(artifact.code, forType: .string)
        model.banner = "Copied."
    }

    private func save() { ArtifactFiles.save(artifact) }
}

/// Everything a file Olo built can become: itself, a website folder for Netlify, a PDF, a Word
/// document or a CSV. One menu, used in the Artifacts panel and on the card in the thread.
struct ArtifactExportMenu<MenuLabel: View>: View {
    let artifact: Artifact
    @ViewBuilder let label: () -> MenuLabel

    private var baseName: String {
        let n = (artifact.suggestedFilename as NSString).deletingPathExtension
        return TranscriptExport.safeFilename(n.isEmpty ? artifact.title : n, fallback: "artifact")
    }

    var body: some View {
        Menu {
            Button("Save as \(artifact.suggestedFilename)...") { ArtifactFiles.save(artifact) }
            if artifact.kind == "html" {
                Button("Save as Website Folder for Netlify...") { ArtifactFiles.saveSiteFolder(artifact, name: baseName) }
            }
            Divider()
            Button("Export as PDF...") {
                if artifact.isPreviewable && !artifact.needsScripts {
                    Task { await DocumentWriter.savePDF(html: ArtifactPreview.document(for: artifact), name: baseName) }
                } else {
                    DocumentWriter.savePDF(MarkdownStyler.attributed(artifact.code, title: artifact.title), name: baseName)
                }
            }
            Button("Export as Word (.docx)...") { DocumentWriter.saveWord(MarkdownStyler.attributed(artifact.code, title: artifact.title), name: baseName) }
                .disabled(artifact.isPreviewable)
            Button("Export Tables as CSV...") { DocumentWriter.saveCSV(from: artifact.code, name: baseName) }
                .disabled(!MarkdownTables.hasTable(artifact.code))
        } label: { label() }
    }
}

/// Writing an artifact to disk, as itself or as a website folder.
enum ArtifactFiles {
    @MainActor
    static func save(_ artifact: Artifact) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = artifact.suggestedFilename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(artifact.code.utf8).write(to: url, options: [.atomic]); AppModel.shared.banner = "Saved \(url.lastPathComponent)." }
        catch { AppModel.shared.banner = "Could not save: \(error.localizedDescription)" }
    }

    /// A folder with index.html inside, which Netlify's drop zone (or any static host) takes as a site.
    @MainActor
    static func saveSiteFolder(_ artifact: Artifact, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.prompt = "Save Folder"
        panel.message = "A folder with index.html inside. Drag the folder onto app.netlify.com/drop to publish it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(artifact.code.utf8).write(to: url.appendingPathComponent("index.html"), options: [.atomic])
            AppModel.shared.banner = "Saved \(url.lastPathComponent)/index.html. Drag the folder onto Netlify to publish."
        } catch { AppModel.shared.banner = "Could not save the folder: \(error.localizedDescription)" }
    }
}

/// A file Olo built, shown in the thread under the answer that made it: what it is, Open to
/// preview it, and the export menu. This is where the download lives.
struct ArtifactCard: View {
    let artifact: Artifact
    @Environment(AppModel.self) private var model

    private var symbol: String {
        switch artifact.kind {
        case "html", "react": return "globe"
        case "svg": return "photo"
        case "markdown": return "doc.text"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.title).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(artifact.suggestedFilename).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if !artifact.validated { Text("has errors").font(.caption2).foregroundStyle(.orange) }
                    else if artifact.repaired { Text("repaired").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            Spacer(minLength: 8)
            Button("Open") { model.openSample(artifact) }.controlSize(.small).help("Review it in the Olo Sample panel")
            if artifact.isPreviewable {
                Button("Run") { model.openInBrowser(.artifact(artifact)) }.controlSize(.small)
                    .help("Run it in Olo's browser to test it")
            }
            ArtifactExportMenu(artifact: artifact) { Label("Export", systemImage: "square.and.arrow.down") }
                .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}

/// Read-only, selectable, non-wrapping code in an NSTextView: AppKit lays out a long file once,
/// lazily, instead of SwiftUI measuring the whole text on every pass.
struct ReadOnlyCodeView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.isRichText = false
            tv.drawsBackground = false
            tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.textColor = .textColor
            tv.textContainerInset = NSSize(width: 10, height: 10)
            // No wrapping: long lines scroll sideways, as in an editor.
            tv.isHorizontallyResizable = true
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            tv.textContainer?.widthTracksTextView = false
            tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            tv.string = text
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
    }
}

/// A read-only WKWebView for an artifact. With scripts off, JavaScript is disabled and a
/// content rule blocks every network load, so the page can only draw what it carries.
/// Links never navigate: they open in the browser when they are web links.
struct WebPreview: NSViewRepresentable {
    let html: String
    let allowScripts: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = allowScripts
        config.websiteDataStore = .nonPersistent()
        if !allowScripts, let rules = WebPreview.rules { config.userContentController.add(rules) }
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        load(view, context: context)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        load(view, context: context)
    }

    private func load(_ view: WKWebView, context: Context) {
        context.coordinator.loaded = html
        let html = self.html
        if allowScripts || WebPreview.rules != nil {
            view.loadHTMLString(html, baseURL: nil)
            return
        }
        // The first preview waits for the rule list to compile, so nothing is fetched before it is in place.
        WebPreview.blockAllLoads { rules in
            if let rules { view.configuration.userContentController.add(rules) }
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    /// One compiled rule list, shared: block every URL the page would fetch.
    private static var rules: WKContentRuleList?

    private static func blockAllLoads(_ done: @escaping (WKContentRuleList?) -> Void) {
        if let rules { done(rules); return }
        let json = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "olo.block-all", encodedContentRuleList: json) { list, _ in
            DispatchQueue.main.async {
                rules = list
                done(list)
            }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // The document itself loads; everything else is a link click, which goes to the browser.
            if action.navigationType == .other, action.request.url?.scheme == "about" || action.request.url == nil {
                decisionHandler(.allow)
                return
            }
            if action.navigationType == .linkActivated, let url = action.request.url, LinkPolicy.isSafeExternal(url) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}
