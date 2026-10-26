import AVFoundation
import Observation
import Speech

/// Dictation into the composer with the system recogniser (Speech framework), on the
/// device when the recogniser supports it. Words land as they are recognised; the caller
/// decides what to do with them. Nothing is sent to helius-olo.io by this; Apple's
/// recogniser is used under the Mac's own settings. It never fakes a result: no
/// permission, no words.
@MainActor @Observable
final class DictationController {
    private(set) var listening = false
    /// The words recognised so far in this session.
    private(set) var transcript = ""
    /// A problem in plain words, or nil.
    var problem: String?

    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var onText: ((String, Bool) -> Void)?

    /// Whether this Mac can recognise speech in the current locale at all.
    var available: Bool { SFSpeechRecognizer(locale: Locale.current)?.isAvailable ?? false }

    /// Starts, or stops if already listening. `onText` receives the whole transcript so far and whether it is final.
    func toggle(onText: @escaping (String, Bool) -> Void) {
        if listening { stop(); return }
        self.onText = onText
        Task { await start() }
    }

    private func start() async {
        problem = nil
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
            problem = "Dictation is not available for your language on this Mac."
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
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        } else if UserDefaults.standard.bool(forKey: Prefs.dictationOnDeviceOnly) {
            problem = "On-device dictation is not available for your language, and Olo is set to use only on-device recognition."
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
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.onText?(self.transcript, result.isFinal)
                    if result.isFinal { self.stop() }
                }
                if let error, self.listening {
                    // A stop on purpose ends the task with an error too; only say so when it was not ours.
                    let text = error.localizedDescription
                    if !text.localizedCaseInsensitiveContains("cancel") { self.problem = "Dictation stopped: \(text)" }
                    self.stop()
                }
            }
        }
    }

    func stop() {
        guard listening || task != nil else { return }
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
