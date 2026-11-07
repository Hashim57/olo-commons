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
        synth.speak(AVSpeechUtterance(string: String(text.prefix(5000))))
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
