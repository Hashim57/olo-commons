import ActivityKit
import Foundation
import OloKit
import UserNotifications
import WidgetKit

/// Olo outside the app. iOS does not let any app draw over other apps, so this is what Apple
/// provides instead: a Live Activity (the Dynamic Island and the Lock Screen), the Home Screen
/// widget, and a morning brief as a notification. All of it is made on the phone.
@MainActor
final class Companion: ObservableObject {
    @Published var active = false
    private var activity: Activity<OloActivityAttributes>?

    var allowed: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    init() {
        activity = Activity<OloActivityAttributes>.activities.first
        active = activity != nil
    }

    /// Starts keeping the person company, or updates what is shown if already started.
    func show(mood: OloMood, line: String, next: PlanEvent?) {
        let state = OloActivityAttributes.ContentState(mood: mood, line: line, nextTitle: next?.title, nextStart: next?.start)
        SharedStore.write(OloSnapshot(line: line, nextTitle: next?.title, nextStart: next?.start, updated: Date()))
        WidgetCenter.shared.reloadAllTimelines()
        guard allowed else { return }
        let content = ActivityContent(state: state, staleDate: next?.end)
        if let activity {
            Task { await activity.update(content) }
        } else if active {
            do { activity = try Activity<OloActivityAttributes>.request(attributes: OloActivityAttributes(name: "Olo"), content: content, pushType: nil) } catch { active = false }
        }
    }

    func start(line: String, next: PlanEvent?) {
        active = true
        show(mood: .idle, line: line, next: next)
        if activity == nil { active = false }
    }

    func stop() {
        let current = activity
        activity = nil; active = false
        Task { await current?.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: The morning brief

    /// Asks once for notifications, then schedules the next three mornings' briefs from the calendar as it stands.
    func scheduleBriefs(upcoming: [PlanEvent], past: [PlanEvent]) async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        let ids = (0..<3).map { "olo.brief.\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        guard granted else { return }
        let cal = Calendar.current
        let hour = DayPlan.briefHour(past, calendar: cal)
        for offset in 1...3 {
            guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date())) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Good morning from Olo"
            content.body = DayPlan.brief(for: day, events: upcoming, calendar: cal)
            content.sound = .default
            var when = cal.dateComponents([.year, .month, .day], from: day)
            when.hour = hour; when.minute = 0
            let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: ids[offset - 1], content: content, trigger: trigger))
        }
    }

    func cancelBriefs() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: (0..<3).map { "olo.brief.\($0)" })
    }
}
