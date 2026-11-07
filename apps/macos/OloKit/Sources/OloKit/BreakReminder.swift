import Foundation

/// The nudge to step away after two hours of using Olo, the same words and rule as the web
/// (client/src/lib/breakReminder.ts in olo-web) and the iPhone: time counts only while Olo is in
/// front, thirty minutes away starts the count again, and a dismissed nudge comes back only after
/// another two hours of use.
public struct BreakReminder: Equatable, Sendable {
    public static let after: TimeInterval = 2 * 60 * 60
    public static let awayResets: TimeInterval = 30 * 60
    /// The most one tick (about a minute apart) can add; a longer gap was time away.
    public static let tickGrace: TimeInterval = 2 * 60
    public static let title = "Consider taking a break"
    public static let message = "Call a friend or connect with nature. Don't lose your humanity."

    public private(set) var active: TimeInterval = 0
    public private(set) var lastSeen: Date

    public init(now: Date = Date()) { lastSeen = now }

    public mutating func tick(now: Date, visible: Bool) {
        guard visible else { return }
        let gap = now.timeIntervalSince(lastSeen)
        if gap >= Self.awayResets { active = 0 } else { active += min(max(0, gap), Self.tickGrace) }
        lastSeen = now
    }

    public var isDue: Bool { active >= Self.after }

    public mutating func nudged(now: Date = Date()) { self = BreakReminder(now: now) }
}

/// Olo's voice: POST /api/voice/speak returns one piece of the answer read aloud by ElevenLabs as MP3, or
/// fails (no key on the server, signed out, offline), when the Mac reads it with its own voice. The
/// neighbouring pieces go with it so the voice keeps its pace and tone across the joins (SpeechPieces).
extension OloAPI {
    public struct SpeakInput: Encodable, Sendable {
        public let text: String
        public let previousText: String?
        public let nextText: String?
        public init(text: String, previousText: String? = nil, nextText: String? = nil) {
            self.text = text; self.previousText = previousText; self.nextText = nextText
        }
    }

    public func speak(_ text: String, previous: String? = nil, next: String? = nil) async -> Data? {
        var req = URLRequest(url: base.appendingPathComponent("api/voice/speak"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        TRPC.authorise(&req, token)
        // After authorise, which sets the usual 30 seconds: a long piece takes ElevenLabs a few seconds per sentence.
        req.timeoutInterval = 60
        req.httpBody = try? JSONEncoder().encode(SpeakInput(text: text, previousText: previous, nextText: next))
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty,
              (http.value(forHTTPHeaderField: "content-type") ?? "").lowercased().contains("audio") else { return nil }
        return data
    }
}
