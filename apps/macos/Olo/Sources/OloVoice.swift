import SwiftUI
import AVFoundation
import Foundation
import OloKit

/// Reads an answer aloud: Olo's voice (ElevenLabs, through helius-olo.io) when the server has a
/// voice key and the person is signed in, the Mac's own voice otherwise. One answer at a time;
/// asking again for the one playing stops it.
@MainActor @Observable
final class OloVoice: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    private(set) var speakingTurn: UUID?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    func toggle(turn: UUID, text: String, api: OloAPI) {
        if speakingTurn == turn { stop(); return }
        stop()
        speakingTurn = turn
        Task {
            if let data = await api.speak(text), speakingTurn == turn, let p = try? AVAudioPlayer(data: data) {
                player = p
                p.delegate = self
                p.play()
                return
            }
            guard speakingTurn == turn else { return }
            let plain = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "[#*`>|]", with: " ", options: .regularExpression)
            synth.speak(AVSpeechUtterance(string: String(plain.prefix(5000))))
        }
    }

    func stop() {
        player?.stop()
        player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speakingTurn = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
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
