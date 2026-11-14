import OloKit
import SwiftUI

/// Your day, as Olo reads it from the calendar on this iPhone: what is next, where the gaps are,
/// what it has noticed about your routine, and the reminders due today.
struct TodayView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var calendar: CalendarBridge
    @EnvironmentObject var companion: Companion
    @Binding var tab: AppTab
    @State private var newReminder = ""
    @State private var showShare = false
    @State private var briefOn: Bool = UserDefaults.standard.bool(forKey: "olo.brief")

    private var cal: Calendar { Calendar.current }
    private var next: PlanEvent? { DayPlan.next(calendar.upcoming, after: Date()) }
    private var free: [FreeBlock] { DayPlan.freeBlocks(calendar.upcoming, on: Date(), now: Date(), calendar: cal) }

    private func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        OloFace(mood: model.mood, size: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.headline)
                            Text(calendar.eventsAllowed ? DayPlan.brief(for: Date(), events: calendar.upcoming, calendar: cal) : "Let me see your calendar and I will keep an eye on your day.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    if !calendar.eventsAllowed {
                        Button("Let Olo read my calendar") { Task { await calendar.requestEvents() } }
                    }
                }

                if calendar.eventsAllowed {
                    if let next {
                        Section("Next") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(next.title).font(.title3.weight(.semibold))
                                Text(next.start > Date() ? "Starts \(time(next.start))" : "On now until \(time(next.end))").foregroundStyle(.secondary)
                                if let place = next.location, !place.isEmpty { Text(place).font(.footnote).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    Section("Today") {
                        if calendar.today.isEmpty { Text("Nothing in your calendar today.").foregroundStyle(.secondary) }
                        ForEach(Array(calendar.today.enumerated()), id: \.offset) { _, e in
                            HStack(alignment: .firstTextBaseline) {
                                Text(e.allDay ? "All day" : time(e.start)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                                Text(e.title)
                            }
                        }
                    }
                    if !free.isEmpty {
                        Section("Free time") {
                            ForEach(Array(free.enumerated()), id: \.offset) { _, b in
                                Text("\(time(b.start)) to \(time(b.end))  ·  \(b.minutes >= 60 ? "\(b.minutes / 60) h \(b.minutes % 60) min" : "\(b.minutes) min")")
                            }
                        }
                    }
                    if !calendar.habits.isEmpty {
                        Section {
                            ForEach(calendar.habits, id: \.self) { Text($0).font(.subheadline) }
                        } header: { Text("What Olo has noticed") } footer: { Text("Worked out on this iPhone from the last four weeks. It is not sent anywhere.") }
                    }
                    Section {
                        Button("Plan my day with Olo") { showShare = true }
                    } footer: { Text("You will see exactly what is shared before anything is sent.") }
                }

                Section("Reminders") {
                    if !calendar.remindersAllowed {
                        Button("Let Olo show my reminders") { Task { await calendar.requestReminders() } }
                    } else {
                        ForEach(calendar.reminders) { r in
                            Button { Task { await calendar.complete(r) } } label: {
                                HStack { Image(systemName: "circle"); Text(r.title).foregroundStyle(.primary); Spacer(); if let due = r.due { Text(time(due)).font(.footnote).foregroundStyle(.secondary) } }
                            }
                        }
                        HStack {
                            TextField("Add a reminder for today", text: $newReminder)
                            Button("Add") {
                                let title = newReminder.trimmingCharacters(in: .whitespacesAndNewlines); newReminder = ""
                                Task { _ = await calendar.addReminder(title, due: cal.date(bySettingHour: 18, minute: 0, second: 0, of: Date())) }
                            }
                            .disabled(newReminder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }

                Section {
                    Toggle("Keep Olo with me", isOn: Binding(get: { companion.active }, set: { on in
                        if on { companion.start(line: next == nil ? "Nothing else in your calendar today." : "Next in your day", next: next) } else { companion.stop() }
                    }))
                    Toggle("Morning brief", isOn: $briefOn)
                } header: { Text("Outside the app") } footer: {
                    Text("Keep Olo with me puts Olo in the Dynamic Island and on the Lock Screen with what is next. The morning brief is a notification written on this iPhone from your calendar.")
                }
            }
            .navigationTitle("Today")
            .refreshable { await calendar.reload() }
            .onChange(of: briefOn) { _, on in
                UserDefaults.standard.set(on, forKey: "olo.brief")
                Task { if on { await companion.scheduleBriefs(upcoming: calendar.upcoming, past: calendar.past) } else { companion.cancelBriefs() } }
            }
            .task { if briefOn { await companion.scheduleBriefs(upcoming: calendar.upcoming, past: calendar.past) } }
            .sheet(isPresented: $showShare) { ShareDaySheet(tab: $tab) }
        }
    }
}

/// Shows exactly what will be sent before a question about the day goes to Olo.
struct ShareDaySheet: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var calendar: CalendarBridge
    @Environment(\.dismiss) private var dismiss
    @Binding var tab: AppTab
    @State private var question = "Help me plan today. What should I do first, and where can I fit focused work?"

    private var shared: String { DayPlan.shareText(day: Date(), events: calendar.upcoming, calendar: Calendar.current) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Your question") { TextField("Question", text: $question, axis: .vertical).lineLimit(2...5) }
                Section {
                    Text(shared).font(.footnote.monospaced())
                } header: { Text("What Olo will be sent") } footer: {
                    Text("Only these times and titles, with your question. Turn on Private in the chat first if you do not want the conversation kept.")
                }
                Section {
                    Button("Send to Olo") {
                        dismiss(); tab = .olo
                        model.ask(question + "\n\n" + shared)
                    }
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Plan my day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
