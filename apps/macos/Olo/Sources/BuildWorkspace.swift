import AppKit
import Observation
import OloKit

/// Build with Olo: a project folder watched for saves. Each saved source file is reviewed by
/// helius-olo.io (code.review) with the previous saved version for context, and the issues come
/// back with fixes the developer can apply. Code is sent only to be reviewed: the server never
/// stores it, never trains on it and never adds it to the brain. The chat about a file is a
/// private chat. Everything happens on the main actor except reading FSEvents.
@MainActor @Observable
final class BuildWorkspace {
    struct ReviewedFile: Identifiable, Equatable {
        var id: String { path }
        /// Relative to the folder, "/" separated.
        let path: String
        /// The text last read from disk.
        var content: String
        /// The text the issues refer to (nil before the first review).
        var reviewedContent: String?
        var issues: [CodeIssue] = []
        var summary: String?
        var model: String?
        var reviewing = false
        var failure: String?
        var reviewedAt: Date?
    }

    struct Countdown: Equatable {
        let id = UUID()
        let path: String
        let issueIds: [String]
        var remaining: Int
    }

    struct UndoSnapshot {
        let text: String
        let issues: [CodeIssue]
        let reviewedContent: String?
    }

    static let bookmarkKey = "build.folder.bookmark.v1"
    static let debounceNanoseconds: UInt64 = 1_500_000_000
    static let countdownSeconds = 3

    private(set) var folderURL: URL?
    private(set) var files: [String: ReviewedFile] = [:]
    /// Paths, most recently saved first.
    private(set) var order: [String] = []
    /// The file shown in the code view.
    private(set) var currentPath: String?
    /// "Fix as I save": off by default, kept for this session only.
    var fixAsISave = false
    private(set) var countdown: Countdown?
    var notice: String?
    private(set) var jumpLine: Int?
    /// Changes whenever the code view should scroll to jumpLine.
    private(set) var jumpToken = 0
    private(set) var selectedIssueId: String?
    /// Files with something to undo.
    private(set) var undoable: Set<String> = []
    /// The private conversation behind the chat box in the Olo pane.
    private(set) var chatConversationId: UUID?

    @ObservationIgnored weak var app: AppModel?
    private let api: OloAPI
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var accessing: URL?
    @ObservationIgnored private var resolvedRoot: String?
    @ObservationIgnored private var ignore = ReviewIgnore()
    @ObservationIgnored private var debounce: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var again: Set<String> = []
    @ObservationIgnored private var ownWrites: [String: String] = [:]
    @ObservationIgnored private var undoStacks: [String: [UndoSnapshot]] = [:]
    @ObservationIgnored private var countdownTask: Task<Void, Never>?

    init(api: OloAPI) {
        self.api = api
    }

    var current: ReviewedFile? {
        guard let p = currentPath else { return nil }
        return files[p]
    }

    var folderName: String { folderURL?.lastPathComponent ?? "" }

