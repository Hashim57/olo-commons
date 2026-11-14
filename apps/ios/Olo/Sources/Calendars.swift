import EventKit
import Foundation
import OloKit

/// A reminder as the Today screen shows it.
struct ReminderItem: Identifiable, Equatable {
    let id: String
    var title: String
    var due: Date?
}

/// The bridge to the iPhone's calendar and reminders. It reads on the device and hands back plain
/// values; nothing here sends anything anywhere.
@MainActor
final class CalendarBridge: ObservableObject {
    private let store = EKEventStore()
    @Published var eventsAllowed = false
    @Published var remindersAllowed = false
    @Published var today: [PlanEvent] = []
    @Published var upcoming: [PlanEvent] = []
    @Published var habits: [String] = []
    @Published var reminders: [ReminderItem] = []
    private(set) var past: [PlanEvent] = []

    init() { refreshStatus() }

    func refreshStatus() {
        eventsAllowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        remindersAllowed = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    func requestEvents() async {
        eventsAllowed = (try? await store.requestFullAccessToEvents()) ?? false
        await reload()
    }

    func requestReminders() async {
        remindersAllowed = (try? await store.requestFullAccessToReminders()) ?? false
        await reload()
    }

    private func events(from: Date, to: Date) -> [PlanEvent] {
        guard eventsAllowed else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).map { e in
            PlanEvent(title: e.title ?? "Busy", start: e.startDate, end: e.endDate, allDay: e.isAllDay, location: e.location)
        }
    }

    /// Reads today, the week ahead and the last four weeks, and works out the habits.
    func reload() async {
        refreshStatus()
        let cal = Calendar.current
        let now = Date()
        let start = cal.startOfDay(for: now)
        let weekAhead = cal.date(byAdding: .day, value: 7, to: start) ?? now
        let monthBack = cal.date(byAdding: .day, value: -28, to: start) ?? now
        let ahead = events(from: start, to: weekAhead)
        today = DayPlan.agenda(ahead, on: now, calendar: cal)
        upcoming = ahead
        past = events(from: monthBack, to: start)
        habits = DayPlan.habits(past, calendar: cal)
        reminders = await dueReminders(until: cal.date(byAdding: .day, value: 1, to: start) ?? now)
    }

    private func dueReminders(until end: Date) async -> [ReminderItem] {
        guard remindersAllowed else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                let items = (found ?? []).map { r in
                    ReminderItem(id: r.calendarItemIdentifier, title: r.title ?? "Reminder", due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) })
                }
                continuation.resume(returning: items.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) })
            }
        }
    }

    func addReminder(_ title: String, due: Date?) async -> Bool {
        if !remindersAllowed { await requestReminders() }
        guard remindersAllowed, let list = store.defaultCalendarForNewReminders() else { return false }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.calendar = list
        if let due { r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due) }
        do { try store.save(r, commit: true) } catch { return false }
        await reload()
        return true
    }

    func complete(_ item: ReminderItem) async {
        guard let r = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        r.isCompleted = true
        try? store.save(r, commit: true)
        await reload()
    }
}
