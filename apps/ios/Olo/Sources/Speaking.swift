import AVFoundation
import Foundation
import OloKit

/// The phone's own voice, used when Olo's voice cannot read (signed out, offline, or no voice key
/// on the server): the best British English voice installed (Premium, then Enhanced, then the
/// default), so the fallback sounds as little like a robot as the phone allows. More voices:
/// Settings, Accessibility, Spoken Content, Voices.
enum PhoneVoice {
    static let best: AVSpeechSynthesisVoice? = {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let british = voices.filter { $0.language == "en-GB" }
        let pool = british.isEmpty ? voices.filter { $0.language.hasPrefix("en") } : british
        return pool.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "en-GB")
    }()

    /// The voice for a text: the British one for English and for text whose language cannot be told,
    /// else the best installed voice for the text's language, so an answer in German, Arabic or
    /// Japanese is read with its own sounds. Olo answers in the language it was spoken to in.
    static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        guard let lang = VoiceLanguage.languageOf(text), !lang.lowercased().hasPrefix("en") else { return best }
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let wanted = lang.replacingOccurrences(of: "_", with: "-").lowercased()
        let base = wanted.split(separator: "-").first.map(String.init) ?? wanted
        let exact = voices.filter { $0.language.replacingOccurrences(of: "_", with: "-").lowercased() == wanted }
        let pool = exact.isEmpty ? voices.filter { $0.language.lowercased().hasPrefix(base + "-") || $0.language.lowercased() == base } : exact
        return pool.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: lang) ?? best
    }

    static func utterance(_ text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        if let v = voice(for: text) { u.voice = v }
        return u
    }
}

/// A spoken stream: pieces are pushed as the answer is written and spoken in order, each fetched
/// while the one before it plays. `end()` returns when the last piece has been heard (or at once
/// if stopped). A piece Olo's voice cannot read is spoken by the phone's own voice, so nothing is
/// skipped. The same shape as the Mac's.
@MainActor
final class SpokenStream: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    /// Tells the owner when the stream starts and stops making sound.
    var onActive: (@MainActor (Bool) -> Void)?

    private let api: OloAPI
    private var queue: [String] = []
    private var fetches: [Int: Task<Data?, Never>] = [:]
    private var played = 0
    private var ended = false
    private var stopped = false
    private var running: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private var finished: CheckedContinuation<Void, Never>?
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()

    init(api: OloAPI) {
        self.api = api
        super.init()
        synth.delegate = self
    }

    func push(_ piece: String) {
        guard !stopped, !ended, !piece.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        queue.append(piece)
        if running == nil { running = Task { await run() } }
        wake?.resume(); wake = nil
    }

    func end() async {
        ended = true
        wake?.resume(); wake = nil
        await running?.value
    }

    func stop() {
        stopped = true
        player?.stop(); player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        wake?.resume(); wake = nil
        resumeFinished()
    }

    private func resumeFinished() {
        finished?.resume()
        finished = nil
    }

    private func fetch(_ i: Int) {
        guard i < queue.count, fetches[i] == nil else { return }
        let (text, previous, next) = (queue[i], i > 0 ? queue[i - 1] : nil, i + 1 < queue.count ? queue[i + 1] : nil)
        let api = self.api
        // Signed out, the server has no voice for this person: the phone reads it at once.
        guard api.token != nil else { fetches[i] = Task<Data?, Never> { nil }; return }
        fetches[i] = Task { await api.speak(text, previous: previous, next: next) }
    }

    private func run() async {
        onActive?(true)
        while !stopped {
            if played >= queue.count {
                if ended { break }
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in wake = c }
                continue
            }
            let i = played
            fetch(i); fetch(i + 1)
            var data: Data?
            if let pending = fetches[i] { data = await pending.value }
            if stopped { break }
            fetch(i + 2)
            if let data, let p = try? AVAudioPlayer(data: data) {
                player = p
                p.delegate = self
                p.prepareToPlay()
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    finished = c
                    if !p.play() { resumeFinished() }
                }
                player = nil
            } else {
                let words = queue[i]
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    finished = c
                    synth.speak(PhoneVoice.utterance(words))
                }
            }
            played += 1
        }
        onActive?(false)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.resumeFinished() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.resumeFinished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeFinished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeFinished() }
    }
}

/// "Go ahead, I'm listening.": one short clip, played at once.
@MainActor
final class CuePlayer: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    /// Versioned with the words, so a phone that kept an old clip fetches the new one.
    private static let fileName = "olo-cue-go-ahead-v1.mp3"
    private static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(fileName)
    }

    private(set) var playing = false
    private var clip: Data?
    private var fetching = false
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var finished: CheckedContinuation<Void, Never>?
    private var limit: Task<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self
        if let url = CuePlayer.fileURL, let data = try? Data(contentsOf: url), !data.isEmpty { clip = data }
    }

    func prepare(api: OloAPI) async {
        guard clip == nil, !fetching, api.token != nil else { return }
        fetching = true
        defer { fetching = false }
        guard let data = await api.speak(VoiceMode.listeningWords) else { return }
        clip = data
        if let url = CuePlayer.fileURL { try? data.write(to: url, options: [.atomic]) }
    }

    /// Plays the cue and returns when it has been said, or after two and a half seconds at most.
    func play() async {
        stop()
        playing = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finished = c
            limit = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                self?.done()
            }
            if let clip, let p = try? AVAudioPlayer(data: clip) {
                player = p
                p.delegate = self
                p.volume = 1
                if !p.play() { done() }
            } else {
                synth.speak(PhoneVoice.utterance(VoiceMode.listeningWords))
            }
        }
        playing = false
    }

    func stop() {
        player?.stop(); player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        done()
    }

    private func done() {
        limit?.cancel(); limit = nil
        finished?.resume()
        finished = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.done() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.done() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.done() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.done() }
    }
}
