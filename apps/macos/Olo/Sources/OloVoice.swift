import SwiftUI
import AVFoundation
import Foundation
import OloKit

/// Reads an answer aloud: Olo's voice (ElevenLabs, through helius-olo.io) when the server has a
/// voice key and the person is signed in, the Mac's own voice otherwise. One answer at a time;
/// asking again for the one playing stops it.
///
/// The answer is read in pieces (SpeechPieces): a sentence or two first, so the voice starts within
/// about a second, then the rest in order, each piece fetched while the one before it plays, so the
/// joins are close to seamless. If a later piece cannot be fetched, the Mac's voice reads what is left.
@MainActor @Observable
final class OloVoice: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    private(set) var speakingTurn: UUID?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let synth = AVSpeechSynthesizer()
    @ObservationIgnored private var finished: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self
    }

    func toggle(turn: UUID, text: String, api: OloAPI) {
        if speakingTurn == turn { stop(); return }
        stop()
        speakingTurn = turn
        let pieces = SpeechPieces.split(text)
        Task { await read(turn: turn, pieces: pieces, api: api) }
    }

    private func read(turn: UUID, pieces: [String], api: OloAPI) async {
        guard !pieces.isEmpty else { stop(); return }
        var next: Task<Data?, Never> = Task { await api.speak(pieces[0], next: pieces.count > 1 ? pieces[1] : nil) }
        for i in pieces.indices {
            let data = await next.value
            guard speakingTurn == turn else { return }
            guard let data, let p = try? AVAudioPlayer(data: data) else {
                // Olo's voice could not read this piece: the Mac reads what is left.
                deviceVoice(pieces[i...].joined(separator: " "))
                return
            }
            if i + 1 < pieces.count {
                let (current, following, after) = (pieces[i], pieces[i + 1], i + 2 < pieces.count ? pieces[i + 2] : nil)
                next = Task { await api.speak(following, previous: current, next: after) }
            }
            player = p
            p.delegate = self
            p.prepareToPlay()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                finished = c
                if !p.play() { resumeFinished() }
            }
            guard speakingTurn == turn else { return }
        }
        stop()
    }

    private func deviceVoice(_ text: String) {
        synth.speak(MacVoice.utterance(String(text.prefix(5000))))
    }

    private func resumeFinished() {
        finished?.resume()
        finished = nil
    }

    func stop() {
        player?.stop()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speakingTurn = nil
        resumeFinished()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.resumeFinished() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.resumeFinished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.stop() }
    }
}

/// The Mac's own voice, used when Olo's voice cannot read (signed out, offline, or no voice key on the
/// server): the best British English voice installed (Premium, then Enhanced, then the default), so the
/// fallback sounds as little like a robot as the Mac allows. More voices: System Settings > Accessibility >
/// Spoken Content > System voice > Manage Voices.
enum MacVoice {
    static let best: AVSpeechSynthesisVoice? = {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let british = voices.filter { $0.language == "en-GB" }
        let pool = british.isEmpty ? voices.filter { $0.language.hasPrefix("en") } : british
        return pool.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "en-GB")
    }()

    static func utterance(_ text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        if let best { u.voice = best }
        return u
    }
}

/// The two-hour nudge above the composer: calm, green, dismissable.
struct BreakNudgeBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.showBreakNudge {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "leaf").foregroundStyle(.green)
                (Text(BreakReminder.title + ". ").bold() + Text(BreakReminder.message))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { model.showBreakNudge = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Dismiss")
            }
            .font(.callout)
            .padding(10)
            .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.green.opacity(0.35)))
        }
    }
}

/// A spoken stream for Talk to Olo: pieces are pushed as the answer is written and spoken in
/// order, each fetched while the one before it plays. `end()` returns when the last piece has been
/// heard (or at once if stopped). A piece Olo's voice cannot read is spoken by the Mac's own voice,
/// so nothing is skipped.
@MainActor
final class SpokenStream: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
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
    private(set) var spokeWithOlo = false

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
        finished?.resume(); finished = nil
    }

    private func fetch(_ i: Int) {
        guard i < queue.count, fetches[i] == nil else { return }
        let (text, previous, next) = (queue[i], i > 0 ? queue[i - 1] : nil, i + 1 < queue.count ? queue[i + 1] : nil)
        let api = self.api
        fetches[i] = Task { await api.speak(text, previous: previous, next: next) }
    }

    private func run() async {
        while !stopped {
            if played >= queue.count {
                if ended { break }
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in wake = c }
                continue
            }
            let i = played
            fetch(i); fetch(i + 1)
            let data: Data? = await fetches[i]?.value ?? nil
            if stopped { break }
            fetch(i + 2)
            if let data, let p = try? AVAudioPlayer(data: data) {
                spokeWithOlo = true
                player = p
                p.delegate = self
                p.prepareToPlay()
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    finished = c
                    if !p.play() { finished?.resume(); finished = nil }
                }
                player = nil
            } else {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    finished = c
                    synth.speak(MacVoice.utterance(queue[i]))
                }
            }
            played += 1
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finished?.resume(); self.finished = nil }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finished?.resume(); self.finished = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished?.resume(); self.finished = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished?.resume(); self.finished = nil }
    }
}