    var issueCount: Int { files.values.reduce(0) { $0 + $1.issues.count } }

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
        panel.prompt = "Watch with Olo"
        panel.message = "Olo reviews each source file in this folder when you save it, in any editor. Files change only when you apply a fix."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Read and write: fixes are written back to the files.
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
        files = [:]
        order = []
        currentPath = nil
        undoStacks = [:]
        undoable = []
        chatConversationId = nil
        reloadIgnore()
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
        for t in debounce.values { t.cancel() }
        debounce = [:]
        cancelCountdown()
        if let a = accessing {
            a.stopAccessingSecurityScopedResource()
            accessing = nil
        }
        if forget {
            folderURL = nil
            resolvedRoot = nil
            files = [:]
            order = []
            currentPath = nil
            undoStacks = [:]
            undoable = []
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

    // MARK: Saves

    private func changed(_ paths: [String]) {
        guard folderURL != nil else { return }
        for p in Set(paths) {
            guard let rel = relativePath(p), !rel.isEmpty else { continue }
            if rel == ".gitignore" { reloadIgnore(); continue }
            guard CodeLanguage.isReviewable(rel), !ignore.ignores(rel) else { continue }
            schedule(rel)
        }
    }

    /// Waits 1.5 seconds after the last save of a file before reviewing it.
    private func schedule(_ rel: String) {
        debounce[rel]?.cancel()
        debounce[rel] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: BuildWorkspace.debounceNanoseconds)
            if Task.isCancelled { return }
            await self?.review(rel)
        }
    }

    /// Reviews one file: at most one review in flight per file; a save during a review is
    /// reviewed again when the first one returns.
    func review(_ rel: String) async {
        debounce[rel] = nil
        guard let root = folderURL else { return }
        if inFlight.contains(rel) {
            again.insert(rel)
            return
        }
        guard let data = try? Data(contentsOf: root.appendingPathComponent(rel)), let text = ReviewIgnore.text(from: data) else { return }
        let ownWrite = ownWrites[rel] == text
        ownWrites[rel] = nil
        let existing = files[rel]
        // Saved without a change (or touched): nothing new to review.
        if let existing, existing.reviewedContent == text, existing.failure == nil, !ownWrite { return }
        let previous = existing?.content
        var file = existing ?? ReviewedFile(path: rel, content: text)
        file.content = text
        file.reviewing = true
        file.failure = nil
        files[rel] = file
        order.removeAll { $0 == rel }
        order.insert(rel, at: 0)
        if !ownWrite || currentPath == nil { show(rel) }

        guard let app, app.canReachCloud else {
            files[rel]?.reviewing = false
            files[rel]?.failure = "Build with Olo reviews in the cloud, so it needs a connection."
            return
        }
        inFlight.insert(rel)
        do {
            try await app.ensureSession()
            let result = try await api.reviewCode(CodeReviewInput(path: rel, content: text, previous: previous))
            files[rel]?.issues = result.sorted
            files[rel]?.summary = result.summary.isEmpty ? nil : result.summary
            files[rel]?.model = result.model.isEmpty ? nil : result.model
            files[rel]?.reviewedContent = text
            files[rel]?.reviewedAt = Date()
            if fixAsISave && !ownWrite { startCountdown(rel) }
        } catch let e as TRPC.RemoteError where e.isUnauthorized {
            files[rel]?.failure = "Sign in to use Build with Olo."
        } catch let e as TRPC.RemoteError where e.isNotFound {
            files[rel]?.failure = "helius-olo.io does not offer code review yet. Try again after the next update."
        } catch {
            files[rel]?.failure = error.localizedDescription
        }
        files[rel]?.reviewing = false
        inFlight.remove(rel)
        if again.remove(rel) != nil { schedule(rel) }
    }

    // MARK: Showing

    func show(_ rel: String) {
        guard currentPath != rel else { return }
        currentPath = rel
        jumpLine = nil
        selectedIssueId = nil
    }

    /// Shows the file and scrolls to the issue's line.
    func jump(to issue: CodeIssue, in rel: String) {
        currentPath = rel
        selectedIssueId = issue.id
        jumpLine = issue.line
        jumpToken += 1
    }

    // MARK: Fixes

    /// The text on disk, if it is still what Olo reviewed (a fix only fits that text).
    private func reviewedTextOnDisk(_ rel: String) -> String? {
        guard let root = folderURL, let file = files[rel] else { return nil }
        guard let data = try? Data(contentsOf: root.appendingPathComponent(rel)), let disk = ReviewIgnore.text(from: data) else {
            notice = "Olo could not read \(rel)."
            return nil
        }
        guard disk == file.reviewedContent else {
            notice = "\(rel) changed since Olo reviewed it. The new review will be ready in a moment."
            return nil
        }
        return disk
    }

    /// Applies one issue's fix: its lines are replaced, the file is written atomically, and the
    /// text before is kept for Undo.
    func applyFix(_ issue: CodeIssue, in rel: String) {
        guard let fix = issue.fix, let file = files[rel], let disk = reviewedTextOnDisk(rel) else { return }
        var source = SourceText(disk)
        let count = source.lines.count
        source.lines = FixApplier.apply(fix, to: source.lines)
        let remaining = FixApplier.rebase(file.issues.filter { $0.id != issue.id }, after: fix, count: count)
        let before = UndoSnapshot(text: disk, issues: file.issues, reviewedContent: file.reviewedContent)
        if write(source.text, to: rel, undo: before, issues: remaining) {
            selectedIssueId = nil
        }
    }

    /// "Apply all safe fixes": information and style only.
    func applySafeFixes(in rel: String) {
        let safe = (files[rel]?.issues ?? []).filter(\.isSafe)
        let n = applyMany(safe, in: rel)
        if n > 0 { notice = "Applied \(n) safe fix\(n == 1 ? "" : "es") in \(rel)." }
    }

    /// Applies the fixes of several issues together (overlapping ones are left for the next review).
    /// Returns how many were applied.
    @discardableResult
    private func applyMany(_ chosen: [CodeIssue], in rel: String) -> Int {
        guard !chosen.isEmpty, let file = files[rel], let disk = reviewedTextOnDisk(rel) else { return 0 }
        var source = SourceText(disk)
        let count = source.lines.count
        let fixes = FixApplier.nonOverlapping(chosen.compactMap(\.fix), count: count)
        guard !fixes.isEmpty, let lines = try? FixApplier.applyAll(fixes, to: source.lines) else { return 0 }
        source.lines = lines
        let applied = Set(chosen.filter { issue in issue.fix.map { fixes.contains($0) } ?? false }.map(\.id))
        var remaining = file.issues.filter { !applied.contains($0.id) }
        // Bottom up, so each fix moves only the issues below it.
        let bottomUp = fixes.sorted { FixApplier.clampedRange($0, count: count).lower > FixApplier.clampedRange($1, count: count).lower }
        for f in bottomUp { remaining = FixApplier.rebase(remaining, after: f, count: count) }
        let before = UndoSnapshot(text: disk, issues: file.issues, reviewedContent: file.reviewedContent)
        return write(source.text, to: rel, undo: before, issues: remaining) ? fixes.count : 0
    }

    /// Writes the file atomically. Olo's own write is still reviewed again, but never auto-fixed.
    @discardableResult
    private func write(_ text: String, to rel: String, undo: UndoSnapshot?, issues: [CodeIssue]) -> Bool {
        guard let root = folderURL else { return false }
        do {
            try Data(text.utf8).write(to: root.appendingPathComponent(rel), options: [.atomic])
        } catch {
            notice = "Olo could not write \(rel): \(error.localizedDescription)"
            return false
        }
        ownWrites[rel] = text
        if let undo {
            var stack = undoStacks[rel] ?? []
            stack.append(undo)
            undoStacks[rel] = Array(stack.suffix(20))
            undoable.insert(rel)
        }
        files[rel]?.content = text
        files[rel]?.reviewedContent = text
        files[rel]?.issues = issues
        return true
    }

    /// Puts back the text from before Olo's last fix, unless the file was edited since.
    func undo(_ rel: String) {
        guard var stack = undoStacks[rel], !stack.isEmpty, let root = folderURL else { return }
        let snapshot = stack.removeLast()
        guard let data = try? Data(contentsOf: root.appendingPathComponent(rel)), let disk = ReviewIgnore.text(from: data), disk == files[rel]?.content else {
            notice = "\(rel) was edited after Olo's fix, so Undo was not applied. Use your editor's undo."
            return
        }
        if write(snapshot.text, to: rel, undo: nil, issues: snapshot.issues) {
            files[rel]?.reviewedContent = snapshot.reviewedContent
            undoStacks[rel] = stack
            if stack.isEmpty { undoable.remove(rel) }
        }
    }

    // MARK: Fix as I save

    /// After a review, errors that are bugs or security holes are fixed after a countdown the
    /// developer can cancel.
    private func startCountdown(_ rel: String) {
        let ids = (files[rel]?.issues ?? []).filter(\.autoFixable).map(\.id)
        guard !ids.isEmpty else { return }
        cancelCountdown()
        let started = Countdown(path: rel, issueIds: ids, remaining: Self.countdownSeconds)
        countdown = started
        countdownTask = Task { [weak self] in
            for _ in 0..<BuildWorkspace.countdownSeconds {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                guard let ws = self, ws.countdown?.id == started.id else { return }
                ws.countdown?.remaining -= 1
            }
            guard let ws = self, ws.countdown?.id == started.id else { return }
            ws.countdown = nil
            ws.countdownTask = nil
            let chosen = (ws.files[rel]?.issues ?? []).filter { started.issueIds.contains($0.id) }
            let n = ws.applyMany(chosen, in: rel)
            if n > 0 { ws.notice = "Olo fixed \(n) issue\(n == 1 ? "" : "s") in \(rel). Undo is above the list." }
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    // MARK: Asking about the file

    /// Asks Olo about the file in view: the text goes as an attachment, with Olo's review, through
    /// the normal ask flow in a private chat (never stored on the server, never the brain).
    func askAboutCurrentFile(_ question: String) {
        guard let app, let file = current else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let cid: UUID
        if let existing = chatConversationId, app.conversation(existing)?.isPrivate == true {
            cid = existing
        } else {
            cid = app.newPrivateConversation(title: "Build with Olo: \(folderName)", select: false)
            chatConversationId = cid
        }
        var attachments = [Attachment(kind: .file, name: file.path, text: file.content)]
        if !file.issues.isEmpty {
            let lines = file.issues.map { i in "Line \(i.line): \(i.severity), \(i.category): \(i.message)" }
            let review = (file.summary.map { [$0] } ?? []) + lines
            attachments.append(Attachment(kind: .file, name: "Olo's review of \(file.path)", text: review.joined(separator: "\n")))
        }
        app.ask(q, attachments: attachments, in: cid)
    }
}
