import SwiftUI

@main
struct OloApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var calendar = CalendarBridge()
    @StateObject private var voice = Voice()
    @StateObject private var companion = Companion()
    @StateObject private var hands = HandsFree()
    @UIApplicationDelegateAdaptor(OloAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(calendar)
                .environmentObject(voice)
                .environmentObject(companion)
                .environmentObject(hands)
        }
    }
}
