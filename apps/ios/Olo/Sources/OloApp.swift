import SwiftUI

@main
struct OloApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var calendar = CalendarBridge()
    @StateObject private var voice = Voice()
    @StateObject private var companion = Companion()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(calendar)
                .environmentObject(voice)
                .environmentObject(companion)
        }
    }
}
