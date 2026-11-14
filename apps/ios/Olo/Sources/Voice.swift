import AVFoundation
import Foundation
import OloKit
import Speech

/// Talking to Olo: the phone's own speech recognition turns what is said into the question, and
/// the phone's own voice reads the answer. Audio is not recorded or kept.
@MainActor
final class Voice: NSObject, ObservableObject {
    @Published var listening = false
    @Published var transcript = ""
    @Published var problem: String?

    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private let synth = AVSpeechSynthesizer()

    private func allowed() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in c.resume(returning: status == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func start() async {
        guard !listening else { return }
        problem = nil
        guard await allowed(), let recognizer, recognizer.isAvailable else {
            problem = "Olo needs the microphone and speech recognition. You can allow them in Settings."
            return
        }
        hush()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
            engine.prepare()
            try engine.start()
            transcript = ""
            listening = true
            recognition = recognizer.recognitionTask(with: req) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let finished = error != nil || (result?.isFinal ?? false)
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if finished { self.halt() }
                }
            }
        } catch {
            problem = "The microphone could not be started."
            halt()
        }
    }

    private func halt() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognition?.cancel()
        request = nil; recognition = nil
        listening = false
    }

    /// Stops listening and returns what was heard.
    func finish() -> String {
        let heard = transcript
        halt()
        return heard.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func speak(_ text: String) {
        let plain = VoiceMode.plainForDisplay(text)
        guard !plain.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: plain)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-")) ?? AVSpeechSynthesisVoice(language: "en-GB")
        synth.speak(utterance)
    }

    func hush() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }
}
