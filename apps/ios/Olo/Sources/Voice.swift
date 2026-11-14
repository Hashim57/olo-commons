import AVFoundation
import Foundation
import OloKit
import Speech
import UIKit

/// Who is using the speech recogniser. iOS gives an app one recognition session at a time, and
/// four things want it: dictation in the composer, Quick Ask, Talk to Olo and "Hey Olo".
enum MicOwner: String { case dictation, quickAsk, talk, wake }

/// The audio session, in one place. Recording uses play and record out of the speaker at normal
/// volume (the "measurement" mode is quiet) with Bluetooth headsets allowed; "Hey Olo" mixes with
/// other apps' music, a conversation ducks it. Playback alone is spoken audio, heard in silent mode.
enum AudioSession {
    static func record(mix: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth]
        options.insert(mix ? .mixWithOthers : .duckOthers)
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setActive(true)
    }

    static func playback() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    /// Hands the speaker back, so music that was ducked comes up again.
    static func rest() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Olo's ears and voice on the phone.
///
/// Listening: the phone's own speech recogniser turns what is said into text. Words arrive as they
/// are recognised; the caller decides what to do with them. It never fakes a result: no permission,
/// no words. One owner holds the microphone at a time, and taking it from someone else stops their
/// session first. The app always shows when it is listening, and iOS shows its own orange dot.
///
/// Speaking: Olo's voice (ElevenLabs, through helius-olo.io) when the server has a voice key and
/// the person is signed in, the phone's own voice otherwise (Speaking.swift). Audio is not
/// recorded or kept.
@MainActor
final class Voice: NSObject, ObservableObject {
    /// Why a session ended on its own.
    enum EndReason { case silence, ended, error }

    /// Who holds the microphone now, or nil when nobody is listening.
    @Published private(set) var owner: MicOwner?
    /// The words recognised so far in this session.
    @Published private(set) var transcript = ""
    /// A problem with dictation in plain words, or nil.
    @Published var problem: String?
    /// True while an answer is being read aloud.
    @Published private(set) var speaking = false

    var listening: Bool { owner != nil }
    func isListening(_ who: MicOwner) -> Bool { owner == who }

    /// Called when the microphone becomes free, so "Hey Olo" can take it back.
    var onFree: (@MainActor () -> Void)?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var onText: (@MainActor (String, Bool) -> Void)?
    private var onEnd: (@MainActor (EndReason) -> Void)?
    /// The session a result belongs to; bumped on every start and stop, so a result the recogniser
    /// delivers after its session was stopped (it does, once) is never taken for the next one's.
    private var generation = 0
    private var stopping = false
    private var resting: Task<Void, Never>?

    private var current: SpokenStream?
    private let cue = CuePlayer()

