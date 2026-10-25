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

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if conversation?.turns.isEmpty ?? true { NewConversationEmptyState() }
                        ForEach(conversation?.turns ?? []) { turn in
                            TurnView(turn: turn, status: turn.id == conversation?.turns.last?.id ? status : nil, compact: false, conversationId: conversationId) { follow in
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
                .onChange(of: conversation?.turns.last?.text.count ?? 0) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            composer
                .layoutPriority(1)
        }
        .navigationTitle(conversation?.title ?? "Olo")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ExportMenu(conversationId: conversationId) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            attach(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .overlay(Text("Drop files to ask Olo about them").font(.title3))
                    .padding(8)
            }
        }
        .onChange(of: model.requestAttachFiles) {
            if model.requestAttachFiles { model.requestAttachFiles = false; pickFiles() }
        }
        .onChange(of: model.focusComposer) { composerFocused = true }
        .onAppear { composerFocused = true }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            NudgeBanner()
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
                Text(BrainText.privateExplainer).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let p = dictation.problem { Text(p).font(.caption).foregroundStyle(.orange).lineLimit(2) }
        }
        .padding(14)
        .fixedSize(horizontal: false, vertical: true)
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
                if turn.text.isEmpty {
                    HStack(spacing: 10) { HeliusAtomView(mode: .loader, size: 56); Text(status ?? "Thinking").foregroundStyle(.secondary) }
                } else if let v = turn.verification, !v.claims.isEmpty, turn.origin == .olo || turn.origin == .commons {
                    answerText(checked: v)
                } else {
                    AnswerBody(content: turn.text, render: { Text(markdown($0)) })
                }
                ForEach(Array(turn.notices.enumerated()), id: \.offset) { _, n in
                    Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
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

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

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
            if let o = turn.origin, !turn.text.isEmpty {
                Text(o.label).font(.caption2).foregroundStyle(o == .offline ? Color.orange : Color.secondary)
            }
            if !turn.text.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(turn.text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy")
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
