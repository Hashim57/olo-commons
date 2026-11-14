import Combine
import CoreMotion
import Foundation
import OloKit
import Speech
import SwiftUI
import UIKit

/// Hands free: "Hey Olo", shake to ask, and the two voice screens they open (Quick Ask and Talk
/// to Olo). The same behaviour as the earlier iPhone app, on the phone's own frameworks.
///
/// What iOS allows: an app cannot listen for a wake word or feel a shake once it has been closed.
/// "Hey Olo" listens while Olo is open on screen, only when it has been turned on, with speech
/// recognised on the phone so the audio never leaves it. With "Keep listening on the Home Screen"
/// on as well, it carries on while Olo is still running in the background, and then the answer is
/// read aloud. Outside the app, the Ask Olo shortcut and control do the job instead.
@MainActor
final class HandsFree: ObservableObject {
    struct QuickAskRequest: Identifiable, Equatable {
        let id = UUID()
        var question = ""
        /// Open with the microphone listening.
        var listen = true
        /// Say "Go ahead, I'm listening." before listening (a shake does; a tap does not).
        var cue = false
    }

    struct TalkRequest: Identifiable, Equatable {
        let id = UUID()
        var conversationId: Int?
    }

    enum WakeState: Equatable {
        case off, starting, listening
        /// The wake phrase was heard; the text is what has been said since.
        case heard(String)
        case unavailable(String)
    }

    @Published var quickAsk: QuickAskRequest? { didSet { if quickAsk != oldValue { refresh() } } }
    @Published var talk: TalkRequest? { didSet { if talk != oldValue { refresh() } } }
    /// Set when a voice screen wants the chat to show a conversation; RootView switches tab.
    @Published var showChat = 0

