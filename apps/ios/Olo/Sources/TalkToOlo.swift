import OloKit
import SwiftUI
import UIKit

/// Talk to Olo: a whole conversation by voice, hands free.
///
/// Opened from the waveform button in the chat, the Talk to Olo home-screen action, olo://talk, or
/// "Hey Olo, let's talk". Olo says "Go ahead, I'm listening.", the microphone opens, a pause of
/// 1.5 s sends what was said, and Olo's voice reads the answer sentence by sentence while it is
/// still being written. Then the microphone opens again for the follow-up, in the same
/// conversation, until the person taps Stop or says "stop", "that's all" or "goodbye". "Build me a
/// landing page for a bakery" starts a build: Olo says it is on it, keeps talking, and reads the
/// summary when the build is done, between turns. Everything said is shown on screen and the
/// conversation is saved like any other. The same state machine as the Mac's.
@MainActor
final class TalkSession: ObservableObject {
    enum Phase { case idle, listening, thinking, speaking, stopped }
    struct Turn: Identifiable, Equatable { let id = UUID(); let you: Bool; var text: String }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var turns: [Turn] = []
    @Published private(set) var heard = ""
    @Published private(set) var conversationId: Int?
    @Published private(set) var build: BuildJob?
    @Published private(set) var quota: String?
    @Published private(set) var problem: String?

    private weak var model: AppModel?
    private weak var voice: Voice?
    private var stream: SpokenStream?
    private var answering: Task<Void, Never>?
    private var silence: Task<Void, Never>?
    private var buildWatch: Task<Void, Never>?
    private var buildAnnounced = false
    /// When the microphone last opened or the person last spoke, for the keep-listening limit.
    private var turnStartedAt = Date.distantPast
    private var reopen: Task<Void, Never>?
    /// iOS closes a recognition session after a stretch of silence or about a minute. While it is
    /// still the person's turn the microphone is opened again, for up to this long since they last
    /// spoke; then Olo waits for a tap, so a forgotten phone does not hold the microphone all afternoon.
    static let keepListening: TimeInterval = 3 * 60

    var label: String {
        if let problem { return problem }
        switch phase {
        case .listening: return heard.isEmpty ? "Listening. A pause sends it." : "Listening..."
        case .thinking: return "Olo is thinking"
        case .speaking: return "Olo is speaking. Tap to interrupt."
        case .stopped: return "Stopped"
        case .idle: return "Tap Olo to talk"
        }
    }

    func start(continuing: Int?, model: AppModel, voice: Voice) {
        stop(spoken: false)
        self.model = model
        self.voice = voice
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
        guard let model, let voice else { return }
        let s = voice.stream(api: model.api)
        stream = s
        s.push(text)
        await s.end()
        if stream === s { stream = nil }
    }

    /// Opens the microphone for the next thing the person says.
    func listen() {
        guard phase != .stopped else { return }
        heard = ""
        problem = nil
        phase = .listening
        turnStartedAt = Date()
        open()
    }

    /// Starts a recognition session (listen() for a new turn; again when iOS gave up mid-turn).
    private func open() {
        guard let voice else { return }
        Task { [weak self] in
            let reason = await voice.start(owner: .talk, onText: { [weak self] text, final in
                self?.heardText(text, final: final)
            }, onEnd: { [weak self] _ in
                self?.sessionEnded()
            })
            guard let self, let reason, self.phase == .listening else { return }
            self.problem = reason
            self.phase = .idle
        }
    }

    private func heardText(_ text: String, final: Bool) {
        // Only while listening. Stopping the recogniser makes iOS send one last, final result; taken
        // as a new one it would send the same question twice and two answers would be read at once.
        guard phase == .listening else { return }
        heard = text
        silence?.cancel()
        silence = nil
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        turnStartedAt = Date()
        silence = Task { [weak self] in
            try? await Task.sleep(nanoseconds: final ? 300_000_000 : 1_500_000_000)
            guard !Task.isCancelled, let self, self.phase == .listening else { return }
            self.silence = nil
            self.phase = .thinking
            self.voice?.stopListening()
            await self.handle(said)
        }
    }

