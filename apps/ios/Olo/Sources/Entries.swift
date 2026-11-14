import AppIntents
import OloKit
import SwiftUI
import UIKit

/// Ways into Olo's voice that are not the icon, funnelled into one place so a request from a
/// home-screen action, a shortcut or a link behaves the same: RootView watches `entry`.
@MainActor
final class PendingEntry: ObservableObject {
    static let shared = PendingEntry()
    @Published var entry: VoiceEntry?

    static let quickAskAction = "com.helius.olo.quickask"
    static let talkAction = "com.helius.olo.talk"

    /// A home-screen quick action (press and hold the icon).
    func take(action type: String) {
        switch type {
        case PendingEntry.quickAskAction: entry = .quickAsk
        case PendingEntry.talkAction: entry = .talk
        default: break
        }
    }
}

/// "Talk to Olo", from Shortcuts, Spotlight or the Action Button: opens the app in a conversation by voice.
struct TalkToOloIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to Olo"
    static var description = IntentDescription("Starts a conversation with Olo by voice. Say stop to finish.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingEntry.shared.entry = .talk
        return .result()
    }
}

/// The home-screen quick actions arrive through the scene, which SwiftUI's App does not expose,
/// so a small scene delegate hands them to PendingEntry.
final class OloAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem { PendingEntry.shared.take(action: item.type) }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = OloSceneDelegate.self
        return configuration
    }
}

final class OloSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        PendingEntry.shared.take(action: shortcutItem.type)
        completionHandler(true)
    }
}