    /// "Listen for Hey Olo" while the app is open. Off until the person turns it on.
    @Published var heyOlo: Bool = UserDefaults.standard.bool(forKey: "olo.heyOlo") {
        didSet { UserDefaults.standard.set(heyOlo, forKey: "olo.heyOlo"); if !heyOlo { wakeFailed = false; refused = [] }; refresh() }
    }
    /// Keep listening while Olo is still running in the background. Off until turned on.
    @Published var heyOloBackground: Bool = UserDefaults.standard.bool(forKey: "olo.heyOloBackground") {
        didSet { UserDefaults.standard.set(heyOloBackground, forKey: "olo.heyOloBackground"); refresh() }
    }
    /// Shake the phone to ask while the app is open. On unless turned off.
    @Published var shakeToAsk: Bool = (UserDefaults.standard.object(forKey: "olo.shakeToAsk") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(shakeToAsk, forKey: "olo.shakeToAsk"); refresh() }
    }
    @Published var haptics: Bool = (UserDefaults.standard.object(forKey: "olo.haptics") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(haptics, forKey: "olo.haptics") }
    }
    @Published private(set) var wakeState: WakeState = .off

    private weak var model: AppModel?
    private weak var voice: Voice?
    private var foreground = true
    private var bag: Set<AnyCancellable> = []
    private let motion = ShakeWatcher()

    // Hey Olo
    private var tracker = WakeTracker()
    private var silenceTimer: Task<Void, Never>?
    private var wakeTimer: Task<Void, Never>?
    private var ackTimer: Task<Void, Never>?
    private var restartTimer: Task<Void, Never>?
    private var startingWake = false
    private var wakeFailed = false
    private var refused: Set<String> = []
    private var restarts: [Date] = []
    private var sessionStartedAt = Date.distantPast

    static let silence: TimeInterval = 1.5
    static let nothingAfterWake: TimeInterval = 6
    /// A pause this long after "Hey Olo" gets "I'm listening"; carrying straight on into the question does not.
    static let ackAfter: TimeInterval = 0.65
    static let restartDelay: TimeInterval = 0.35
    /// More quick failures than this inside the window means something is wrong; stop rather than spin.
    static let maxRestarts = 8
    static let restartWindow: TimeInterval = 30
    /// A session that lasted longer than this ended normally (iOS limits, silence) and is not a failure.
    static let healthySession: TimeInterval = 3

    /// Called once, when the app's objects exist.
    func attach(model: AppModel, voice: Voice) {
        guard self.model == nil else { return }
        self.model = model
        self.voice = voice
        voice.onFree = { [weak self] in
            self?.after(0.5) { [weak self] in self?.refresh() }
        }
        // When Olo stops speaking, what it said is behind the offset, so it never hears itself.
        voice.$speaking.removeDuplicates().sink { [weak self] speaking in
            if !speaking { self?.tracker.speechEnded() }
        }.store(in: &bag)
        model.$termsAccepted.removeDuplicates().sink { [weak self] _ in
            self?.after(0.1) { [weak self] in self?.refresh() }
        }.store(in: &bag)
        motion.onShake = { [weak self] in self?.shaken() }
        refresh()
    }

    func sceneChanged(active: Bool) {
        guard foreground != active else { return }
        foreground = active
        refresh()
    }

    // MARK: Opening the voice screens

    func openQuickAsk(question: String = "", listen: Bool = true, cue: Bool = false) {
        guard model?.needsTerms == false else { return }
        talk = nil
        quickAsk = QuickAskRequest(question: question, listen: listen && question.isEmpty, cue: cue)
    }

    func openTalk(conversationId: Int? = nil) {
        guard model?.needsTerms == false else { return }
        quickAsk = nil
        talk = TalkRequest(conversationId: conversationId)
    }

    func handle(_ entry: VoiceEntry) {
        switch entry {
        case .quickAsk: openQuickAsk()
        case .talk: openTalk()
        }
    }

    /// A voice screen asks for a conversation to be shown in the chat.
    func openInChat(_ conversationId: Int) {
        quickAsk = nil
        talk = nil
        showChat += 1
        guard let model else { return }
        Task {
            await model.loadConversations()
            if let c = model.conversations.first(where: { $0.id == conversationId }) { await model.open(c) }
        }
    }

    func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        if haptics { UIImpactFeedbackGenerator(style: style).impactOccurred() }
    }

    // MARK: What should be running

    private var termsAccepted: Bool { model?.needsTerms == false }
    private var wakeWanted: Bool { termsAccepted && heyOlo && quickAsk == nil && talk == nil && (foreground || heyOloBackground) }
    private var shakeWanted: Bool {
        termsAccepted && shakeToAsk && quickAsk == nil && talk == nil && (foreground || (heyOlo && heyOloBackground))
    }

    /// Starts and stops Hey Olo and the shake watcher to match the settings and what is on screen.
    private func refresh() {
        guard let voice else { return }
        if shakeWanted { motion.start() } else { motion.stop() }
        if wakeWanted {
            if voice.owner != .wake, !startingWake {
                restarts = []
                Task { await startWake() }
            }
        } else {
            restartTimer?.cancel()
            clearTimers()
            if voice.owner == .wake { voice.stopListening(notify: false) }
            if case .unavailable = wakeState, heyOlo { return }
            wakeState = .off
        }
    }

    @discardableResult
    private func after(_ seconds: TimeInterval, _ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await body()
        }
    }

    private func clearTimers() {
        silenceTimer?.cancel(); silenceTimer = nil
        wakeTimer?.cancel(); wakeTimer = nil
        ackTimer?.cancel(); ackTimer = nil
    }

    // MARK: Hey Olo

    private func startWake() async {
        guard wakeWanted, !wakeFailed, !startingWake, let voice, voice.owner != .wake else { return }
        // Dictation, Quick Ask or Talk to Olo has the microphone: wait politely, never take it.
        if voice.owner != nil {
            restartTimer?.cancel()
            restartTimer = after(1) { [weak self] in await self?.startWake() }
            return
        }
        startingWake = true
        defer { startingWake = false }
        wakeState = .starting
        var reason: String?
        // The phone's English, then the other English if iOS refuses it.
        for _ in 0..<3 {
            let offered = SFSpeechRecognizer.supportedLocales()
                .map { $0.identifier.replacingOccurrences(of: "_", with: "-") }
                .filter { !refused.contains($0) }
            let fallback = ["en-US", "en-GB"].filter { !refused.contains($0) }
            let language = WakePhrase.recognitionLanguage(deviceLocale: Locale.current.identifier, supported: offered.isEmpty ? fallback : offered)
            tracker.sessionStarted()
            clearTimers()
            sessionStartedAt = Date()
            reason = await voice.start(owner: .wake, locale: Locale(identifier: language), onDeviceOnly: true, mix: true,
                                       onText: { [weak self] text, _ in self?.wakeHeard(text) },
                                       onEnd: { [weak self] _ in self?.wakeEnded() })
            if reason == nil { break }
            if refused.contains(language) || !language.hasPrefix("en") { break }
            refused.insert(language)
        }
        if let reason {
            wakeFailed = true
            wakeState = .unavailable(reason)
            return
        }
        guard wakeWanted, voice.owner == .wake else {
            if voice.owner == .wake { voice.stopListening(notify: false) }
            if case .unavailable = wakeState {} else { wakeState = .off }
            return
        }
        wakeState = .listening
        if let api = model?.api { Task { await voice.prepareCue(api: api) } }
    }

    private func scheduleRestart() {
        restartTimer?.cancel()
        guard wakeWanted, !wakeFailed else { return }
        let now = Date()
        let quickFailure = now.timeIntervalSince(sessionStartedAt) < HandsFree.healthySession
        restarts = restarts.filter { now.timeIntervalSince($0) < HandsFree.restartWindow }
        if quickFailure { restarts.append(now) }
        if restarts.count > HandsFree.maxRestarts {
            wakeFailed = true
            wakeState = .unavailable("Hey Olo stopped because the recogniser kept ending. Turn it off and on again to retry.")
            return
        }
        restartTimer = after(HandsFree.restartDelay) { [weak self] in await self?.startWake() }
    }

    /// The session ended on its own (iOS closes long ones, and silent ones): listening carries on.
    private func wakeEnded() {
        clearTimers()
        guard wakeWanted else { wakeState = .off; return }
        if tracker.phase == .done { return }
        scheduleRestart()
    }

    private func wakeHeard(_ text: String) {
        guard let voice, voice.owner == .wake else { return }
        // In the background a new session may not be allowed to start, so the transcript is never recycled there.
        for event in tracker.heard(text, deaf: voice.speaking, canRecycle: foreground) {
            switch event {
            case .recycle:
                voice.stopListening(notify: false)
                scheduleRestart()
            case .woke:
                ackTimer?.cancel()
                ackTimer = after(HandsFree.ackAfter) { [weak self] in
                    guard let self, self.tracker.phase == .capturing, self.tracker.question.isEmpty else { return }
                    await self.ack()
                }
                wakeTimer?.cancel()
                wakeTimer = after(HandsFree.nothingAfterWake) { [weak self] in
                    guard let self, self.tracker.phase == .capturing, self.silenceTimer == nil else { return }
                    await self.finishWake(nil)
                }
            case .question(let question):
                wakeState = .heard(question)
                guard !question.isEmpty else { continue }
                ackTimer?.cancel(); ackTimer = nil
                silenceTimer?.cancel()
                silenceTimer = after(HandsFree.silence) { [weak self] in
                    guard let self else { return }
                    self.silenceTimer = nil
                    await self.finishWake(question)
                }
            }
        }
    }

    /// Says "Go ahead, I'm listening." and then takes whatever comes next as the question.
    private func ack() async {
        guard let voice else { return }
        tracker.beginAck()
        wakeTimer?.cancel(); wakeTimer = nil
        ackTimer = nil
        wakeState = .heard("")
        if haptics { UISelectionFeedbackGenerator().selectionChanged() }
        await voice.sayListening()
        guard tracker.phase == .acking, voice.owner == .wake else { return }
        tracker.ackFinished()
        wakeTimer = after(HandsFree.nothingAfterWake) { [weak self] in
            guard let self, self.tracker.phase == .afterAck, self.silenceTimer == nil else { return }
            await self.finishWake(nil)
        }
    }

    private func finishWake(_ question: String?) async {
        clearTimers()
        guard let voice, voice.owner == .wake else { return }
        let asked = (question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !foreground {
            // Olo is in the background: the session keeps running (stopping it could let iOS suspend
            // Olo), the question is answered aloud, then listening carries on.
            guard !asked.isEmpty else { rearm(); return }
            tracker.answering()
            await answerOffScreen(asked)
            rearm()
            return
        }
        tracker.finished()
        voice.stopListening(notify: false)
        if asked.isEmpty {
            if haptics { UISelectionFeedbackGenerator().selectionChanged() }
            // "Hey Olo" and nothing else: Quick Ask opens, listening. The cue has been said already.
            openQuickAsk()
        } else {
            if haptics { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            if WakePhrase.wantsConversation(asked) { openTalk() } else { openQuickAsk(question: asked, listen: false) }
        }
        // Opening a voice screen pauses Hey Olo; it starts again when the screen closes. If nothing
        // opened (the terms are not accepted yet), listening resumes on its own.
        after(2) { [weak self] in self?.refresh() }
    }

    private func rearm() {
        clearTimers()
        tracker.rearm()
        if voice?.owner == .wake { wakeState = .listening }
    }

    /// For shake to ask: true when Hey Olo had the microphone and took the question itself.
    private func summonWake() -> Bool {
        guard let voice, voice.owner == .wake, !wakeFailed else { return false }
        switch tracker.phase {
        case .waiting, .capturing:
            clearTimers()
            Task { await ack() }
            return true
        case .acking, .afterAck:
            return true
        case .answering, .done:
            return false
        }
    }

    /// Asked with Olo in the background: answered aloud, and kept in the history like any question.
    private func answerOffScreen(_ question: String) async {
        guard let model, let voice else { return }
        let sorry = "Sorry, I could not get an answer just now."
        var reply = ""
        do {
            try await model.ensureSession()
            var input = OloAPI.AskInput(conversationId: nil, content: question)
            input.client = "ios"
            for try await event in model.api.ask(input) {
                switch event {
                case .delta(let text): reply += text
                case .error(let message, _, _): if reply.isEmpty { reply = message }
                default: break
                }
            }
            await model.loadConversations()
        } catch let failure as OloAPI.StreamFailure {
            reply = failure.isQuota ? (failure.message.isEmpty ? "You have used today's free questions." : failure.message) : sorry
        } catch {
            reply = sorry
        }
        await voice.say(reply.isEmpty ? sorry : reply, api: model.api)
    }

    // MARK: Shake to ask

    /// The phone was shaken. When Hey Olo has the microphone it takes the question itself, with no
    /// hand-over to another recogniser, so it is instant; in the background that is the only way,
    /// and the answer is read aloud. Otherwise Quick Ask opens, Olo says "Go ahead, I'm listening."
    /// and listens.
    private func shaken() {
        guard shakeWanted else { return }
        tap(.medium)
        if heyOlo, summonWake() { return }
        if foreground { openQuickAsk(question: "", listen: true, cue: true) }
    }
}

/// Feels a shake. iOS gives apps no system-wide shake, so this reads the accelerometer only while
/// it is wanted (20 readings a second, which costs next to nothing); the decision is OloKit's
/// ShakeDetector. Readings never leave the phone and are not kept.
@MainActor
final class ShakeWatcher {
    var onShake: (@MainActor () -> Void)?
    private let manager = CMMotionManager()
    private var detector = ShakeDetector()
    private var running = false

    func start() {
        guard !running, manager.isAccelerometerAvailable else { return }
        running = true
        detector.reset()
        manager.accelerometerUpdateInterval = 0.05
        manager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let a = data?.acceleration else { return }
            let (x, y, z) = (a.x, a.y, a.z)
            Task { @MainActor [weak self] in self?.reading(x, y, z) }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopAccelerometerUpdates()
    }

    private func reading(_ x: Double, _ y: Double, _ z: Double) {
        guard running else { return }
        // Core Motion reports in g, gravity included, as the detector expects.
        if detector.push(x: x, y: y, z: z, timeMs: Date().timeIntervalSince1970 * 1000) { onShake?() }
    }
}
