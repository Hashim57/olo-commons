import AppKit
import SwiftUI
import OloKit

/// Talk to Olo: a whole conversation by voice, hands free.
///
/// Opened from the menu bar, the File menu (Cmd+Shift+T), the toolbar or Quick Ask.
/// Olo says "Go ahead, I'm listening", the Mac's recogniser opens, a pause of 1.5 s
/// sends what was said, and Olo's voice reads the answer sentence by sentence while
/// it is still being written. Then the mic opens again for the follow-up, in the same
/// conversation, until the person presses Stop or says "stop", "that's all" or
/// "goodbye". "Build me a landing page for a bakery" starts a build: Olo says it is on
/// it, keeps talking, and reads the summary when the build is done, between turns.
/// Everything said is shown in the panel and the conversation is saved like any other.
@MainActor
final class TalkToOloController {
    static let shared = TalkToOloController()
    private var panel: NSPanel?
    let session = TalkToOloSession()

    func show(continuing conversationId: Int? = nil) {
        let p = panel ?? makePanel()
        panel = p
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let size = p.frame.size
            p.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2))
        }
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        session.start(continuing: conversationId, api: AppModel.shared.api)
    }

    func close() {
        session.stop(spoken: false)
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = "Talk to Olo"
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: TalkToOloView(session: session).environment(AppModel.shared))
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.session.stop(spoken: false) }
        }
        return p
    }
}

/// The conversation's state machine, kept out of the view so it survives re-renders.
@MainActor @Observable
final class TalkToOloSession {
    enum Phase { case idle, listening, thinking, speaking, stopped }
    struct Turn: Identifiable { let id = UUID(); let you: Bool; var text: String }

    private(set) var phase: Phase = .idle
    private(set) var turns: [Turn] = []
    private(set) var heard = ""
    private(set) var conversationId: Int?
    private(set) var build: BuildJob?
    private(set) var quota: String?
    private(set) var problem: String?

    @ObservationIgnored private var api: OloAPI?
    @ObservationIgnored private let dictation = DictationController()
    @ObservationIgnored private var stream: SpokenStream?
    @ObservationIgnored private var answering: Task<Void, Never>?
    @ObservationIgnored private var silence: Task<Void, Never>?
    @ObservationIgnored private var buildWatch: Task<Void, Never>?
    @ObservationIgnored private var buildAnnounced = false

    var label: String {
        if let problem { return problem }
        switch phase {
        case .listening: return heard.isEmpty ? "Listening. A pause sends it." : "Listening..."
        case .thinking: return "Olo is thinking"
        case .speaking: return "Olo is speaking. Click to interrupt."
        case .stopped: return "Stopped"
        case .idle: return "Click the atom to talk"
        }
    }

    func start(continuing: Int?, api: OloAPI) {
        stop(spoken: false)
        self.api = api
        turns = []
        heard = ""
        build = nil
        quota = nil
        problem = nil
        buildAnnounced = false
        conversationId = continuing
        phase = .speaking
        Task {
            await say(VoiceMode.listeningWords)
            if phase != .stopped { listen() }
        }
    }

    /// Says something in Olo's voice and waits for it to finish.
    private func say(_ text: String) async {
        guard let api else { return }
        let s = SpokenStream(api: api)
        stream = s
        s.push(text)
        await s.end()
        if stream === s { stream = nil }
    }

