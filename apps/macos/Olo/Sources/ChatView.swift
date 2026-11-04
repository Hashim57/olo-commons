import SwiftUI
import UniformTypeIdentifiers
import OloKit

struct ChatView: View {
    let conversationId: UUID
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var attachments: [Attachment] = []
    @State private var searchWeb = UserDefaults.standard.bool(forKey: Prefs.searchWebByDefault)
    @State private var useFolders = UserDefaults.standard.bool(forKey: Prefs.useFoldersByDefault)
    @State private var dropTargeted = false
    @State private var dictation = DictationController()
    @AppStorage(Prefs.challengeMode) private var challenge = false
    @FocusState private var composerFocused: Bool

    private var conversation: LocalConversation? { model.conversation(conversationId) }
    private var status: String? { model.answering[conversationId] }

    private var lastTurnId: UUID? { conversation?.turns.last?.id }
    private var lastTextCount: Int { conversation?.turns.last?.text.count ?? 0 }
    private var artifactCount: Int { conversation?.turns.reduce(0) { $0 + $1.artifacts.count } ?? 0 }
    private var latestArtifact: Artifact? { conversation?.turns.last(where: { !$0.artifacts.isEmpty })?.artifacts.last }

    var body: some View {
        @Bindable var model = model
        thread
        .navigationTitle(conversation?.title ?? "Olo")
        .toolbar { toolbarItems }
        .inspector(isPresented: $model.showSample) {
            SamplePanel().inspectorColumnWidth(min: 360, ideal: 520, max: 760)
        }
        .onChange(of: artifactCount) { sampleLanded() }
        .onChange(of: status == nil) { sampleLanded() }
        .dropDestination(for: URL.self) { urls, _ in
            attach(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay { dropOverlay }
        .onChange(of: model.requestAttachFiles) {
            if model.requestAttachFiles { model.requestAttachFiles = false; pickFiles() }
        }
        .onChange(of: model.focusComposer) { composerFocused = true }
        .onAppear { composerFocused = true }
    }

    /// The transcript above the composer.
    private var thread: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if conversation?.turns.isEmpty ?? true { NewConversationEmptyState() }
                        ForEach(conversation?.turns ?? []) { turn in
                            TurnView(turn: turn, status: turn.id == lastTurnId ? status : nil, compact: false, conversationId: conversationId) { follow in
                                model.ask(follow, in: conversationId)
                            }
                            .id(turn.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: lastTextCount) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            composer
                .layoutPriority(1)
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { ExportMenu(conversationId: conversationId) }
        ToolbarItem(placement: .primaryAction) { SampleToggle() }
    }

    /// A new file in this conversation opens in the Sample panel as soon as it lands.
    /// Opens the newest file in the Olo Sample, once the answer has finished: opening the inspector
    /// while text is still streaming in resized the thread on every word.
    private func sampleLanded() {
        guard status == nil else { return }
        if let a = latestArtifact, a.id != model.sample?.id { model.openSample(a) }
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [6]))
                .overlay(Text("Drop files to ask Olo about them").font(.title3))
                .padding(8)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            NudgeBanner()
            BreakNudgeBanner()
            QuotaBanner()
            if !attachments.isEmpty { AttachmentChips(attachments: $attachments) }
            HStack(alignment: .bottom, spacing: 10) {
                Button(action: pickFiles) { Image(systemName: "paperclip") }
                    .buttonStyle(.borderless).help("Attach files (Cmd+O), or drop them here")
                Button(action: toggleDictation) {
                    Image(systemName: dictation.listening ? "mic.fill" : "mic").foregroundStyle(dictation.listening ? Color.red : Color.primary)
                }
                .buttonStyle(.borderless).help(dictation.listening ? "Stop dictation" : "Dictate a question")
                TextField(model.isOnline ? "Ask Olo" : "Ask Olo (offline: answered from this Mac)", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($composerFocused)
                    .onSubmit(send)
                if status != nil {
                    Button { model.stop(conversationId) } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                        .buttonStyle(.borderless).help("Stop")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                        .keyboardShortcut(.return, modifiers: [.command])
                }
            }
            HStack(spacing: 14) {
                Toggle(isOn: $searchWeb) { Label("Search the web", systemImage: "globe") }
                    .help("Olo searches and answers only from what it finds, with citations")
                if !model.folders.folders.isEmpty {
                    Toggle(isOn: $useFolders) { Label("Use my folders", systemImage: "folder") }
                        .help("Adds the best matching passages from the folders you chose in Settings")
                }
                Toggle(isOn: $challenge) { Label("Challenge me", systemImage: "exclamationmark.bubble") }
                    .help("Olo disagrees first when the evidence points the other way")
                Spacer(minLength: 8)
                if let s = status { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .toggleStyle(.checkbox)
            .font(.caption)
            .lineLimit(1)
            ContextGaugeView(reading: gauge)
            privacyRow
            if conversation?.isPrivate == true {
                Text(BrainText.privateExplainer).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
            if let p = dictation.problem { Text(p).font(.caption).foregroundStyle(.orange).lineLimit(2) }
        }
        .padding(14)
        .background(.bar)
    }

    /// "Add to Olo brain" (this chat, starting at the account default), the "Private chat" switch
    /// (only before the first message), and the link to the brain.
    private var privacyRow: some View {
        let isPrivate = conversation?.isPrivate ?? false
        let started = !(conversation?.turns.isEmpty ?? true) || conversation?.serverId != nil
        let brainOn = Binding<Bool>(get: { model.brainEnabled(for: conversationId) }, set: { model.setAddToBrain(conversationId, $0) })
        let privateOn = Binding<Bool>(get: { isPrivate }, set: { model.setPrivate(conversationId, $0) })
        return HStack(spacing: 14) {
            Toggle(isOn: brainOn) { Label(BrainText.toggle, systemImage: "brain.head.profile") }
                .toggleStyle(.checkbox)
                .disabled(isPrivate)
                .help(isPrivate ? "Private chats are never added to the Olo brain" : "Only the question text, scrubbed of personal details, appears in the public Olo brain. Never the answer, your name or your account.")
            Toggle(isOn: privateOn) { Label(BrainText.privateChat, systemImage: isPrivate ? "lock.fill" : "lock.open") }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(started)
                .help(started ? "Set before the first message. File > New Private Chat starts one." : BrainText.privateExplainer)
            Button(BrainText.viewBrain) { model.openBrain() }
                .buttonStyle(.link)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .lineLimit(1)
    }

    private var gauge: ContextGauge.Reading {
        let turns = (conversation?.turns ?? []).map { (role: $0.role == .user ? "user" : "assistant", text: $0.text) }
        return ContextGauge.reading(turns: turns, draft: draft)
    }

    private func toggleDictation() {
        let before = draft
        dictation.toggle { text, _ in
            draft = before.isEmpty ? text : before + " " + text
        }
    }

    private func send() {
        guard status == nil else { return }
        let q = draft
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        model.ask(q, attachments: attachments, in: conversationId, searchWeb: searchWeb, useFolders: useFolders)
        draft = ""
        attachments = []
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        attach(panel.urls)
    }

    private func attach(_ urls: [URL]) {
        Task {
            let (read, failed) = await Task.detached(priority: .userInitiated) { () -> ([Attachment], [String]) in
                var read: [Attachment] = []
                var failed: [String] = []
                for u in urls.prefix(10) {
                    if let a = FileExtractor.attachment(for: u) { read.append(a) } else { failed.append(u.lastPathComponent) }
                }
                return (read, failed)
            }.value
            attachments.append(contentsOf: read)
            if !failed.isEmpty { model.banner = "Olo could not read text from \(failed.joined(separator: ", "))." }
        }
    }
}

struct AttachmentChips: View {
    @Binding var attachments: [Attachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { a in
                    HStack(spacing: 4) {
                        Image(systemName: a.kind == .selection ? "text.quote" : "doc.text")
                        Text(a.name).lineLimit(1)
                        Text("\(a.text.count.formatted()) chars").foregroundStyle(.secondary)
                        Button { attachments.removeAll { $0.id == a.id } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).help("Remove")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                }
            }
        }
    }
}

/// One turn: your question, or Olo's answer with where it came from, the sources and
/// what Zeus found for each sentence.
struct TurnView: View {
    let turn: Turn
    let status: String?
    let compact: Bool
    var conversationId: UUID? = nil
    var onFollowUp: (String) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var fixing = false
    @State private var showChecks = false
    @State private var showUnverified = UserDefaults.standard.bool(forKey: Prefs.showUnverified)
    @State private var flagNote: String?

    var body: some View {
        if turn.role == .user {
            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Spacer(minLength: 60)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(turn.text).textSelection(.enabled)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                        if !turn.attachments.isEmpty {
                            Text(turn.attachments.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if Crisis.detect(turn.text) { CrisisBanner() }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if turn.text.isEmpty, let job = model.buildJobs[turn.id] {
                    BuildProgressView(job: job, turnId: turn.id)
                } else if turn.text.isEmpty {
                    HStack(spacing: 10) { HeliusAtomView(mode: .loader, size: 56); Text(status ?? "Thinking").foregroundStyle(.secondary) }
                } else if let v = turn.verification, !v.claims.isEmpty, turn.origin == .olo || turn.origin == .commons,
                          !MarkdownBlocks.isStructured(turn.text) {
                    answerText(checked: v)
                } else {
                    // A document, a list or code is read whole: hiding its unverified sentences would leave
                    // holes in it. The checks still appear below, claim by claim.
                    AnswerBody(content: turn.text, render: { MarkdownText(text: $0) })
                }
                if !turn.text.isEmpty, let job = model.buildJobs[turn.id] {
                    BuildProgressView(job: job, turnId: turn.id)
                }
                if !turn.artifacts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(turn.artifacts) { a in ArtifactCard(artifact: a) }
                    }
                }
                ForEach(Array(turn.notices.enumerated()), id: \.offset) { _, n in
                    Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                if let cid = conversationId, status == nil, turn.notices.contains(where: { $0.localizedCaseInsensitiveContains("length limit") || $0.localizedCaseInsensitiveContains("cut short") }) {
                    Button { model.continueAnswer(in: cid) } label: { Label("Continue the answer", systemImage: "arrow.turn.down.right") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("Olo carries on from where it stopped")
                }
                if let v = turn.verification, !v.claims.isEmpty { verification(v) }
                if !turn.sources.isEmpty { sources }
                if let line = References.line(turn.references) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(line, systemImage: "books.vertical").font(.caption)
                        ForEach(Array(References.flagged(turn.references).enumerated()), id: \.offset) { _, r in
                            Text(r.text + (r.note.map { ": " + $0 } ?? "")).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
                if !turn.memories.isEmpty {
                    Text("Shaped by \(turn.memories.count) thing\(turn.memories.count == 1 ? "" : "s") you've told Olo")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help(turn.memories.map(\.content).joined(separator: "\n"))
                }
                if let s = turn.brainStatus, let note = BrainText.note(for: s) {
                    Label(note, systemImage: "brain.head.profile").font(.caption2).foregroundStyle(.secondary)
                }
                footer
                if !compact, !turn.followUps.isEmpty {
                    HStack { ForEach(turn.followUps, id: \.self) { q in Button(q) { onFollowUp(q) }.buttonStyle(.bordered).controlSize(.small) } }
                }
            }
        }
    }

    private func markdown(_ s: String) -> AttributedString { MarkdownText.inline(s) }

    /// Only the sentences Zeus could support are shown; the rest wait behind a button, labelled.
    private func answerText(checked v: AnswerVerification) -> some View {
        let split = Abstain.splitShown(text: turn.text, claims: v.claims)
        return VStack(alignment: .leading, spacing: 8) {
            if split.shown.isEmpty {
                Text(Abstain.nothingVerified).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(markdown(split.shown.joined(separator: " "))).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !split.hidden.isEmpty {
                Button(showUnverified ? "Hide \(split.hidden.count) unverified sentence\(split.hidden.count == 1 ? "" : "s")" : "Show \(split.hidden.count) unverified sentence\(split.hidden.count == 1 ? "" : "s")") { showUnverified.toggle() }
                    .buttonStyle(.borderless).font(.caption)
                if showUnverified {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(split.hidden.enumerated()), id: \.offset) { _, h in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(h.0).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Text(Abstain.label(for: h.1)).font(.caption2).foregroundStyle(h.1 == "contradicted" ? Color.red : Color.orange)
                            }
                        }
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    /// The Flag menu on a claim: the reader's verdict goes to a reviewer, and accepted flags teach Zeus.
    private func flagMenu(_ c: ClaimVerdict) -> some View {
        Menu {
            ForEach(0..<FeedbackRequest.userChoices.count, id: \.self) { i in
                let choice = FeedbackRequest.userChoices[i]
                Button(choice.label) { sendFlag(c, choice.value) }
            }
        } label: {
            Label("Flag", systemImage: "flag").labelStyle(.titleOnly)
        }
        .menuStyle(.borderlessButton).font(.caption).fixedSize()
        .help("Tell a reviewer this verdict is wrong; accepted flags teach Zeus")
    }

    private func sendFlag(_ c: ClaimVerdict, _ userVerdict: String) {
        let origin = turn.origin ?? .olo
        guard let req = try? FeedbackRequest.build(answerSource: origin, claim: c, sources: turn.sources, userVerdict: userVerdict, note: nil) else { flagNote = FeedbackRequest.failed; return }
        flagNote = "Sending the flag"
        Task { @MainActor in
            flagNote = await FeedbackRequest.send(req)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            flagNote = nil
        }
    }

    private func verification(_ v: AnswerVerification) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showChecks.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal")
                    if v.supported > 0 { Text("\(v.supported) supported").foregroundStyle(.green) }
                    if v.contradicted > 0 { Text("\(v.contradicted) contradicted").foregroundStyle(.red) }
                    if v.unsupported > 0 { Text("\(v.unsupported) not covered").foregroundStyle(.orange) }
                    Image(systemName: showChecks ? "chevron.up" : "chevron.down").font(.caption2)
                }
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            if let n = flagNote { Text(n).font(.caption2).foregroundStyle(.secondary) }
            if !compact, let cid = conversationId, turn.serverMessageId != nil {
                HStack(spacing: 10) {
                    if v.contradicted + v.unsupported > 0 {
                        Button(fixing ? "Fixing..." : "Fix flagged sentences") {
                            fixing = true
                            Task { await model.fixFlagged(cid: cid, tid: turn.id); fixing = false }
                        }
                        .disabled(fixing)
                    }
                    if v.claims.contains(where: { $0.claimId != nil }) {
                        Button("Watch") { Task { await model.watch(turn) } }
                            .help("Olo tells you if the evidence for these claims changes")
                    }
                }
                .buttonStyle(.borderless).font(.caption)
            }
            if showChecks {
                ForEach(Array(v.claims.enumerated()), id: \.offset) { _, c in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .top, spacing: 6) {
                            Label(c.claim, systemImage: icon(c.verdict)).foregroundStyle(color(c.verdict))
                            Spacer(minLength: 4)
                            flagMenu(c)
                        }
                        if let e = c.excerpt, !e.isEmpty { Text("\"\(e)\"").font(.caption).italic().foregroundStyle(.secondary) }
                        if !c.rationale.isEmpty { Text(c.rationale).font(.caption).foregroundStyle(.secondary) }
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(turn.sources, id: \.self) { s in
                if let url = URL(string: s.url), LinkPolicy.isSafeExternal(url) {
                    HStack(spacing: 6) {
                        Link(destination: url) { Text("[\(s.index)] \(s.title)").lineLimit(1) }.font(.caption)
                        if let label = s.downRankedLabel { Text(label).font(.caption2).foregroundStyle(.orange) }
                        if s.urlOk == false { Image(systemName: "link.badge.plus").font(.caption2).foregroundStyle(.secondary).help("This link did not answer when checked") }
                    }
                } else {
                    Text("[\(s.index)] \(s.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !turn.text.isEmpty, let line = turn.answeredBy?.line {
                Text(line + (Publishers.summary(of: turn.sources).map { "; " + $0 } ?? "")).font(.caption2).foregroundStyle(.secondary)
            } else if !turn.text.isEmpty, let p = Publishers.summary(of: turn.sources) {
                Text(p).font(.caption2).foregroundStyle(.secondary)
            }
            footerRow
        }
    }

    private var footerRow: some View {
        HStack(spacing: 12) {
            // "Answered by Olo" once: the line above already says it when the server named the writer.
            if let o = turn.origin, !turn.text.isEmpty, !(o == .olo && turn.answeredBy?.line != nil) {
                Text(o.label).font(.caption2).foregroundStyle(o == .offline ? Color.orange : Color.secondary)
            }
            if !turn.text.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(turn.text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy")
                Button { model.voice.toggle(turn: turn.id, text: turn.text, api: model.api) } label: {
                    Image(systemName: model.voice.speakingTurn == turn.id ? "speaker.slash" : "speaker.wave.2")
                }
                .buttonStyle(.borderless).help(model.voice.speakingTurn == turn.id ? "Stop reading" : "Read aloud in Olo's voice")
                if !compact, let cid = conversationId, turn.serverMessageId != nil {
                    Button { editing = true } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).help("Edit a passage")
                        .sheet(isPresented: $editing) { EditPassageSheet(conversationId: cid, turn: turn) }
                }
            }
            if let s = status, !turn.text.isEmpty { Text(s).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func icon(_ v: String) -> String {
        switch v { case "supported": return "checkmark.circle"; case "contradicted": return "xmark.octagon"; default: return "questionmark.circle" }
    }

    private func color(_ v: String) -> Color {
        switch v { case "supported": return .primary; case "contradicted": return .red; default: return .orange }
    }
}


/// A calm note with helplines, shown above the answer when a message reads as self-harm. Never blocks the answer.
struct CrisisBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Crisis.title).font(.callout.weight(.semibold))
            ForEach(Crisis.helplines, id: \.name) { h in
                Text("\(h.name): \(h.detail)").font(.caption)
            }
            Text(Crisis.emergency).font(.caption.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// An answer drawn as a document: headings at three sizes, bullets and numbers with a hanging
/// indent, quotes with a bar, code in a monospaced box, tables as a grid, and inline bold,
/// italic, code and links everywhere. The structure comes from OloKit's MarkdownBlocks.
struct MarkdownText: View {
    let text: String

    /// Inline Markdown (bold, italic, code, links) as styled text; the raw text when it does not parse.
    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    var body: some View {
        let blocks = MarkdownBlocks.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let t):
            Text(MarkdownText.inline(t))
                .font(level <= 1 ? .title2.weight(.semibold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level <= 2 ? 6 : 2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let t):
            Text(MarkdownText.inline(t)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\u{2022}").foregroundStyle(.secondary).frame(width: 12, alignment: .trailing)
                        Text(MarkdownText.inline(item)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 4)
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).").foregroundStyle(.secondary).monospacedDigit().frame(width: 22, alignment: .trailing)
                        Text(MarkdownText.inline(item)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 4)
        case .quote(let t):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.5)).frame(width: 3)
                Text(MarkdownText.inline(t)).italic().foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(language.isEmpty ? "code" : language).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).controlSize(.small).help("Copy the code")
                }
                .padding(.horizontal, 10).padding(.top, 6)
                CodeBlockBody(code: code)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        case .table(let header, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, h in
                            Text(MarkdownText.inline(h)).font(.callout.weight(.semibold))
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(MarkdownText.inline(cell)).font(.callout).textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }
}

/// A code block in the thread. A long one shows its first 40 lines with "Show all": a whole page
/// of code laid out as one SwiftUI text inside a scrolling thread is what hung and crashed the window
/// ("needing another Update Constraints in Window pass") when a cut build streamed into it.
struct CodeBlockBody: View {
    let code: String
    @State private var expanded = false
    private static let preview = 40

    private var lines: [Substring] { code.split(separator: "\n", omittingEmptySubsequences: false) }

    var body: some View {
        let all = lines
        let shown = expanded || all.count <= Self.preview ? code : all.prefix(Self.preview).joined(separator: "\n")
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal) {
                Text(shown).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
            if all.count > Self.preview {
                Button(expanded ? "Show fewer lines" : "Show all \(all.count) lines") { expanded.toggle() }
                    .buttonStyle(.borderless).font(.caption).padding(.horizontal, 10).padding(.bottom, 6)
            }
        }
    }
}

/// The Olo Sample: the document or page Olo made, open beside the conversation for review, with
/// Preview and Code, Export, and a way into the Artifacts library. The same detail view as the
/// library, so what you see here is what you export.
struct SamplePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext").foregroundStyle(.tint)
                Text("Olo Sample").font(.headline)
                Text("for review").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let a = model.sample {
                    Button("Open in Artifacts") { model.openArtifact(a) }.controlSize(.small)
                }
                Button { model.showSample = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Close the Sample panel")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if let a = model.sample {
                ArtifactDetail(artifact: a, inLibrary: false).id(a.id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.richtext").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Nothing to review yet").foregroundStyle(.secondary)
                    Text("Ask Olo to build a page, a document, a chart or a plan and it opens here.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The toolbar switch for the Olo Sample panel.
struct SampleToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Toggle(isOn: $model.showSample) { Label("Olo Sample", systemImage: "sidebar.right") }
            .disabled(model.sample == nil)
            .help("Show or hide the Olo Sample: the document or page Olo made, beside the conversation")
    }
}
