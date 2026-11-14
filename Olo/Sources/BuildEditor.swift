import AppKit
import Observation
import OloKit

/// One open file in Build with Olo's editor. The text view holds the text; `text` mirrors it on
/// every change, and is not observed so typing never redraws the SwiftUI views around it.
@MainActor @Observable
final class EditorDocument {
    /// Relative to the folder, "/" separated.
    let path: String
    let language: String
    let controller: CodeTextController

    @ObservationIgnored var text: String
    /// What is on disk as far as Olo knows (last loaded or saved).
    @ObservationIgnored var savedText: String
    /// Bumped on every change, so a late suggestion can tell it is stale.
    @ObservationIgnored var revision = 0
    /// The text the issues' line numbers refer to.
    @ObservationIgnored var issuesBase: String
    /// The text of the last finished review, sent as `previous` with the next one.
    @ObservationIgnored var reviewedText: String?

    private(set) var dirty = false
    /// The version on disk, when another editor saved the file while it had unsaved edits here.
    var conflictText: String?
    var issues: [CodeIssue] = []
    var summary: String?
    var reviewing = false
    var reviewFailure: String?
    var reviewedOnce = false
    var line = 1
    var column = 1

    init(path: String, text: String) {
        self.path = path
        self.language = CodeLanguage.detect(path)
        self.text = text
        self.savedText = text
        self.issuesBase = text
        self.controller = CodeTextController(path: path, text: text)
    }

    var name: String { (path as NSString).lastPathComponent }

    func updateDirty() {
        let now = text != savedText
        if dirty != now { dirty = now }
    }
}

/// Build with Olo's editor: tabs, saving (Cmd+S and autosave), files changed by other editors,
/// Olo's review as you type with fixes applied into the text (undoable), suggestions as ghost
/// text, and "Tell Olo what to build or change" with a diff to accept or reject. Everything goes
/// to helius-olo.io privately: never stored there, never trained on, never added to the brain.
@MainActor @Observable
final class BuildEditor {
    enum PaneTab: String, CaseIterable {
        case issues = "Issues"
        case change = "Olo's Change"
        case answers = "Answers"
    }

    struct Countdown: Equatable {
        let id = UUID()
        let path: String
        let issueIds: [String]
        var remaining: Int
    }

    struct Proposal {
        let path: String
        let original: String
        let proposed: String
        let explanation: String
        let rows: [DiffRow]
        let selection: CodeEditSelection?
    }

    static let autosaveKey = "build.autosave.v1"
    static let suggestionsKey = "build.suggestions.v1"
    static let needsUpdate = "helius-olo.io needs the v61 update for this"
    static let reviewDelay: UInt64 = 1_200_000_000
    static let completionDelay: UInt64 = 600_000_000
    static let autosaveDelay: UInt64 = 1_000_000_000
    static let countdownSeconds = 3

    private(set) var tabs: [String] = []
    private(set) var docs: [String: EditorDocument] = [:]
    private(set) var currentPath: String?
    var autosave: Bool {
        didSet { UserDefaults.standard.set(autosave, forKey: BuildEditor.autosaveKey) }
    }
    var suggestions: Bool {
        didSet {
            UserDefaults.standard.set(suggestions, forKey: BuildEditor.suggestionsKey)
            if !suggestions { stopCompletion() }
        }
    }
    /// "Fix as I type": off by default, for this session only.
    var fixAsIType = false {
        didSet { if !fixAsIType { cancelCountdown() } }
    }
    private(set) var countdown: Countdown?
    var paneTab: PaneTab = .issues
    private(set) var proposal: Proposal?
    private(set) var writing = false
    var writeFailure: String?
    private(set) var allowance: BuildAllowance?
    private(set) var selectedIssueId: String?

    @ObservationIgnored weak var workspace: BuildWorkspace?
    private let api: OloAPI
    @ObservationIgnored private var reviewTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var saveTimers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var reviewsInFlight: Set<String> = []
    @ObservationIgnored private var reviewAgain: Set<String> = []
    @ObservationIgnored private var completionTimer: Task<Void, Never>?
    @ObservationIgnored private var completionTask: Task<Void, Never>?
    @ObservationIgnored private var completionId: UUID?
    @ObservationIgnored private var completionsOff = false
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var toldNeedsUpdate = false
    @ObservationIgnored private var allowanceMissing = false
    @ObservationIgnored private var allowanceFetchedAt: Date?