    /// Opens the mic for the next thing the person says.
    func listen() {
        guard phase != .stopped else { return }
        heard = ""
        problem = nil
        phase = .listening
        dictation.toggle { [weak self] text, final in
            guard let self, self.phase == .listening else { return }
            self.heard = text
            self.silence?.cancel()
            let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !said.isEmpty else { return }
            self.silence = Task { [weak self] in
                try? await Task.sleep(nanoseconds: final ? 300_000_000 : 1_500_000_000)
                guard !Task.isCancelled, let self, self.phase == .listening else { return }
                self.dictation.stop()
                await self.handle(said)
            }
        }
        // The recogniser starts asynchronously; a refused permission or a missing microphone shows up shortly after.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, self.phase == .listening, let p = self.dictation.problem else { return }
            self.problem = p
            self.phase = .idle
        }
    }

    private func stopListening() {
        silence?.cancel()
        silence = nil
        dictation.stop()
    }

    private func handle(_ transcript: String) async {
        guard phase != .stopped else { return }
        turns.append(Turn(you: true, text: transcript))
        switch VoiceMode.command(transcript) {
        case .stop: stop(spoken: true)
        case .build(let prompt): await startBuild(prompt)
        case .ask(let text): await ask(text)
        }
    }

    private func ask(_ content: String) async {
        guard let api else { return }
        guard !content.isEmpty else { listen(); return }
        phase = .thinking
        let s = SpokenStream(api: api)
        stream = s
        turns.append(Turn(you: false, text: ""))
        let index = turns.count - 1
        let task = Task { [weak self] in
            guard let self else { return }
            await self.streamAnswer(content, into: s, at: index, api: api)
        }
        answering = task
        await task.value
        answering = nil
        if stream === s { stream = nil }
        AppModel.shared.noteVoiceAnswer(conversationId)
        if quota != nil { phase = .idle; return }
        if phase != .stopped { listen() }
    }

    /// Streams one answer, speaking each sentence as it completes, then waits for the voice to finish.
    private func streamAnswer(_ content: String, into s: SpokenStream, at index: Int, api: OloAPI) async {
        let sentences = SentenceStream()
        var full = ""
        var spokenAny = false
        do {
            for try await event in api.ask(OloAPI.AskInput(conversationId: conversationId, content: content)) {
                try Task.checkCancellation()
                switch event {
                case .start(let id): if id > 0 { conversationId = id }
                case .delta(let text):
                    full += text
                    if index < turns.count { turns[index].text = full }
                    let pieces = sentences.push(full)
                    for piece in pieces { s.push(piece) }
                    if !pieces.isEmpty, !spokenAny { spokenAny = true; phase = .speaking }
                case .done(let id, _): if let id, id > 0 { conversationId = id }
                case .error(let message, _, let code):
                    if code == "quota_exceeded" {
                        quota = message
                        s.push("You have used your free messages for now. Subscribe to keep talking.")
                    } else {
                        s.push("Something went wrong with that answer. Ask me again.")
                    }
                default: break
                }
            }
            for piece in sentences.flush(full) { s.push(piece) }
        } catch is CancellationError {
            s.stop()
            return
        } catch {
            if let f = error as? OloAPI.StreamFailure, f.isQuota {
                quota = f.message
                s.push("You have used your free messages for now. Subscribe to keep talking.")
            } else {
                s.push("Something went wrong with that answer. Ask me again.")
            }
        }
        await s.end()
    }

    private func startBuild(_ prompt: String) async {
        guard let api else { return }
        phase = .thinking
        do {
            let job = try await api.startBuild(OloAPI.StartBuildInput(prompt: prompt, tier: "medium", conversationId: conversationId))
            build = job
            buildAnnounced = false
            await api.kickBuild(id: job.id)
            turns.append(Turn(you: false, text: VoiceMode.buildStarted))
            phase = .speaking
            await say(VoiceMode.buildStarted)
            watchBuild(job.id)
        } catch {
            if let f = error as? OloAPI.StreamFailure, f.isQuota {
                quota = f.message
                await say("You have used your free messages for now. Subscribe to keep building.")
                phase = .idle
                return
            }
            await say("I could not start that build. Say it again in a moment.")
        }
        if phase != .stopped { listen() }
    }

    /// Polls the build; when it finishes, Olo says so between turns (never over the person).
    private func watchBuild(_ id: String) {
        guard let api else { return }
        buildWatch?.cancel()
        buildWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.phase != .stopped else { return }
                guard let job = try? await api.buildJob(id: id) else { continue }
                self.build = job
                guard ["succeeded", "failed", "cancelled"].contains(job.status) else { continue }
                // Wait for a quiet moment.
                while self.phase == .thinking || self.phase == .speaking {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled || self.phase == .stopped { return }
                }
                guard !self.buildAnnounced else { return }
                self.buildAnnounced = true
                let words: String
                switch job.status {
                case "succeeded": words = VoiceMode.buildDone(summary: job.summary, filename: job.artifact?.filename)
                case "failed": words = VoiceMode.buildFailed(error: job.error)
                default: words = "That build was cancelled."
                }
                self.stopListening()
                self.turns.append(Turn(you: false, text: words))
                self.phase = .speaking
                await self.say(words)
                if self.phase != .stopped { self.listen() }
                return
            }
        }
    }

    /// Click on the atom: interrupt the voice and listen, or pause listening, or start again.
    func tapAtom() {
        switch phase {
        case .speaking:
            stream?.stop(); stream = nil
            answering?.cancel()
            listen()
        case .listening:
            stopListening()
            phase = .idle
        case .idle, .stopped:
            phase = .idle
            listen()
        case .thinking:
            break
        }
    }

    func stop(spoken: Bool) {
        let wasRunning = !turns.isEmpty
        phase = .stopped
        stopListening()
        answering?.cancel(); answering = nil
        buildWatch?.cancel(); buildWatch = nil
        stream?.stop(); stream = nil
        if spoken, wasRunning {
            turns.append(Turn(you: false, text: VoiceMode.stopWords))
            Task { await say(VoiceMode.stopWords) }
        }
    }
}