    /// The session ended on its own while it is still the person's turn: open the microphone again,
    /// so "Listening" is true for as long as it is shown.
    private func sessionEnded() {
        guard phase == .listening, silence == nil else { return }
        if Date().timeIntervalSince(turnStartedAt) > TalkSession.keepListening {
            phase = .idle
            return
        }
        reopen?.cancel()
        reopen = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, self.phase == .listening else { return }
            self.open()
        }
    }

    /// The language to listen for changed: if listening now, start again in it.
    func languageChanged() {
        guard phase == .listening else { return }
        stopListening()
        listen()
    }

    private func stopListening() {
        silence?.cancel()
        silence = nil
        reopen?.cancel()
        reopen = nil
        if voice?.isListening(.talk) == true { voice?.stopListening() }
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
        guard let model, let voice else { return }
        guard !content.isEmpty else { listen(); return }
        phase = .thinking
        let s = voice.stream(api: model.api)
        stream = s
        turns.append(Turn(you: false, text: ""))
        let index = turns.count - 1
        let task = Task { [weak self] in
            guard let self else { return }
            await self.streamAnswer(content, into: s, at: index, model: model)
        }
        answering = task
        await task.value
        answering = nil
        if stream === s { stream = nil }
        await model.loadConversations()
        if quota != nil { phase = .idle; return }
        if phase != .stopped { listen() }
    }

    /// Streams one answer, speaking each sentence as it completes, then waits for the voice to finish.
    private func streamAnswer(_ content: String, into s: SpokenStream, at index: Int, model: AppModel) async {
        let sentences = SentenceStream()
        var full = ""
        var spokenAny = false
        do {
            try await model.ensureSession()
            var input = OloAPI.AskInput(conversationId: conversationId, content: content, brain: model.brain)
            input.client = "ios"
            for try await event in model.api.ask(input) {
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
                        tell("You have used your free messages for now. Subscribe to keep talking.", into: s, at: index, keeping: full)
                    } else {
                        tell("Something went wrong with that answer. Ask me again.", into: s, at: index, keeping: full)
                    }
                default: break
                }
            }
            let rest = sentences.flush(full)
            for piece in rest { s.push(piece) }
            if !rest.isEmpty, !spokenAny, phase == .thinking { phase = .speaking }
        } catch is CancellationError {
            s.stop()
            return
        } catch {
            if let f = error as? OloAPI.StreamFailure, f.isQuota {
                quota = f.message
                tell("You have used your free messages for now. Subscribe to keep talking.", into: s, at: index, keeping: full)
            } else {
                tell("Something went wrong with that answer. Ask me again.", into: s, at: index, keeping: full)
            }
        }
        await s.end()
    }

    /// Speaks a problem and shows it in Olo's turn too, so the panel never sits on "..." after a failed answer.
    private func tell(_ words: String, into s: SpokenStream, at index: Int, keeping full: String) {
        s.push(words)
        if index < turns.count { turns[index].text = full.isEmpty ? words : full + "\n\n" + words }
        if phase == .thinking { phase = .speaking }
    }

    private func startBuild(_ prompt: String) async {
        guard let model else { return }
        phase = .thinking
        do {
            try await model.ensureSession()
            let job = try await model.api.startBuild(OloAPI.StartBuildInput(prompt: prompt, tier: "medium", conversationId: conversationId))
            build = job
            buildAnnounced = false
            await model.api.kickBuild(id: job.id)
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
        guard let model else { return }
        let api = model.api
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

    /// A tap on Olo: interrupt the voice and listen, or pause listening, or start again.
    func tapOlo() {
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
    let request: HandsFree.TalkRequest
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var voice: Voice
    @EnvironmentObject var hands: HandsFree
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = TalkSession()
    /// The language to listen for: "auto" follows the phone's language. Shared with dictation.
    @AppStorage(VoiceLanguage.preferenceKey) private var voiceLanguage: String = VoiceLanguage.auto

    private var mood: OloMood {
        switch session.phase {
        case .thinking: return .thinking
        case .listening, .speaking: return .happy
        case .idle, .stopped: return .idle
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(session.turns) { turn in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(turn.you ? "YOU" : "OLO").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                    Text(TalkToOloView.shown(turn)).font(.body).textSelection(.enabled).opacity(turn.you ? 0.8 : 1)
                                }
                                .id(turn.id)
                            }
                            if session.phase == .listening, !session.heard.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("YOU").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                    Text(session.heard).font(.body).italic().opacity(0.8)
                                }
                                .id("heard")
                            }
                            if let job = session.build {
                                HStack {
                                    Text(job.status == "succeeded" ? "Build ready" : job.status == "failed" ? "Build failed" : "Building: \(job.detail ?? job.stage ?? "starting")")
                                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                    Spacer()
                                    if job.status == "succeeded", let cid = session.conversationId {
                                        Button("Open") { leave(to: cid) }
                                    }
                                }
                                .padding(10).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator)))
                            }
                            if let quota = session.quota {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(quota).font(.callout)
                                    Button(model.signedIn ? "See plans" : "Sign in") {
                                        close()
                                        if model.signedIn { model.showPlans = true } else { model.showSignIn = true }
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                .padding(10).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator)))
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                    }
                    .onChange(of: session.turns) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                    .onChange(of: session.heard) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
                Divider()
                VStack(spacing: 10) {
                    Button { hands.tap(); session.tapOlo() } label: {
                        ListeningOlo(mood: mood, live: session.phase == .listening, size: 104)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(session.label)
                    Text(session.label).font(.callout).multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        if let cid = session.conversationId {
                            Button("Open in chat") { leave(to: cid) }
                        }
                        Button("Stop") { close() }
                    }
                    .buttonStyle(.bordered)
                    Text("Say \"stop\" or \"that's all\" to finish. \"Build me a...\" starts a build.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack(spacing: 6) {
                        Text("Listening in").font(.caption).foregroundStyle(.secondary)
                        Picker("Language to listen for", selection: $voiceLanguage) {
                            Text("Automatic (\(VoiceLanguage.label(VoiceLanguage.resolve(preference: VoiceLanguage.auto, deviceLocale: Locale.current.identifier))))").tag(VoiceLanguage.auto)
                            ForEach(VoiceLanguage.options) { option in Text(option.label).tag(option.code) }
                        }
                        .labelsHidden()
                        .onChange(of: voiceLanguage) { _, _ in session.languageChanged() }
                    }
                    Text("Olo answers in the language you speak.").font(.caption).foregroundStyle(.secondary)
                    if !model.signedIn {
                        Text("Sign in to hear Olo's own voice. Until then this iPhone's voice reads the answers.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
            }
            .navigationTitle("Talk to Olo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { close() } } }
        }
        .onAppear {
            // The screen stays awake for the length of the conversation.
            UIApplication.shared.isIdleTimerDisabled = true
            session.start(continuing: request.conversationId, model: model, voice: voice)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            session.stop(spoken: false)
            voice.hush()
        }
    }

    /// Olo's turns without Markdown marks or dashes (VoiceMode.plainForDisplay); what was heard as said.
    private static func shown(_ turn: TalkSession.Turn) -> String {
        let text = turn.you ? turn.text : VoiceMode.plainForDisplay(turn.text)
        return text.isEmpty ? "..." : text
    }

    private func close() {
        session.stop(spoken: false)
        dismiss()
    }

    private func leave(to conversationId: Int) {
        session.stop(spoken: false)
        hands.openInChat(conversationId)
    }
}
