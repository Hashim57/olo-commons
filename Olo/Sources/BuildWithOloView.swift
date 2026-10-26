import SwiftUI
import OloKit

/// The words Build with Olo uses about privacy, in one place.
enum BuildText {
    static let privacy = "Code is sent to helius-olo.io only to be reviewed, completed or rewritten. It is never stored there, never used for training and never added to the Olo brain. Build with Olo is always private."
    static let chatNote = "Private: the code goes with your question and is never saved on the server or added to the brain."
    static let fixAsITypeHelp = "After each review, errors that are bugs or security holes are fixed in the editor after a 3 second countdown you can cancel. Cmd+Z undoes a fix."
    static let suggestionsHelp = "When you pause at the end of a line, Olo suggests what comes next in grey. Tab accepts it, Esc or any other key dismisses it."
    static let autosaveHelp = "Saves the file 1 second after you stop typing. Cmd+S saves at any time."
}

/// Build with Olo: the folder's files on the left, Olo's editor in the middle (reviewed as you
/// type, with suggestions), and the Olo pane on the right (issues, Olo's changes, answers).
/// Files saved in other editors are picked up too, because Olo also watches the folder.
struct BuildWithOloView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ws = model.buildWorkspace
        Group {
            if ws.folderURL == nil {
                BuildEmptyState()
            } else {
                HSplitView {
                    BuildFileTreeView()
                        .frame(minWidth: 170, idealWidth: 220, maxWidth: 360, maxHeight: .infinity)
                    BuildEditorPane()
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    BuildOloPane()
                        .frame(minWidth: 290, idealWidth: 360, maxWidth: 520, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            ws.restore()
            ws.editor.refreshAllowance()
        }
    }
}

struct BuildEmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hammer")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Build with Olo").font(.largeTitle.weight(.semibold))
            Text("Choose a project folder and code with Olo: open files from the list, type in Olo's editor, and Olo reviews as you type, suggests the next lines and writes code when you ask. Files you save in Xcode, VS Code or any other editor are picked up too.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 560)
            Button("Choose Project Folder...") { model.buildWorkspace.chooseFolder() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Label(BuildText.privacy, systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: The editor

/// The middle column: tabs, the editor and the status line.
struct BuildEditorPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let editor = model.buildWorkspace.editor
        VStack(spacing: 0) {
            EditorTabBar()
            Divider()
            if let doc = editor.current, doc.conflictText != nil {
                BuildConflictBar(doc: doc)
            }
            BuildEditorArea()
            Divider()
            EditorStatusLine()
        }
    }
}

struct BuildEditorArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let editor = model.buildWorkspace.editor
        if let doc = editor.current {
            CodeEditor(controller: doc.controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text("Open a file from the list on the left, or make a new one.")
                    .foregroundStyle(.secondary)
                Text("New File... and New Folder... are under the list. Files you save in another editor open here too, reviewed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct EditorTabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ws = model.buildWorkspace
        let editor = ws.editor
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(editor.tabs, id: \.self) { path in
                        if let doc = editor.docs[path] {
                            EditorTabItem(doc: doc, selected: path == editor.currentPath)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            Button("Save") { editor.saveCurrent() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(editor.current == nil)
                .help("Save (Cmd+S)")
            Menu {
                Button("Change Folder...") { ws.chooseFolder() }
                Button("Close Folder") { ws.stopWatching() }
            } label: {
                Image(systemName: "folder.badge.gearshape")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Change or close the project folder")
        }
        .controlSize(.small)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
    }
}

struct EditorTabItem: View {
    let doc: EditorDocument
    let selected: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let editor = model.buildWorkspace.editor
        HStack(spacing: 5) {
            Text(doc.name)
                .lineLimit(1)
                .fontWeight(selected ? .semibold : .regular)
            if doc.dirty {
                Circle()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
            Button { editor.close(doc.path) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.borderless)
                .help("Close \(doc.name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { editor.show(doc.path) }
        .help(doc.path)
    }
}

struct BuildConflictBar: View {
    let doc: EditorDocument
    @Environment(AppModel.self) private var model

    var body: some View {
        let editor = model.buildWorkspace.editor
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(doc.name) was changed by another editor while you had unsaved edits here.")
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("Keep Mine") { editor.keepMine(doc.path) }
                .help("Keep the text in Olo's editor; saving replaces the other version")
            Button("Use Disk Version") { editor.useDisk(doc.path) }
                .help("Load the saved version (Cmd+Z brings yours back)")
        }
        .font(.callout)
        .controlSize(.small)
        .padding(8)
        .background(Color.orange.opacity(0.14))
    }
}

/// Language, line:column, what Olo is doing, and the day's Build allowance.
struct EditorStatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let editor = model.buildWorkspace.editor
        HStack(spacing: 14) {
            if let doc = editor.current {
                Text(doc.language.capitalized)
                Text("\(doc.line):\(doc.column)")
                    .monospacedDigit()
                    .help("Line and column")
                BuildReviewStatus(doc: doc)
            } else {
                Text("No file open")
            }
            Spacer(minLength: 0)
            if let summary = editor.allowance?.summary {
                Text(summary).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

struct BuildReviewStatus: View {
    let doc: EditorDocument

    var body: some View {
        if doc.reviewing {
            Label("Olo reviewing...", systemImage: "sparkles")
        } else if let failure = doc.reviewFailure {
            Text("Olo: " + failure)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(failure)
        } else if doc.reviewedOnce {
            let n = doc.issues.count
            Text(n == 0 ? "Olo: no issues" : "Olo: \(n) issue\(n == 1 ? "" : "s")")
        } else if !CodeLanguage.isReviewable(doc.path) {
            Text("Olo reviews source files")
        } else {
            Text("Olo: ready")
        }
    }
}

// MARK: The Olo pane

/// The right column: switches, banners, "Tell Olo what to build or change", then the issues,
/// Olo's proposed change, or the answers.
struct BuildOloPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ws = model.buildWorkspace
        @Bindable var editor = ws.editor
        VStack(alignment: .leading, spacing: 0) {
            BuildControls()
            if let c = editor.countdown { FixCountdownBanner(countdown: c) }
            if let n = ws.notice { BuildNoticeBar(text: n) }
            Divider()
            OloWriteBox()
            Divider()
            Picker("Show", selection: $editor.paneTab) {
                ForEach(BuildEditor.PaneTab.allCases, id: \.self) { tab in
                    Text(label(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            BuildPaneContent(tab: editor.paneTab)
        }
    }

    private func label(_ tab: BuildEditor.PaneTab) -> String {
        if tab == .issues, let n = model.buildWorkspace.editor.current?.issues.count, n > 0 { return "Issues (\(n))" }
        return tab.rawValue
    }
}

struct BuildPaneContent: View {
    let tab: BuildEditor.PaneTab

    var body: some View {
        switch tab {
        case .issues: BuildIssuesList()
        case .change: BuildProposalView()
        case .answers: BuildChat()
        }
    }
}

struct BuildControls: View {
    @Environment(AppModel.self) private var model

    private var safeCount: Int { model.buildWorkspace.editor.current?.issues.filter(\.isSafe).count ?? 0 }

    var body: some View {
        @Bindable var editor = model.buildWorkspace.editor
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Olo", systemImage: "sparkles").font(.headline)
                Spacer()
                Label("Always private", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(BuildText.privacy)
            }
            Toggle("Fix as I type", isOn: $editor.fixAsIType)
                .help(BuildText.fixAsITypeHelp)
            Toggle("Suggestions as I type", isOn: $editor.suggestions)
                .help(BuildText.suggestionsHelp)
            Toggle("Autosave", isOn: $editor.autosave)
                .help(BuildText.autosaveHelp)
            Button("Apply all safe fixes (\(safeCount))") { editor.applySafeFixes() }
                .disabled(safeCount == 0)
                .help("Applies the fixes for information and style issues only (Cmd+Z undoes them)")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(12)
    }
}

struct FixCountdownBanner: View {
    let countdown: BuildEditor.Countdown
    @Environment(AppModel.self) private var model

    var body: some View {
        let n = countdown.issueIds.count
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
            Text("Fixing \(n) issue\(n == 1 ? "" : "s") in \((countdown.path as NSString).lastPathComponent) in \(max(countdown.remaining, 0))...")
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("Cancel") { model.buildWorkspace.editor.cancelCountdown() }
        }
        .font(.callout)
        .padding(10)
        .background(Color.orange.opacity(0.16))
    }
}

struct BuildNoticeBar: View {
    let text: String
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
            Text(text).lineLimit(4)
            Spacer(minLength: 0)
            Button { model.buildWorkspace.notice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
        }
        .font(.caption)
        .padding(10)
        .background(Color.secondary.opacity(0.1))
    }
}

/// "Tell Olo what to build or change", and "Explain this".
struct OloWriteBox: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""

    var body: some View {
        let editor = model.buildWorkspace.editor
        let hasFile = editor.current != nil
        VStack(alignment: .leading, spacing: 6) {
            TextField("Tell Olo what to build or change", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .onSubmit(send)
                .disabled(!hasFile)
            HStack(spacing: 8) {
                Button("Ask Olo to Write", action: send)
                    .disabled(!hasFile || editor.writing || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Olo changes the open file, or only the selected lines, and shows the change for you to accept or reject")
                Button("Explain This") { editor.explain() }
                    .disabled(!hasFile)
                    .help("Explains the selected code, or the whole file, in a private chat")
                Spacer(minLength: 0)
                if editor.writing { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            Text(hasFile ? "Uses the selected lines when something is selected. An empty file is written from scratch." : "Open or make a file first.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.buildWorkspace.editor.writing else { return }
        model.buildWorkspace.editor.askToWrite(text)
        draft = ""
    }
}

// MARK: Issues

/// The open file's review: a summary line, then each issue with Apply.
struct BuildIssuesList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let editor = model.buildWorkspace.editor
        List {
            if let doc = editor.current {
                Section {
                    ForEach(doc.issues) { issue in
                        BuildIssueRow(issue: issue, selected: editor.selectedIssueId == issue.id)
                    }
                } header: {
                    ReviewSummaryHeader(doc: doc)
                }
            } else {
                Text("Open a file and Olo reviews it as you type.")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .frame(maxHeight: .infinity)
    }
}

struct ReviewSummaryHeader: View {
    let doc: EditorDocument

    private var counts: String {
        let e = doc.issues.filter { $0.severity == "error" }.count
        let w = doc.issues.filter { $0.severity == "warning" }.count
        let i = doc.issues.count - e - w
        return "\(e) error\(e == 1 ? "" : "s"), \(w) warning\(w == 1 ? "" : "s"), \(i) note\(i == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(doc.path).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if doc.reviewing { ProgressView().controlSize(.mini) }
                if doc.reviewedOnce { Text(counts).font(.caption2).foregroundStyle(.secondary) }
            }
            if let failure = doc.reviewFailure {
                Text(failure).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if let summary = doc.summary {
                Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if doc.reviewedOnce && doc.issues.isEmpty {
                Text("No issues found.").font(.caption).foregroundStyle(.secondary)
            } else if doc.reviewing {
                Text("Reviewing...").font(.caption).foregroundStyle(.secondary)
            } else if !CodeLanguage.isReviewable(doc.path) {
                Text("Olo reviews source and config files; this one is just edited.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .padding(.vertical, 2)
    }
}

struct BuildIssueRow: View {
    let issue: CodeIssue
    let selected: Bool
    @Environment(AppModel.self) private var model

    private var lineText: String {
        issue.endLine > issue.line ? "Lines \(issue.line) to \(issue.endLine)" : "Line \(issue.line)"
    }

    var body: some View {
        let editor = model.buildWorkspace.editor
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: SeverityStyle.symbol(issue.severity))
                .foregroundStyle(SeverityStyle.color(issue.severity))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(issue.severity.capitalized).font(.caption.weight(.semibold))
                    Text(issue.category.capitalized).font(.caption)
                    Text(lineText).font(.caption).foregroundStyle(.secondary)
                }
                Text(issue.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix = issue.fix {
                    Button("Apply") { editor.apply(issue) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help(fix.replacement.isEmpty ? "Removes these lines (Cmd+Z undoes it)" : fix.replacement)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { editor.jump(to: issue) }
        .listRowBackground(selected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}

// MARK: Olo's change

struct BuildProposalView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let editor = model.buildWorkspace.editor
        Group {
            if editor.writing {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Olo is writing...").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let proposal = editor.proposal {
                BuildProposalDetail(proposal: proposal, stale: editor.proposalIsStale)
            } else if let failure = editor.writeFailure {
                VStack(alignment: .leading, spacing: 8) {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .lineLimit(6)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text("Tell Olo what to build or change above. Its change appears here as a diff to accept or reject.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

struct BuildProposalDetail: View {
    let proposal: BuildEditor.Proposal
    let stale: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let editor = model.buildWorkspace.editor
        let counts = LineDiff.counts(proposal.rows)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text((proposal.path as NSString).lastPathComponent).font(.callout.weight(.semibold)).lineLimit(1)
                Text("+\(counts.added)").foregroundStyle(.green)
                Text("-\(counts.removed)").foregroundStyle(.red)
                Spacer(minLength: 0)
                Button("Reject") { editor.rejectProposal() }
                Button("Accept") { editor.acceptProposal() }
                    .disabled(proposal.rows.isEmpty)
            }
            .controlSize(.small)
            .padding(8)
            if !proposal.explanation.isEmpty {
                ScrollView {
                    Text(proposal.explanation)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                }
                .frame(maxHeight: 120)
            }
            if stale {
                Text("The file changed after you asked. Accepting replaces it with Olo's version, including your newer edits (Cmd+Z brings them back).")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .padding(8)
            }
            Divider()
            if proposal.rows.isEmpty {
                Text("Olo's version is the same as yours.")
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                DiffView(rows: proposal.rows)
            }
        }
    }
}

// MARK: Answers

/// Answers from "Explain this" and questions about the open file, in a private chat: the code
/// never enters the brain or the server's history.
struct BuildChat: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""

    var body: some View {
        let ws = model.buildWorkspace
        let cid = ws.chatConversationId
        let turns = model.conversation(cid)?.turns ?? []
        let status = cid.flatMap { model.answering[$0] }
        let hasFile = ws.editor.current != nil
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if turns.isEmpty {
                            Text("Press Explain This, or ask about the open file below.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(turns.suffix(8)) { t in
                            TurnView(turn: t, status: t.id == turns.last?.id ? status : nil, compact: true)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(8)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: turns.last?.text.count ?? 0) { proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(ws.editor.current.map { "Ask Olo about \($0.name)" } ?? "Open a file to ask Olo about it", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)
                    .disabled(!hasFile)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                    .buttonStyle(.borderless)
                    .disabled(!hasFile || status != nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Label(BuildText.chatNote, systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(10)
    }

    private func send() {
        let q = draft
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.buildWorkspace.askAboutCurrentFile(q)
        draft = ""
    }
}