struct TalkToOloView: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: TalkToOloSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Talk to Olo").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { TalkToOloController.shared.close() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(session.turns) { turn in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(turn.you ? "YOU" : "OLO").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                                Text(turn.text.isEmpty ? "..." : turn.text).font(.body).textSelection(.enabled)
                                    .opacity(turn.you ? 0.8 : 1)
                            }
                            .id(turn.id)
                        }
                        if session.phase == .listening, !session.heard.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("YOU").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                                Text(session.heard).font(.body).italic().opacity(0.8)
                            }
                            .id("heard")
                        }
                        if let job = session.build {
                            HStack {
                                Text(job.status == "succeeded" ? "Build ready" : job.status == "failed" ? "Build failed" : "Building: \(job.detail ?? job.stage ?? "starting")")
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                Spacer()
                                if job.status == "succeeded", let cid = session.conversationId {
                                    Button("Open") { openInChat(cid) }
                                }
                            }
                            .padding(10).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        }
                        if let quota = session.quota {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(quota).font(.callout)
                                Button("Subscribe") { TalkToOloController.shared.close(); model.openSubscribe() }.buttonStyle(.borderedProminent)
                            }
                            .padding(10).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                .onChange(of: session.turns.count) { withAnimation { proxy.scrollTo(session.turns.last?.id, anchor: .bottom) } }
                .onChange(of: session.heard) { proxy.scrollTo("heard", anchor: .bottom) }
            }
            Divider()
            VStack(spacing: 10) {
                Button { session.tapAtom() } label: {
                    HeliusAtomView(mode: session.phase == .thinking ? .loader : .idle, size: 120)
                        .frame(width: 150, height: 150)
                        .background(Circle().fill(session.phase == .listening ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04)))
                        .overlay(Circle().stroke(session.phase == .listening ? Color.accentColor : Color.primary.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .help(session.label)
                Text(session.label).font(.callout).multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    if let cid = session.conversationId {
                        Button("Open in chat") { openInChat(cid) }
                    }
                    Button("Stop") { TalkToOloController.shared.close() }
                }
                Text("Say \"stop\" or \"that's all\" to finish. \"Build me a...\" starts a build.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(minWidth: 480, minHeight: 560)
    }

    private func openInChat(_ serverId: Int) {
        TalkToOloController.shared.close()
        model.openServerConversation(serverId)
        model.showMainWindow()
    }
}
