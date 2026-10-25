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
        guard let id = conversationId, let c = model.conversation(id) else { return [] }
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
        HSplitView {
            list.frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            detail.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            loading = true
            await model.refreshLibraryArtifacts()
            shares = (try? await model.api.listShares()) ?? []
            loading = false
            if selected == nil { selected = all.first?.id }
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
        .listStyle(.sidebar)
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
            Button { copyCode() } label: { Image(systemName: "doc.on.doc") }.help("Copy the code")
            Button { save() } label: { Image(systemName: "square.and.arrow.down") }.help("Save as a file")
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

    private var codeView: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(artifact.code)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(artifact.code, forType: .string)
        model.banner = "Copied."
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = artifact.suggestedFilename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(artifact.code.utf8).write(to: url, options: [.atomic]) }
        catch { model.banner = "Could not save: \(error.localizedDescription)" }
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
