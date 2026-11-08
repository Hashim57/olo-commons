import AVFoundation
import Observation
import OloKit
import Speech

/// Dictation into the composer with the system recogniser (Speech framework), on the
/// device when the recogniser supports it. Words land as they are recognised; the caller
/// decides what to do with them. Nothing is sent to helius-olo.io by this; Apple's
/// recogniser is used under the Mac's own settings. It never fakes a result: no
/// permission, no words.
///
/// The language listened for is the person's choice (VoiceLanguage, chosen in Talk to
/// Olo) or the Mac's language on Automatic; a recogniser cannot detect it on its own.
/// Each session carries a generation number, so a result the recogniser delivers after
/// its session was stopped (it does, once) can never be taken for the next session's.
@MainActor @Observable
final class DictationController {
    private(set) var listening = false
    /// The words recognised so far in this session.
    private(set) var transcript = ""
    /// A problem in plain words, or nil.
    var problem: String?

    /// Why a session ended on its own, for `onEnd`.
    enum EndReason { case silence, ended, error }

    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var onText: ((String, Bool) -> Void)?
    @ObservationIgnored private var onEnd: ((EndReason) -> Void)?
    /// The session the task belongs to; bumped on every start and stop.
    @ObservationIgnored private var generation = 0
    /// True between our own stop and the error the cancelled task reports, which is not a failure.
    @ObservationIgnored private var stopping = false

    /// Whether this Mac can recognise speech in the chosen language at all.
    var available: Bool { SFSpeechRecognizer(locale: VoiceLanguage.listeningLocale())?.isAvailable ?? false }

    /// Starts, or stops if already listening. `onText` receives the whole transcript so far and whether it is final.
    func toggle(onText: @escaping (String, Bool) -> Void) {
        if listening { stop(); return }
        start(onText: onText, onEnd: nil)
    }

    /// Starts listening (never stops). `onEnd` is called when the session ends on its own: the recogniser
    /// gives up after a stretch of silence or about a minute, which Talk to Olo answers by opening the mic
    /// again while it is still the person's turn.
    func start(onText: @escaping (String, Bool) -> Void, onEnd: ((EndReason) -> Void)?) {
        if listening { stop() }
        self.onText = onText
        self.onEnd = onEnd
        generation += 1
        let mine = generation
        Task { await begin(generation: mine) }
    }

    private func begin(generation mine: Int) async {
        problem = nil
        let locale = VoiceLanguage.listeningLocale()
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            problem = "Dictation is not available for \(VoiceLanguage.label(VoiceLanguage.normalise(locale.identifier))) on this Mac. Choose another language, or add it in System Settings > Keyboard > Dictation."
            return
        }
        guard await DictationController.speechPermission() else {
            problem = "Speech recognition was refused. Allow it in System Settings > Privacy & Security > Speech Recognition."
            return
        }
        guard await DictationController.microphonePermission() else {
            problem = "Microphone access was refused. Allow it in System Settings > Privacy & Security > Microphone."
            return
        }
        // Stopped, or started again, while the permissions were being asked.
        guard mine == generation else { return }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        } else if UserDefaults.standard.bool(forKey: Prefs.dictationOnDeviceOnly) {
            problem = "On-device dictation is not available for this language, and Olo is set to use only on-device recognition."
            return
        }
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            problem = "No microphone was found."
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            problem = "The microphone could not be started: \(error.localizedDescription)"
            return
        }
        transcript = ""
        listening = true
        stopping = false
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, mine == self.generation else { return }  // a late result from an earlier session
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.onText?(self.transcript, result.isFinal)
                    if result.isFinal {
                        let hadWords = !self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        self.finish(reason: hadWords ? .ended : .silence)
                    }
                }
                if let error, self.listening {
                    // A stop on purpose ends the task with an error too; only say so when it was not ours.
                    let text = error.localizedDescription
                    let ns = error as NSError
                    // kAFAssistantErrorDomain 1110 "No speech detected" and 203 "Retry": the recogniser gave up on a silence.
                    let silence = ns.code == 1110 || ns.code == 203 || text.localizedCaseInsensitiveContains("no speech")
                    if !self.stopping, !silence, !text.localizedCaseInsensitiveContains("cancel") { self.problem = "Dictation stopped: \(text)" }
                    self.finish(reason: silence ? .silence : .error)
                }
            }
        }
    }

    /// The session ended on its own: tear down and tell the caller why.
    private func finish(reason: EndReason) {
        let wasOurs = stopping
        stop()
        if !wasOurs { onEnd?(reason) }
    }

    func stop() {
        guard listening || task != nil else { return }
        stopping = true
        generation += 1
        listening = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    private static func speechPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status == .authorized) }
            }
        }
    }

    private static func microphonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        default: return await AVCaptureDevice.requestAccess(for: .audio)
        }
    }
}
