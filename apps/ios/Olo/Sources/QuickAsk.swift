import OloKit
import SwiftUI

/// Quick Ask: one question, one answer, from anywhere in the app.
///
/// It opens from a shake, from "Hey Olo", from the Ask Olo control or shortcut (olo://ask?listen=1)
/// and from the Quick Ask home-screen action. A big Olo to tap, a text field, and the answer
/// streaming in underneath. Speaking ends with 1.5 s of silence and the question goes by itself;
/// typing ends with Send. A question that was spoken is answered aloud.
///
/// The answer is a normal Olo answer, saved as a new conversation (so "Open in chat" continues it
/// with sources and verdicts), checked by Zeus as usual.
@MainActor
final class QuickAskSession: ObservableObject {
    enum Phase { case idle, cue, listening, thinking, answered }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var heard = ""
    @Published private(set) var question = ""
    @Published private(set) var item: ChatItem?
    @Published private(set) var conversationId: Int?
    @Published private(set) var problem: String?
    @Published private(set) var needsPlan = false
    @Published var typed = ""

    private weak var model: AppModel?
    private weak var voice: Voice?
    private var answering: Task<Void, Never>?
    private var silence: Task<Void, Never>?
    private var spoken = false
    private var closed = false

    static let silenceSeconds: UInt64 = 1_500_000_000

    func begin(_ request: HandsFree.QuickAskRequest, model: AppModel, voice: Voice) {
        guard self.model == nil else { return }
        self.model = model
        self.voice = voice
        if !request.question.isEmpty {
            spoken = true
            ask(request.question)
        } else if request.listen {
            Task {
                if request.cue {
                    phase = .cue
                    await voice.sayListening()
                }
                if !closed { await listen() }
            }
        }
    }

    /// Opens the microphone for one question.
    func listen() async {
        guard let voice, !closed else { return }
        voice.hush()
        answering?.cancel()
        heard = ""
        problem = nil
        phase = .listening
        let reason = await voice.start(owner: .quickAsk, onText: { [weak self] text, final in
            self?.heardText(text, final: final)
        }, onEnd: { [weak self] _ in
            // iOS closed the session on a silence: wait for a tap, never pretend to listen.
            guard let self, self.phase == .listening, self.silence == nil else { return }
            self.phase = .idle
        })
        if let reason, phase == .listening {
            problem = reason
            phase = .idle
        }
    }

    private func heardText(_ text: String, final: Bool) {
        guard phase == .listening else { return }
        heard = text
        silence?.cancel()
        silence = nil
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return }
        silence = Task { [weak self] in
            try? await Task.sleep(nanoseconds: final ? 300_000_000 : QuickAskSession.silenceSeconds)
            guard !Task.isCancelled, let self, self.phase == .listening else { return }
            self.silence = nil
            self.voice?.stopListening()
            self.spoken = true
            self.ask(said)
        }
    }

    func stopListening() {
        silence?.cancel(); silence = nil
        if voice?.isListening(.quickAsk) == true { voice?.stopListening() }
        if phase == .listening || phase == .cue { phase = .idle }
    }

    func send() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typed = ""
        stopListening()
        spoken = false
        ask(text)
    }

    func askAnother() {
        answering?.cancel()
        voice?.hush()
        item = nil
        question = ""
        conversationId = nil
        needsPlan = false
        Task { await listen() }
    }

    private func ask(_ text: String) {
        guard let model, let voice else { return }
        answering?.cancel()
        voice.hush()
        question = text
        problem = nil
        needsPlan = false
        phase = .thinking
        item = ChatItem(role: "assistant", text: "", status: "Thinking", streaming: true)
        let readAloud = spoken || model.speakAnswers
        answering = Task { [weak self] in
            var outcome = StreamOutcome()
            var failure: String?
            do {
                try await model.ensureSession()
                var input = OloAPI.AskInput(conversationId: nil, content: text, grounded: model.grounded, brain: model.brain)
                input.client = "ios"
                for try await event in model.api.ask(input) {
                    if Task.isCancelled { return }
                    outcome.apply(event)
                    guard let self else { return }
                    self.item?.text = outcome.text
                    self.item?.status = outcome.completed ? nil : outcome.status
                    self.item?.verification = outcome.verification
                    self.item?.sources = outcome.sources
                    self.item?.notices = outcome.notices
                    self.item?.artifacts = outcome.artifacts
                    if let id = outcome.conversationId, id > 0 { self.conversationId = id }
                    if case .error(let message, _, let code) = event {
                        failure = message
                        if code == "quota_exceeded" { self.needsPlan = true }
                    }
                }
            } catch let stream as OloAPI.StreamFailure {
                failure = stream.message
                if stream.isQuota { self?.needsPlan = true }
            } catch is CancellationError {
                return
            } catch {
                failure = OloAPI.isTransientNetworkError(error) ? "Olo could not be reached. Check your connection and ask again." : error.localizedDescription
            }
            guard let self, !Task.isCancelled else { return }
            self.item?.streaming = false
            self.item?.status = nil
            if let failure {
                self.problem = failure
                if outcome.text.isEmpty { self.item = nil }
            }
            self.phase = .answered
            if readAloud, failure == nil, !outcome.text.isEmpty, !self.closed { voice.read(outcome.text, api: model.api) }
            await model.loadConversations()
        }
    }

    func close() {
        closed = true
        silence?.cancel()
        answering?.cancel()
        if voice?.isListening(.quickAsk) == true { voice?.stopListening() }
        voice?.hush()
    }
}

