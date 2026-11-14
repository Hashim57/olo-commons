import Foundation

/// The Olo Terms of Use as the app presents them: the version in force, a plain
/// English summary shown before the first conversation, and the links. The full
/// text lives at helius-olo.io; the summary is a courtesy, not a substitute.
public enum Legal {
    /// Raise this when the terms change: everyone sees the "Before you start" sheet again.
    public static let termsVersion = "2026-10-25"

    public static let termsURL = URL(string: "https://helius-olo.io/terms")!
    public static let privacyURL = URL(string: "https://helius-olo.io/privacy")!
    /// Apple's standard EULA, which the App Store listing uses unless a custom one is filed.
    public static let eulaURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    public static let provider = "Helius Network Ltd, a company registered in England and Wales"

    /// One point of the summary: a short heading and a sentence or two.
    public struct Point: Equatable, Sendable {
        public let title: String
        public let text: String
        public init(title: String, text: String) { self.title = title; self.text = text }
    }

    /// The summary, in the order it is shown. Every point is a plain reading of the full terms.
    public static let summary: [Point] = [
        Point(title: "Who provides Olo",
              text: "Olo is made and run by \(provider). The terms are a contract between you and Helius Network Ltd."),
        Point(title: "Olo can be wrong",
              text: "Answers are written by AI models and checked sentence by sentence by Zeus. Checking reduces mistakes; it does not remove them. Check anything that matters before you act on it."),
        Point(title: "Your account",
              text: "You sign in with a code sent to your email. Keep that inbox safe: whoever reads it can use your account."),
        Point(title: "Subscriptions",
              text: "A subscription renews automatically unless you cancel it at least 24 hours before the end of the current period. You manage or cancel it in your App Store settings, not in Olo."),
        Point(title: "Your content stays yours",
              text: "What you write, attach or upload remains yours. Olo uses it only to answer you, and stores it so your conversations follow you across devices."),
        Point(title: "Improving Olo and training Zeus",
              text: "Your conversations are used to improve Olo and to train Zeus only while the consent switch is on. Flags you send from a verdict are always used, because sending one is your choice."),
    ]

    /// The sentence Apple asks every app selling auto-renewable subscriptions to show.
    public static let renewalSentence = "Payment is charged to your Apple ID at confirmation of purchase. The subscription renews automatically unless cancelled at least 24 hours before the end of the current period. Manage or cancel it in App Store settings."
}

/// A record that this person agreed to a version of the terms, kept on this Mac.
public struct LegalAcceptance: Codable, Equatable, Sendable {
    public var version: String
    public var acceptedAt: Date

    public init(version: String, acceptedAt: Date) {
        self.version = version
        self.acceptedAt = acceptedAt
    }
}

/// Where the acceptance lives: one small JSON value in UserDefaults.
public final class LegalStore: @unchecked Sendable {
    public static let key = "legal.acceptance.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The most recent acceptance, whatever its version.
    public var acceptance: LegalAcceptance? {
        guard let data = defaults.data(forKey: LegalStore.key) else { return nil }
        return try? LegalStore.decoder.decode(LegalAcceptance.self, from: data)
    }

    /// True when this exact version has been agreed to.
    public func accepted(for version: String = Legal.termsVersion) -> Bool {
        acceptance?.version == version
    }

    /// True when an older version was agreed to: the sheet says "The terms have changed".
    public func acceptedOlderVersion(than version: String = Legal.termsVersion) -> Bool {
        guard let a = acceptance else { return false }
        return a.version != version
    }

    /// Records agreement to a version, now by default.
    @discardableResult
    public func record(version: String = Legal.termsVersion, at date: Date = Date()) -> LegalAcceptance {
        let a = LegalAcceptance(version: version, acceptedAt: date)
        if let data = try? LegalStore.encoder.encode(a) { defaults.set(data, forKey: LegalStore.key) }
        return a
    }

    public func reset() {
        defaults.removeObject(forKey: LegalStore.key)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