    init(api: OloAPI) {
        self.api = api
        let defaults = UserDefaults.standard
        autosave = defaults.object(forKey: BuildEditor.autosaveKey) as? Bool ?? true
        suggestions = defaults.object(forKey: BuildEditor.suggestionsKey) as? Bool ?? true
    }

    var current: EditorDocument? {
        guard let p = currentPath else { return nil }
        return docs[p]
    }

    // MARK: Tabs

    /// Opens a file in a tab (or shows its tab). False when it is not text Olo can edit.
    @discardableResult
    func open(_ rel: String, select: Bool = true) -> Bool {
        if docs[rel] != nil {
            if select { show(rel) }
            return true
        }
        guard let root = workspace?.folderURL else { return false }
        guard let text = BuildEditor.readText(root.appendingPathComponent(rel)) else {
            workspace?.notice = "Olo opens text files up to 1 MB. \(rel) is binary or too large."
            return false
        }
        let doc = EditorDocument(path: rel, text: text)
        wire(doc)
        docs[rel] = doc
        tabs.append(rel)
        if select || currentPath == nil { show(rel) }
        scheduleReview(rel, after: 200_000_000)
        return true
    }

    func show(_ rel: String) {
        guard docs[rel] != nil, currentPath != rel else { return }
        stopCompletion()
        currentPath = rel
        selectedIssueId = nil
        if proposal?.path != rel { proposal = nil }
    }

    private func wire(_ doc: EditorDocument) {
        doc.controller.onTextChange = { [weak self, weak doc] text in
            guard let self, let doc else { return }
            self.textChanged(doc, text)
        }
        doc.controller.onCaretChange = { [weak doc] line, column in
            guard let doc else { return }
            if doc.line != line { doc.line = line }
            if doc.column != column { doc.column = column }
        }
    }

