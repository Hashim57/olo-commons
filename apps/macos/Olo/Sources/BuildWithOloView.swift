import SwiftUI
import OloKit

/// The words Build with Olo uses about privacy, in one place.
enum BuildText {
    static let privacy = "Code is sent to helius-olo.io only to be reviewed. It is never stored there, never used for training and never added to the Olo brain. Build with Olo is always private."
    static let chatNote = "Private: the file goes with your question and is never saved on the server or added to the brain."
    static let fixAsISaveHelp = "After each review, errors that are bugs or security holes are fixed by themselves after a 3 second countdown you can cancel."
}

/// Build with Olo: on the left the project's code as it was last saved, with the flagged lines;
/// on the right the Olo pane with the issues, fixes and a chat about the file. Works with any
/// editor, because Olo watches the saves on disk.
struct BuildWithOloView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ws = model.buildWorkspace
        Group {
            if ws.folderURL == nil {
                BuildEmptyState()
            } else {
                HSplitView {
                    BuildCodePane()
                        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                    BuildOloPane()
                        .frame(minWidth: 320, idealWidth: 400, maxWidth: 560, maxHeight: .infinity)
                }
            }
        }
        .onAppear { ws.restore() }
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
            Text("Choose a project folder. Olo watches it, and each time you save a source file in any editor (Xcode, VS Code or anything else) it reviews the file and lists what it finds, with fixes you can apply.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 540)
            Button("Choose Project Folder...") { model.buildWorkspace.chooseFolder() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Label(BuildText.privacy, systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The left side: which folder, which file, and the file itself.
struct BuildCodePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ws = model.buildWorkspace
        VStack(spacing: 0) {
            header
            Divider()
            if let file = ws.current {
                CodeView(text: file.content, issues: file.issues, jumpLine: ws.jumpLine, jumpToken: ws.jumpToken, selectedIssueId: ws.selectedIssueId)
                    .id(file.path)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("Save a file in your editor and it appears here, reviewed.")
                        .foregroundStyle(.secondary)
                    Text("Olo skips .git, node_modules, build folders, files over 200 KB, binary files and anything in .gitignore.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        let ws = model.buildWorkspace
        let selection = Binding<String>(get: { ws.currentPath ?? "" }, set: { ws.show($0) })
        return HStack(spacing: 10) {
            Label(ws.folderName, systemImage: "folder")
                .font(.headline)
                .lineLimit(1)
            if !ws.order.isEmpty {
                Picker("File", selection: selection) {
                    ForEach(ws.order, id: \.self) { path in
                        Text(path).tag(path)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
            }
            Spacer()
            Button("Change Folder...") { ws.chooseFolder() }
            Button("Stop Watching") { ws.stopWatching() }
                .help("Olo stops watching and forgets this folder")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The right side: switches, the countdown, the issues for every reviewed file, and the chat.
struct BuildOloPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ws = model.buildWorkspace
        VStack(alignment: .leading, spacing: 0) {
            BuildControls()
            if let c = ws.countdown { FixCountdownBanner(countdown: c) }
            if let n = ws.notice { BuildNoticeBar(text: n) }
            Divider()
            BuildIssuesList()
            Divider()
            BuildChat()
        }
    }
}

struct BuildControls: View {
    @Environment(AppModel.self) private var model

    private var safeCount: Int { model.buildWorkspace.current?.issues.filter(\.isSafe).count ?? 0 }

    var body: some View {
        let ws = model.buildWorkspace
        let fixOn = Binding<Bool>(get: { ws.fixAsISave }, set: { ws.fixAsISave = $0 })
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Olo", systemImage: "sparkles").font(.headline)
                Spacer()
                Label("Always private", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(BuildText.privacy)
            }
            Toggle("Fix as I save", isOn: fixOn)
                .toggleStyle(.switch)
                .help(BuildText.fixAsISaveHelp)
            HStack(spacing: 10) {
                Button("Apply all safe fixes (\(safeCount))") {
                    if let p = ws.currentPath { ws.applySafeFixes(in: p) }
                }
                .disabled(safeCount == 0)
                .help("Applies the fixes for information and style issues only")
                if let p = ws.currentPath, ws.undoable.contains(p) {
                    Button("Undo") { ws.undo(p) }
                        .help("Puts back the file as it was before Olo's last fix")
                }
            }
            .controlSize(.small)
        }
        .padding(12)
    }
}

struct FixCountdownBanner: View {
    let countdown: BuildWorkspace.Countdown
    @Environment(AppModel.self) private var model

    var body: some View {
        let n = countdown.issueIds.count
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
            Text("Fixing \(n) issue\(n == 1 ? "" : "s") in \((countdown.path as NSString).lastPathComponent) in \(max(countdown.remaining, 0))...")
                .lineLimit(2)
            Spacer()
            Button("Cancel") { model.buildWorkspace.cancelCountdown() }
                .keyboardShortcut(.cancelAction)
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
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { model.buildWorkspace.notice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
        }
        .font(.caption)
        .padding(10)
        .background(.quaternary.opacity(0.5))
    }
}

/// Every reviewed file, newest save first: a summary line per review, then its issues.
struct BuildIssuesList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ws = model.buildWorkspace
        List {
            if ws.order.isEmpty {
                Text("Save a file in your editor and Olo reviews it here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(ws.order, id: \.self) { path in
                if let file = ws.files[path] {
                    Section {
                        ForEach(file.issues) { issue in
                            BuildIssueRow(issue: issue, path: path)
                        }
                    } header: {
                        ReviewSummaryHeader(file: file)
                    }
                }
            }
        }
        .listStyle(.inset)
        .frame(maxHeight: .infinity)
    }
}

struct ReviewSummaryHeader: View {
    let file: BuildWorkspace.ReviewedFile

    private var counts: String {
        let e = file.issues.filter { $0.severity == "error" }.count
        let w = file.issues.filter { $0.severity == "warning" }.count
        let i = file.issues.count - e - w
        return "\(e) error\(e == 1 ? "" : "s"), \(w) warning\(w == 1 ? "" : "s"), \(i) note\(i == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(file.path).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if file.reviewing { ProgressView().controlSize(.mini) }
                if file.reviewedAt != nil { Text(counts).font(.caption2).foregroundStyle(.secondary) }
            }
            if let failure = file.failure {
                Text(failure).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if let summary = file.summary {
                Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if file.reviewedAt != nil && file.issues.isEmpty {
                Text("No issues found.").font(.caption).foregroundStyle(.secondary)
            } else if file.reviewing {
                Text("Reviewing...").font(.caption).foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .padding(.vertical, 2)
    }
}

struct BuildIssueRow: View {
    let issue: CodeIssue
    let path: String
    @Environment(AppModel.self) private var model

    private var lineText: String {
        issue.endLine > issue.line ? "Lines \(issue.line) to \(issue.endLine)" : "Line \(issue.line)"
    }

    var body: some View {
        let ws = model.buildWorkspace
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: SeverityStyle.symbol(issue.severity))
                .foregroundStyle(SeverityStyle.color(issue.severity))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(issue.category.capitalized).font(.caption.weight(.semibold))
                    Text(lineText).font(.caption).foregroundStyle(.secondary)
                }
                Text(issue.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix = issue.fix {
                    Button("Apply fix") { ws.applyFix(issue, in: path) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help(fix.replacement.isEmpty ? "Removes these lines" : fix.replacement)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { ws.jump(to: issue, in: path) }
        .listRowBackground(ws.selectedIssueId == issue.id ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}

/// Ask Olo about the file in view. The question goes through the normal ask flow in a private
/// chat with the file attached, so the code never enters the brain or the server's history.
struct BuildChat: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""

    var body: some View {
        let ws = model.buildWorkspace
        let cid = ws.chatConversationId
        let turns = model.conversation(cid)?.turns ?? []
        let status = cid.flatMap { model.answering[$0] }
        VStack(alignment: .leading, spacing: 6) {
            if !turns.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(turns.suffix(6)) { t in
                                TurnView(turn: t, status: t.id == turns.last?.id ? status : nil, compact: true)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(8)
                    }
                    .frame(minHeight: 120, maxHeight: 280)
                    .onChange(of: turns.last?.text.count ?? 0) { proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(ws.current.map { "Ask Olo about \(($0.path as NSString).lastPathComponent)" } ?? "Save a file to ask Olo about it", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)
                    .disabled(ws.current == nil)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                    .buttonStyle(.borderless)
                    .disabled(ws.current == nil || status != nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Label(BuildText.chatNote, systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
