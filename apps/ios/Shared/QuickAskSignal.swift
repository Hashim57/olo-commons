import AppIntents
import Foundation

/// "Open Quick Ask", from the Ask Olo control, the Action Button, Shortcuts or Spotlight.
///
/// The intent is in both the app and the widget extension (which offers the control). Because it
/// opens the app when run, it leaves a note in the shared app group with the time, and the app
/// opens Quick Ask, listening, when it comes to the front and finds a fresh note.
struct OpenQuickAskIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Quick Ask"
    static var description = IntentDescription("Opens Olo's Quick Ask with the microphone listening.")
    static var openAppWhenRun: Bool = true

    init() {}

    func perform() async throws -> some IntentResult {
        QuickAskSignal.raise()
        return .result()
    }
}

enum QuickAskSignal {
    private static let key = "olo.quickAskRequestedAt"
    /// A note older than this is stale: the app was not opened for it.
    private static let fresh: TimeInterval = 20

    static func raise() {
        SharedStore.defaults.set(Date().timeIntervalSince1970, forKey: key)
    }

    /// True once for each fresh request.
    static func take() -> Bool {
        let at = SharedStore.defaults.double(forKey: key)
        guard at > 0 else { return false }
        SharedStore.defaults.removeObject(forKey: key)
        return Date().timeIntervalSince1970 - at < fresh
    }
}