    /// Closes a tab, asking first when it has unsaved edits.
    func close(_ rel: String) {
        guard let doc = docs[rel] else { return }
        if doc.dirty {
            let alert = NSAlert()
            alert.messageText = "Save changes to \(doc.name)?"
            alert.informativeText = "Your changes are lost if you close without saving."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard save(rel, explicit: true) else { return }
            case .alertSecondButtonReturn:
                break
            default:
                return
            }
        }
        discard(rel)
    }

    private func discard(_ rel: String) {
        reviewTimers[rel]?.cancel()
        reviewTimers[rel] = nil
        saveTimers[rel]?.cancel()
        saveTimers[rel] = nil
        if countdown?.path == rel { cancelCountdown() }
        if proposal?.path == rel { proposal = nil }
        if currentPath == rel { stopCompletion() }
        docs[rel]?.controller.scrollView.removeFromSuperview()
        docs[rel] = nil
        let index = tabs.firstIndex(of: rel) ?? 0
        tabs.removeAll { $0 == rel }
        if currentPath == rel {
            currentPath = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]
        }
    }

    /// Saves what can be saved and closes every tab (the folder is changing).
    func closeAll() {
        for rel in tabs where docs[rel]?.dirty == true && docs[rel]?.conflictText == nil {
            save(rel, explicit: false)
        }
        for rel in tabs { discard(rel) }
        selectedIssueId = nil
        writeFailure = nil
        cancelCountdown()
    }

    // MARK: Typing

    private func textChanged(_ doc: EditorDocument, _ text: String) {
        doc.text = text
        doc.revision += 1
        doc.updateDirty()
        // Keep the markers on their lines while the review catches up.
        if !doc.issues.isEmpty {
            let moved = IssueRebaser.rebase(doc.issues, from: doc.issuesBase, to: text)
            if moved != doc.issues {
                doc.issues = moved
                doc.controller.setIssues(moved)
            }
        }
        doc.issuesBase = text
        scheduleReview(doc.path, after: BuildEditor.reviewDelay)
        if doc.dirty { scheduleAutosave(doc.path) }
        if doc.path == currentPath { scheduleCompletion(doc) }
    }

    // MARK: Saving

    private func scheduleAutosave(_ rel: String) {
        saveTimers[rel]?.cancel()
        guard autosave else { return }
        saveTimers[rel] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: BuildEditor.autosaveDelay)
            if Task.isCancelled { return }
            self?.saveTimers[rel] = nil
            self?.save(rel, explicit: false)
        }
    }

    /// Cmd+S.
    func saveCurrent() {
        if let p = currentPath { save(p, explicit: true) }
    }

    /// Writes the file atomically, keeping its permissions. A file that changed on disk while it
    /// had edits here waits for the developer's choice.
    @discardableResult
    func save(_ rel: String, explicit: Bool) -> Bool {
        guard let doc = docs[rel], let root = workspace?.folderURL else { return false }
        if doc.conflictText != nil {
            if explicit { workspace?.notice = "\(doc.name) changed on disk. Choose Keep Mine or Use Disk Version first." }
            return false
        }
        guard doc.dirty || explicit else { return true }
        let url = root.appendingPathComponent(rel)
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        let text = doc.text
        do {
            try Data(text.utf8).write(to: url, options: [.atomic])
        } catch {
            workspace?.notice = "Olo could not save \(rel): \(error.localizedDescription)"
            return false
        }
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        doc.savedText = text
        doc.updateDirty()
        return true
    }

    // MARK: Changes on disk

    /// Files another editor (or tool) saved. An open file without unsaved edits is reloaded; with
    /// unsaved edits the developer chooses. A file that is not open opens in a tab and is reviewed,
    /// unless many files changed at once (a checkout or a build), which would flood the tabs.
    func diskChanged(_ paths: [String]) {
        guard let root = workspace?.folderURL else { return }
        let closed = paths.filter { docs[$0] == nil }
        for rel in paths {
            guard let doc = docs[rel] else { continue }
            guard let disk = BuildEditor.readText(root.appendingPathComponent(rel)) else { continue }
            if disk == doc.text {
                doc.savedText = disk
                doc.conflictText = nil
                doc.updateDirty()
            } else if disk == doc.savedText {
                continue
            } else if !doc.dirty {
                doc.savedText = disk
                doc.controller.replaceText(disk, actionName: "Reload from Disk")
            } else {
                saveTimers[rel]?.cancel()
                saveTimers[rel] = nil
                doc.conflictText = disk
            }
        }
        guard closed.count <= 3 else { return }
        for rel in closed where CodeLanguage.isReviewable(rel) {
            open(rel, select: currentPath == nil)
        }
    }

    /// Keeps the text in the editor; the next save replaces the disk version.
    func keepMine(_ rel: String) {
        guard let doc = docs[rel], let disk = doc.conflictText else { return }
        doc.conflictText = nil
        doc.savedText = disk
        doc.updateDirty()
        if doc.dirty { scheduleAutosave(rel) }
    }

    /// Takes the version on disk (undoable).
    func useDisk(_ rel: String) {
        guard let doc = docs[rel], let disk = doc.conflictText else { return }
        doc.conflictText = nil
        doc.savedText = disk
        doc.controller.replaceText(disk, actionName: "Use Disk Version")
        doc.updateDirty()
    }

    // MARK: New files and folders

    /// A safe path inside the folder: no absolute paths, no "..", no empty parts.
    nonisolated static func cleanRelativePath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return nil }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return parts.joined(separator: "/")
    }

    func createFile(_ raw: String) {
        guard let root = workspace?.folderURL else { return }
        guard let rel = BuildEditor.cleanRelativePath(raw) else {
            workspace?.notice = "Type a name inside the folder, for example src/main.swift."
            return
        }
        let url = root.appendingPathComponent(rel)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            open(rel)
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url, options: [.atomic])
        } catch {
            workspace?.notice = "Olo could not create \(rel): \(error.localizedDescription)"
            return
        }
        workspace?.tree.invalidate(parentOf: rel)
        open(rel)
        current?.controller.focus()
    }

    func createFolder(_ raw: String) {
        guard let root = workspace?.folderURL else { return }
        guard let rel = BuildEditor.cleanRelativePath(raw) else {
            workspace?.notice = "Type a folder name inside the project, for example src/utils."
            return
        }
        do {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(rel), withIntermediateDirectories: true)
        } catch {
            workspace?.notice = "Olo could not create \(rel): \(error.localizedDescription)"
            return
        }
        workspace?.tree.invalidate(parentOf: rel)
        workspace?.tree.expand(rel)
    }

    /// Text Olo can open: up to 1 MB, no NUL bytes near the start, UTF-8.
    nonisolated static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count <= 1_000_000 else { return nil }
        if data.prefix(8_192).contains(0) { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Review as you type

    private func scheduleReview(_ rel: String, after delay: UInt64) {
        reviewTimers[rel]?.cancel()
        guard CodeLanguage.isReviewable(rel) else { return }
        reviewTimers[rel] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            await self?.review(rel)
        }
    }

    /// Reviews the open text (not only what is saved), with the last reviewed text as context. At
    /// most one review per file is in flight; a change during a review is reviewed when it returns.
    func review(_ rel: String) async {
        reviewTimers[rel] = nil
        guard let doc = docs[rel] else { return }
        if reviewsInFlight.contains(rel) {
            reviewAgain.insert(rel)
            return
        }
        let snapshot = doc.text
        if snapshot == doc.reviewedText && doc.reviewFailure == nil { return }
        if snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setReview(doc, issues: [], summary: nil, snapshot: snapshot)
            return
        }
        guard snapshot.count <= CodeReviewInput.maxContent else {
            doc.reviewFailure = "This file is too long for Olo to review (over 60,000 characters)."
            return
        }
        guard let app = workspace?.app, app.canReachCloud else {
            doc.reviewFailure = "Olo reviews in the cloud, so it needs a connection."
            return
        }
        reviewsInFlight.insert(rel)
        doc.reviewing = true
        doc.reviewFailure = nil
        do {
            try await app.ensureSession()
            let result = try await api.reviewCode(CodeReviewInput(path: rel, content: snapshot, previous: doc.reviewedText))
            if docs[rel] === doc {
                setReview(doc, issues: result.sorted, summary: result.summary, snapshot: snapshot)
                if fixAsIType { startCountdown(rel) }
            }
            refreshAllowance()
        } catch let e as TRPC.RemoteError where e.isUnauthorized {
            doc.reviewFailure = "Sign in to use Build with Olo."
        } catch let e as TRPC.RemoteError where e.isNotFound {
            doc.reviewFailure = "helius-olo.io does not offer code review yet."
        } catch let e as TRPC.RemoteError where e.isAllowanceExhausted {
            doc.reviewFailure = e.message
        } catch {
            doc.reviewFailure = error.localizedDescription
        }
        doc.reviewing = false
        reviewsInFlight.remove(rel)
        if reviewAgain.remove(rel) != nil { scheduleReview(rel, after: 300_000_000) }
    }

    /// Stores a review of `snapshot`, moved onto the text as it is now.
    private func setReview(_ doc: EditorDocument, issues: [CodeIssue], summary: String?, snapshot: String) {
        let mapped = IssueRebaser.rebase(issues, from: snapshot, to: doc.text)
        doc.issues = mapped
        doc.issuesBase = doc.text
        doc.summary = (summary?.isEmpty ?? true) ? nil : summary
        doc.reviewedText = snapshot
        doc.reviewedOnce = true
        doc.reviewFailure = nil
        doc.controller.setIssues(mapped)
        if let id = selectedIssueId, !mapped.contains(where: { $0.id == id }) { selectedIssueId = nil }
    }

    // MARK: Fixes (into the text, undoable)

    /// Applies one issue's fix to the text in the editor. Cmd+Z undoes it.
    func apply(_ issue: CodeIssue) {
        guard let p = currentPath else { return }
        let n = applyMany([issue], in: p)
        if n == 0 { workspace?.notice = "That fix no longer fits the code. Olo will look again in a moment." }
    }

    /// "Apply all safe fixes": information and style only.
    func applySafeFixes() {
        guard let p = currentPath, let doc = docs[p] else { return }
        let n = applyMany(doc.issues.filter(\.isSafe), in: p)
        if n > 0 { workspace?.notice = "Applied \(n) safe fix\(n == 1 ? "" : "es"). Cmd+Z undoes them." }
    }

    /// Applies several fixes together as one undoable step (overlapping ones wait for the next review).
    @discardableResult
    private func applyMany(_ chosen: [CodeIssue], in rel: String) -> Int {
        guard let doc = docs[rel], !chosen.isEmpty else { return 0 }
        var source = SourceText(doc.text)
        let count = source.lines.count
        let fixes = FixApplier.nonOverlapping(chosen.compactMap(\.fix), count: count)
        guard !fixes.isEmpty, let lines = try? FixApplier.applyAll(fixes, to: source.lines) else { return 0 }
        source.lines = lines
        let applied = Set(chosen.filter { issue in issue.fix.map { f in fixes.contains(f) } ?? false }.map(\.id))
        doc.issues.removeAll { applied.contains($0.id) }
        doc.controller.setIssues(doc.issues)
        if let id = selectedIssueId, applied.contains(id) { selectedIssueId = nil }
        doc.controller.replaceText(source.text, actionName: fixes.count == 1 ? "Olo Fix" : "Olo Fixes")
        return fixes.count
    }

    func jump(to issue: CodeIssue) {
        selectedIssueId = issue.id
        current?.controller.reveal(line: issue.line)
    }

    // MARK: Fix as I type

    private func startCountdown(_ rel: String) {
        let ids = (docs[rel]?.issues ?? []).filter(\.autoFixable).map(\.id)
        guard !ids.isEmpty else { return }
        if let c = countdown, c.path == rel, c.issueIds == ids { return }
        cancelCountdown()
        let started = Countdown(path: rel, issueIds: ids, remaining: BuildEditor.countdownSeconds)
        countdown = started
        countdownTask = Task { [weak self] in
            for _ in 0..<BuildEditor.countdownSeconds {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                guard let editor = self, editor.countdown?.id == started.id else { return }
                editor.countdown?.remaining -= 1
            }
            guard let editor = self, editor.countdown?.id == started.id else { return }
            editor.countdown = nil
            editor.countdownTask = nil
            let chosen = (editor.docs[rel]?.issues ?? []).filter { started.issueIds.contains($0.id) && $0.fix != nil }
            let n = editor.applyMany(chosen, in: rel)
            if n > 0 { editor.workspace?.notice = "Olo fixed \(n) issue\(n == 1 ? "" : "s") in \((rel as NSString).lastPathComponent). Cmd+Z undoes it." }
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    // MARK: Suggestions as you type

    private func stopCompletion() {
        completionTimer?.cancel()
        completionTimer = nil
        completionTask?.cancel()
        completionTask = nil
        completionId = nil
        current?.controller.clearGhost()
    }

    private func scheduleCompletion(_ doc: EditorDocument) {
        stopCompletion()
        guard suggestions, !completionsOff, CodeLanguage.isReviewable(doc.path) else { return }
        completionTimer = Task { [weak self, weak doc] in
            try? await Task.sleep(nanoseconds: BuildEditor.completionDelay)
            if Task.isCancelled { return }
            guard let self, let doc else { return }
            self.completionTimer = nil
            self.requestCompletion(doc)
        }
    }

    /// Asks code.complete for the text at the cursor. Never while another request is in flight;
    /// a keystroke cancels the request (stopCompletion), so a stale answer is never shown.
    private func requestCompletion(_ doc: EditorDocument) {
        guard completionTask == nil, doc.path == currentPath, let context = doc.controller.completionContext() else { return }
        guard let app = workspace?.app, app.canReachCloud, app.api.token != nil else { return }
        let revision = doc.revision
        let input = CodeCompleteInput(path: doc.path, prefix: context.prefix, suffix: context.suffix, language: doc.language)
        let id = UUID()
        completionId = id
        let api = self.api
        completionTask = Task { [weak self, weak doc] in
            var suggestion = ""
            var failure: TRPC.RemoteError?
            do {
                let result = try await api.completeCode(input)
                suggestion = CompletionCleanup.clean(result.completion, prefix: context.prefix, suffix: context.suffix)
            } catch let e as TRPC.RemoteError {
                failure = e
            } catch {
                // Cancelled by a keystroke, or the network: nothing to show.
            }
            // Another request replaced this one, or a keystroke stopped it: nothing of ours to clear.
            guard let self, self.completionId == id else { return }
            self.completionTask = nil
            self.completionId = nil
            if let failure {
                self.completionFailed(failure)
                return
            }
            guard !Task.isCancelled, !suggestion.isEmpty, let doc, doc.revision == revision, doc.path == self.currentPath else { return }
            doc.controller.showGhost(suggestion, at: context.location)
        }
    }

    private func completionFailed(_ e: TRPC.RemoteError) {
        if e.isNotFound {
            completionsOff = true
            tellNeedsUpdate()
        } else if e.isAllowanceExhausted {
            completionsOff = true
            workspace?.notice = "\(e.message). Suggestions are paused until tomorrow; reviews and the editor keep working."
        }
    }

    /// Shown once per session: the server has not got Build with Olo v2 yet. The editor keeps working.
    private func tellNeedsUpdate() {
        guard !toldNeedsUpdate else { return }
        toldNeedsUpdate = true
        workspace?.notice = BuildEditor.needsUpdate + ". The editor keeps working without it."
    }

    // MARK: Ask Olo to write

    /// Sends the open file (and the selected lines, if any) with the instruction to code.edit and
    /// shows the answer as a diff to accept or reject.
    func askToWrite(_ instruction: String) {
        let ask = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let doc = current, !ask.isEmpty, !writing else { return }
        paneTab = .change
        proposal = nil
        let original = doc.text
        guard CodeEditInput.fits(original) else {
            writeFailure = "This file is too long for Olo to rewrite (over 60,000 characters). Select a part of it, or split it."
            return
        }
        guard let app = workspace?.app, app.canReachCloud else {
            writeFailure = "Olo writes in the cloud, so it needs a connection."
            return
        }
        let selection = doc.controller.selectedLines()
        let input = CodeEditInput(path: doc.path, content: original, instruction: ask, selection: selection, language: doc.language)
        let path = doc.path
        writing = true
        writeFailure = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await app.ensureSession()
                let result = try await self.api.editCode(input)
                let rows = await Task.detached(priority: .userInitiated) {
                    LineDiff.rows(old: SourceText(original).lines, new: SourceText(result.content).lines)
                }.value
                if self.docs[path] != nil {
                    self.proposal = Proposal(path: path, original: original, proposed: result.content,
                                             explanation: result.explanation, rows: rows, selection: selection)
                }
            } catch let e as TRPC.RemoteError where e.isNotFound {
                self.writeFailure = BuildEditor.needsUpdate + "."
                self.toldNeedsUpdate = true
            } catch let e as TRPC.RemoteError where e.isUnauthorized {
                self.writeFailure = "Sign in to use Build with Olo."
            } catch {
                self.writeFailure = error.localizedDescription
            }
            self.writing = false
            self.refreshAllowance()
        }
    }

    /// Puts Olo's version into the editor as one undoable step.
    func acceptProposal() {
        guard let p = proposal, let doc = docs[p.path] else { return }
        if currentPath != p.path { show(p.path) }
        doc.controller.replaceText(p.proposed, actionName: "Olo Change")
        proposal = nil
        workspace?.notice = "Olo's change is in \(doc.name). Cmd+Z undoes it."
    }

    func rejectProposal() {
        proposal = nil
    }

    /// Whether the file changed after Olo was asked (accepting then replaces those edits too).
    var proposalIsStale: Bool {
        guard let p = proposal, let doc = docs[p.path] else { return false }
        return doc.text != p.original
    }

    // MARK: Explain this

    /// Sends the selection (or the whole file) through the private ask flow.
    func explain() {
        guard let doc = current, let ws = workspace else { return }
        let selected = doc.controller.selectedText()
        let lines = doc.controller.selectedLines()
        let name = lines.map { "\(doc.path), lines \($0.startLine) to \($0.endLine)" } ?? doc.path
        let body = selected.isEmpty ? doc.text : selected
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            workspace?.notice = "There is nothing to explain yet: the file is empty."
            return
        }
        ws.askPrivately("Explain this code: what it does, how it works, and anything that looks wrong.", name: name, text: body, doc: doc)
        paneTab = .answers
    }

    // MARK: Allowance

    /// code.allowance, at most every 15 seconds; quietly absent on a server without it.
    func refreshAllowance() {
        guard !allowanceMissing else { return }
        if let at = allowanceFetchedAt, Date().timeIntervalSince(at) < 15 { return }
        guard let app = workspace?.app, app.canReachCloud, app.api.token != nil else { return }
        allowanceFetchedAt = Date()
        let api = self.api
        Task { [weak self] in
            do {
                let value = try await api.buildAllowance()
                self?.allowance = value
            } catch let e as TRPC.RemoteError where e.isNotFound {
                self?.allowanceMissing = true
            } catch {
                // Not worth a notice: the status line just leaves it out.
            }
        }
    }
}
