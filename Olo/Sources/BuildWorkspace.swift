import AppKit
import Observation
import OloKit

/// Build with Olo: a project folder opened in Olo's own editor (BuildEditor) and watched for
/// saves from any other editor. Each file is reviewed by helius-olo.io (code.review) as you type,
/// Olo suggests and writes code (code.complete, code.edit), and fixes go into the editor's text
/// with undo. Code is sent only to be reviewed or written: the server never stores it, never
/// trains on it and never adds it to the brain. The chat about a file is a private chat.
/// Everything happens on the main actor except reading FSEvents.
@MainActor @Observable
final class BuildWorkspace {
    static let bookmarkKey = "build.folder.bookmark.v1"

    private(set) var folderURL: URL?
    var notice: String?
    /// The private conversation behind the Answers tab in the Olo pane.
    private(set) var chatConversationId: UUID?
    let editor: BuildEditor
    let tree: BuildFileTree

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var accessing: URL?
    @ObservationIgnored private var resolvedRoot: String?
    @ObservationIgnored private(set) var ignore = ReviewIgnore()

    init(api: OloAPI) {
        editor = BuildEditor(api: api)
        tree = BuildFileTree()
        editor.workspace = self
        tree.workspace = self
    }

    var folderName: String { folderURL?.lastPathComponent ?? "" }

    // MARK: The folder

    /// Opens the folder chosen last time, if its bookmark still resolves.
    func restore() {
        guard folderURL == nil, let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            return
        }
        open(url, refreshBookmark: stale)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open with Olo"
        panel.message = "Olo opens this folder in its editor and reviews your code as you type. Files saved in other editors are picked up too."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Read and write: the editor saves files and makes new ones.
        if let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
        open(url, refreshBookmark: false)
    }

    private func open(_ url: URL, refreshBookmark: Bool) {
        stopWatching(forget: false)
        let granted = url.startAccessingSecurityScopedResource()
        accessing = granted ? url : nil
        if refreshBookmark, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
        }
        folderURL = url.standardizedFileURL
        resolvedRoot = url.resolvingSymlinksInPath().standardizedFileURL.path
        chatConversationId = nil
        reloadIgnore()
        tree.reset()
        let w = FolderWatcher { [weak self] paths in
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.changed(paths) } }
        }
        if w.start(path: url.path) {
            watcher = w
            notice = nil
        } else {
            notice = "Olo could not watch this folder. Choose it again, or another one."
        }
    }

    /// Stops watching. With `forget`, the folder is closed and not reopened next time.
    func stopWatching(forget: Bool = true) {
        watcher?.stop()
        watcher = nil
        // Edits are saved before the folder closes (the security scope ends below).
        editor.closeAll()
        if let a = accessing {
            a.stopAccessingSecurityScopedResource()
            accessing = nil
        }
        if forget {
            folderURL = nil
            resolvedRoot = nil
            tree.reset()
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        }
    }

    private func reloadIgnore() {
        guard let root = folderURL else { return }
        let gitignore = try? String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
        ignore = ReviewIgnore(gitignore: gitignore)
    }

    /// The path relative to the folder, or nil when it is outside it.
    private func relativePath(_ absolute: String) -> String? {
        let candidates = [folderURL?.path, resolvedRoot].compactMap { $0 }
        let standard = URL(fileURLWithPath: absolute).standardizedFileURL.path
        for root in candidates {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if standard.hasPrefix(prefix) { return String(standard.dropFirst(prefix.count)) }
            if absolute.hasPrefix(prefix) { return String(absolute.dropFirst(prefix.count)) }
        }
        return nil
    }

    // MARK: Saves from other editors

    private func changed(_ paths: [String]) {
        guard folderURL != nil else { return }
        var saved: [String] = []
        for p in Set(paths) {
            guard let rel = relativePath(p), !rel.isEmpty else { continue }
            if rel == ".gitignore" {
                reloadIgnore()
                tree.refresh()
                continue
            }
            guard !ignore.ignores(rel) else { continue }
            tree.invalidate(parentOf: rel)
            saved.append(rel)
        }
        if !saved.isEmpty { editor.diskChanged(saved.sorted()) }
    }

    // MARK: Asking about the file

    /// Asks Olo about code through the normal ask flow, in a private chat (never stored on the
    /// server, never the brain): the code goes as an attachment, with Olo's review of the file.
    func askPrivately(_ question: String, name: String, text: String, doc: EditorDocument?) {
        guard let app else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let cid: UUID
        if let existing = chatConversationId, app.conversation(existing)?.isPrivate == true {
            cid = existing
        } else {
            cid = app.newPrivateConversation(title: "Build with Olo: \(folderName)", select: false)
            chatConversationId = cid
        }
        var attachments = [Attachment(kind: .file, name: name, text: text)]
        if let doc, !doc.issues.isEmpty {
            let lines = doc.issues.map { i in "Line \(i.line): \(i.severity), \(i.category): \(i.message)" }
            let review = (doc.summary.map { [$0] } ?? []) + lines
            attachments.append(Attachment(kind: .file, name: "Olo's review of \(doc.path)", text: review.joined(separator: "\n")))
        }
        app.ask(q, attachments: attachments, in: cid)
    }

    /// A question about the file in the editor (the box under the answers).
    func askAboutCurrentFile(_ question: String) {
        guard let doc = editor.current else { return }
        askPrivately(question, name: doc.path, text: doc.text, doc: doc)
    }
}
