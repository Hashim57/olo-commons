import AppIntents
import EventKit
import Foundation
import OloKit

/// A question handed over by Siri or Shortcuts, picked up by the chat when the app opens.
@MainActor
final class PendingAsk: ObservableObject {
    static let shared = PendingAsk()
    @Published var question: String?
}

struct AskOloIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Olo"
    static var description = IntentDescription("Ask Olo a question. The answer is checked against its sources.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Question")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingAsk.shared.question = question
        return .result()
    }
}

struct MyDayIntent: AppIntent {
    static var title: LocalizedStringResource = "What is my day like"
    static var description = IntentDescription("Olo reads today's calendar on this device and sums it up.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return .result(dialog: "Open Olo and allow the calendar first, then ask me again.")
        }
        let store = EKEventStore()
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? Date()
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil)).map { e in
            PlanEvent(title: e.title ?? "Busy", start: e.startDate, end: e.endDate, allDay: e.isAllDay)
        }
        return .result(dialog: IntentDialog(stringLiteral: DayPlan.brief(for: Date(), events: events, calendar: cal)))
    }
}

struct OloShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskOloIntent(), phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question"], shortTitle: "Ask Olo", systemImageName: "bubble.left")
        AppShortcut(intent: MyDayIntent(), phrases: ["What is my day like in \(.applicationName)", "\(.applicationName) my day"], shortTitle: "My day", systemImageName: "calendar")
    }
}