struct QuickAskView: View {
    let request: HandsFree.QuickAskRequest
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var voice: Voice
    @EnvironmentObject var hands: HandsFree
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = QuickAskSession()
    @FocusState private var typing: Bool

    private var label: String {
        switch session.phase {
        case .cue: return "Go ahead, I'm listening."
        case .listening: return session.heard.isEmpty ? "Listening. A pause sends it." : "Listening..."
        case .thinking: return "Olo is thinking"
        case .answered: return voice.speaking ? "Olo is speaking. Tap to stop." : "Tap Olo to ask another"
        case .idle: return "Tap Olo to talk, or type below"
        }
    }

    private var mood: OloMood {
        switch session.phase {
        case .thinking: return .thinking
        case .listening, .cue: return .happy
        case .answered:
            guard let v = session.item?.verification else { return .idle }
            return v.flaggedCount > 0 ? .unsure : .happy
        case .idle: return .idle
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Button { tapOlo() } label: {
                        ListeningOlo(mood: mood, live: session.phase == .listening || session.phase == .cue, size: 110)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(session.phase == .listening ? "Stop listening" : "Talk to Olo")
                    Text(label).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if session.phase == .listening, !session.heard.isEmpty {
                        Text(session.heard).font(.title3).italic().multilineTextAlignment(.center)
                    }
                    if !session.question.isEmpty {
                        Text(session.question).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let item = session.item {
                        MessageView(item: item)
                    }
                    if let problem = session.problem {
                        Text(problem).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if session.needsPlan {
                        Button(model.signedIn ? "See plans" : "Sign in") {
                            dismiss()
                            if model.signedIn { model.showPlans = true } else { model.showSignIn = true }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if session.phase == .answered {
                        HStack(spacing: 10) {
                            if let id = session.conversationId {
                                Button("Open in chat") { hands.openInChat(id) }
                            }
                            if let text = session.item?.text, !text.isEmpty {
                                Button(voice.speaking ? "Stop reading" : "Read aloud") {
                                    if voice.speaking { voice.hush() } else { voice.read(text, api: model.api) }
                                }
                            }
                            Button("Ask another") { session.askAnother() }
                        }
                        .buttonStyle(.bordered).font(.subheadline)
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    TextField("Type a question", text: $session.typed, axis: .vertical).lineLimit(1...4).focused($typing)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                        .onSubmit { session.send() }
                    Button { typing = false; session.send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                    }
                    .disabled(session.typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.bar)
            }
            .navigationTitle("Quick Ask")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { hands.openTalk() } label: { Image(systemName: "waveform") }.accessibilityLabel("Talk to Olo")
                }
            }
        }
        .onAppear { session.begin(request, model: model, voice: voice) }
        .onDisappear { session.close() }
        .onChange(of: typing) { _, now in if now { session.stopListening() } }
    }

    private func tapOlo() {
        hands.tap()
        switch session.phase {
        case .listening, .cue: session.stopListening()
        case .thinking: break
        case .answered:
            if voice.speaking { voice.hush() } else { session.askAnother() }
        case .idle: Task { await session.listen() }
        }
    }
}

/// Olo with a ring that breathes while the microphone is open, so listening is always visible.
struct ListeningOlo: View {
    let mood: OloMood
    let live: Bool
    var size: CGFloat = 120
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.accentColor.opacity(live ? 0.55 : 0), lineWidth: 3)
                .frame(width: size * 1.28, height: size * 1.28)
                .scaleEffect(live && pulse ? 1.12 : 1.0)
                .opacity(live && pulse ? 0.35 : 1.0)
            Circle().fill(live ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
                .frame(width: size * 1.28, height: size * 1.28)
            OloFace(mood: mood, size: size, animated: true)
        }
        .frame(width: size * 1.5, height: size * 1.5)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true } }
    }
}