    override init() {
        super.init()
        let centre = NotificationCenter.default
        centre.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw == AVAudioSession.InterruptionType.began.rawValue
            Task { @MainActor [weak self] in self?.interrupted(began: began) }
        }
        centre.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            let devices = reason == .oldDeviceUnavailable || reason == .newDeviceAvailable
            Task { @MainActor [weak self] in if devices { self?.routeChanged() } }
        }
    }

    // MARK: Listening

    /// Starts listening for `who`. Returns nil when listening started (or was stopped again while
    /// permissions were being asked), otherwise why it could not, in plain words.
    ///
    /// `onText` receives the whole transcript so far and whether it is final. `onEnd` is called when
    /// the session ends on its own: iOS gives up after a stretch of silence or about a minute.
    @discardableResult
    func start(owner who: MicOwner, locale: Locale? = nil, onDeviceOnly: Bool = false, mix: Bool = false,
               onText: @escaping @MainActor (String, Bool) -> Void,
               onEnd: (@MainActor (EndReason) -> Void)? = nil) async -> String? {
        if owner != nil || recognition != nil { stopListening(notify: false) }
        generation += 1
        let mine = generation
        let language = locale ?? VoiceLanguage.listeningLocale()
        let name = VoiceLanguage.label(VoiceLanguage.normalise(language.identifier))
        guard let recognizer = SFSpeechRecognizer(locale: language), recognizer.isAvailable else {
            return "Speech recognition is not available for \(name) on this iPhone. Choose another language in Settings, Voice."
        }
        if onDeviceOnly, !recognizer.supportsOnDeviceRecognition {
            return "This iPhone cannot recognise \(name) on the device, and the audio must not leave it, so listening stays off."
        }
        guard await Voice.speechPermission() else {
            return "Speech recognition was refused. Allow it in Settings, Privacy and Security, Speech Recognition."
        }
        guard await Voice.microphonePermission() else {
            return "Microphone access was refused. Allow it in Settings, Privacy and Security, Microphone."
        }
        // Stopped, or started again, while the permissions were being asked.
        guard mine == generation else { return nil }
        resting?.cancel()
        do {
            try AudioSession.record(mix: mix)
        } catch {
            return "The microphone could not be started. Another app may be using it."
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = onDeviceOnly
        if who == .wake {
            // Punctuation is extra work on every partial result and the wake check ignores it.
            req.addsPunctuation = false
            req.contextualStrings = ["Hey Olo", "Olo"]
        } else {
            req.addsPunctuation = true
            req.taskHint = .dictation
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return "No microphone was found." }
        input.removeTap(onBus: 0)
        Voice.installTap(on: input, format: format, into: req)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return "The microphone could not be started."
        }
        request = req
        transcript = ""
        stopping = false
        self.onText = onText
        self.onEnd = onEnd
        owner = who
        recognition = Voice.recognise(with: recognizer, request: req) { [weak self] text, final, failure in
            Task { @MainActor [weak self] in self?.recognised(mine, text: text, final: final, failure: failure) }
        }
        return nil
    }

    /// The audio tap runs on the audio thread, so it is made outside the main actor.
    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, into request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    /// The recogniser reports on its own queue; only plain values cross back to the main actor.
    nonisolated private static func recognise(with recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                              deliver: @escaping @Sendable (String?, Bool, NSError?) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            deliver(result?.bestTranscription.formattedString, result?.isFinal ?? false, error as NSError?)
        }
    }

    private func recognised(_ session: Int, text: String?, final: Bool, failure: NSError?) {
        guard session == generation, owner != nil else { return }
        if let text {
            transcript = text
            onText?(text, final)
            // onText may have stopped the session.
            guard session == generation, owner != nil else { return }
            if final {
                let hadWords = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                endedByItself(hadWords ? .ended : .silence)
                return
            }
        }
        if let failure {
            let message = failure.localizedDescription
            // 1110 "No speech detected" and 203 "Retry": the recogniser gave up on a silence.
            let silence = failure.code == 1110 || failure.code == 203 || message.localizedCaseInsensitiveContains("no speech")
            if owner == .dictation, !stopping, !silence, !message.localizedCaseInsensitiveContains("cancel") {
                problem = "Dictation stopped: \(message)"
            }
            endedByItself(silence ? .silence : .error)
        }
    }

    /// The session ended on its own: tear down, tell its owner why, and say the microphone is free.
    private func endedByItself(_ reason: EndReason) {
        let end = onEnd
        teardown()
        end?(reason)
        if owner == nil { onFree?() }
    }

    /// Stops listening on purpose. The owner's `onEnd` is not called.
    func stopListening(notify: Bool = true) {
        guard owner != nil || recognition != nil else { return }
        stopping = true
        teardown()
        if notify { onFree?() }
    }

    private func teardown() {
        generation += 1
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognition?.cancel()
        recognition = nil
        request = nil
        onText = nil
        onEnd = nil
        owner = nil
        settle()
    }

    /// A phone call or another app took the audio: stop speaking and listening. When it ends,
    /// "Hey Olo" may take the microphone back.
    private func interrupted(began: Bool) {
        if began {
            hush()
            if owner != nil { endedByItself(.error) }
        } else {
            onFree?()
        }
    }

    /// Headphones went in or out: the microphone's format changed under the session, so end it and
    /// let its owner open a fresh one.
    private func routeChanged() {
        if owner != nil { endedByItself(.ended) }
    }

    /// Lets go of the audio session a moment after the last use, never between two turns.
    private func settle() {
        resting?.cancel()
        resting = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, self.owner == nil, !self.speaking, !self.cue.playing else { return }
            AudioSession.rest()
        }
    }

    private static func speechPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in c.resume(returning: status == .authorized) }
            }
        }
    }

    private static func microphonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    // MARK: Speaking

    /// A new spoken stream. It stops whatever was speaking first, so two answers are never read
    /// over each other.
    func stream(api: OloAPI) -> SpokenStream {
        current?.stop()
        resting?.cancel()
        // While the microphone is in use the session belongs to the recogniser and must not change.
        if owner == nil { AudioSession.playback() }
        let stream = SpokenStream(api: api)
        stream.onActive = { [weak self, weak stream] active in
            guard let self, let stream, self.current === stream else { return }
            self.speaking = active
            if !active { self.settle() }
        }
        current = stream
        return stream
    }

    /// Reads an answer aloud, in pieces: a sentence or two first so the voice starts within about a
    /// second, then the rest in order.
    func read(_ text: String, api: OloAPI) {
        let pieces = SpeechPieces.split(text)
        guard !pieces.isEmpty else { return }
        let s = stream(api: api)
        for piece in pieces { s.push(piece) }
        Task { await s.end() }
    }

    /// Says something and returns when it has been heard (or was stopped).
    func say(_ text: String, api: OloAPI) async {
        let pieces = SpeechPieces.split(text)
        guard !pieces.isEmpty else { return }
        let s = stream(api: api)
        for piece in pieces { s.push(piece) }
        await s.end()
    }

    /// Stops reading aloud.
    func hush() {
        current?.stop()
        current = nil
        cue.stop()
        if speaking { speaking = false }
        settle()
    }

    /// Fetches "Go ahead, I'm listening." in Olo's voice once and keeps it on the phone, so the cue
    /// plays at once when it is needed.
    func prepareCue(api: OloAPI) async {
        await cue.prepare(api: api)
    }

    /// "Go ahead, I'm listening.", said when Hey Olo hears its name or the phone is shaken. Olo's own
    /// voice when the clip is on the phone, the phone's voice otherwise. Returns once it has been
    /// said. It does not count as speaking, so nothing pauses for it.
    func sayListening() async {
        resting?.cancel()
        if owner == nil { AudioSession.playback() }
        await cue.play()
        settle()
    }
}
