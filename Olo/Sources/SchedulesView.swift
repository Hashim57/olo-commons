import SwiftUI
import OloKit

/// Scheduled (schedules.*): questions Olo asks on a schedule, in this Mac's time zone,
/// answered and checked like a typed one, kept in one conversation per task, and
/// announced by a nudge, a push and (if chosen) an email. Same procedures as the web.
struct SchedulesView: View {
    @Environment(AppModel.self) private var model
    @State private var tasks: [ScheduledTask] = []
    @State private var loading = false
    @State private var saving = false
    @State private var note: String?
    @State private var problem: String?

    @State private var prompt = ""
    @State private var cadence = "weekdays"
    @State private var weekday = 1
    @State private var time = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var emailMe = false
    /// After Run now, look again every few seconds until the run lands.
    @State private var waitingId: Int?

    private static let examples = [
        "Summarise overnight news about Caribbean fintech, with sources.",
        "Every Friday, list new open-source releases in AI safety tooling.",
        "Check whether the UK changed any rules for contractors this week.",
    ]
    private static let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let problem { Text(problem).foregroundStyle(.secondary) }
                newTask
                if tasks.isEmpty && problem == nil && !loading {
                    Text("Nothing scheduled yet.").foregroundStyle(.secondary)
                }
                ForEach(tasks) { task in row(task) }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
        .task(id: waitingId) { await followRun() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scheduled").font(.largeTitle.weight(.semibold))
            Text("Questions Olo asks for you on a schedule. Each answer is checked by Zeus like any other, kept in its own conversation, and sent to your devices. Email is optional.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Refresh") { Task { await load() } }.disabled(loading)
                if loading { ProgressView().controlSize(.small) }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var newTask: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NEW SCHEDULED TASK").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 70, maxHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel("What should Olo ask?")
            HStack(spacing: 8) {
                ForEach(Self.examples, id: \.self) { example in
                    Button(example) { prompt = example }
                        .buttonStyle(.bordered).controlSize(.small).lineLimit(1)
                }
            }
            HStack(spacing: 14) {
                Picker("How often", selection: $cadence) {
                    Text("Every day").tag("daily")
                    Text("Weekdays").tag("weekdays")
                    Text("Once a week").tag("weekly")
                }
                .labelsHidden().frame(width: 140)
                if cadence == "weekly" {
                    Picker("Day", selection: $weekday) {
                        ForEach(0..<7, id: \.self) { i in Text(Self.days[i]).tag(i) }
                    }
                    .labelsHidden().frame(width: 130)
                }
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute).labelsHidden()
                Toggle("Email me the answer", isOn: $emailMe)
            }
            HStack(spacing: 12) {
                Button(saving ? "Scheduling..." : "Schedule") { Task { await create() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 || saving)
                Text("Times are in \(TimeZone.current.identifier). Each run counts as one message.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    private func row(_ task: ScheduledTask) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "calendar.badge.clock").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Button(task.title) {
                    if let id = task.conversationId { model.openServerConversation(id) }
                }
                .buttonStyle(.plain)
                .disabled(task.conversationId == nil)
                Text(meta(task)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                if let last = task.lastLine {
                    Text(last).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button { Task { await runNow(task) } } label: {
                Image(systemName: waitingId == task.id ? "bolt.fill" : "bolt")
            }
            .buttonStyle(.borderless).help("Run now")
            Button { Task { await update(task, email: !task.email) } } label: {
                Image(systemName: task.email ? "envelope.fill" : "envelope")
            }
            .buttonStyle(.borderless).help(task.email ? "Stop emailing" : "Email me the answer")
            Button { Task { await update(task, enabled: !task.enabled) } } label: {
                Image(systemName: task.enabled ? "pause" : "play")
            }
            .buttonStyle(.borderless).help(task.enabled ? "Pause" : "Resume")
            Button { Task { await remove(task) } } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        .opacity(task.enabled ? 1 : 0.55)
    }

    private func meta(_ task: ScheduledTask) -> String {
        var parts = [task.scheduleLine.uppercased()]
        if task.email { parts.append("EMAIL") }
        if !task.enabled {
            parts.append("PAUSED")
        } else if let next = Self.parse(task.nextRunAt) {
            parts.append("NEXT " + next.formatted(.dateTime.weekday(.abbreviated).hour().minute()).uppercased())
        }
        return parts.joined(separator: " · ")
    }

    private static func parse(_ iso: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    // MARK: Calls

    private func load() async {
        guard model.canReachCloud, model.api.token != nil else { problem = "Sign in and connect to schedule questions."; return }
        loading = true
        defer { loading = false }
        do {
            tasks = try await model.api.listSchedules()
            problem = nil
        } catch let e as TRPC.RemoteError where e.isNotFound {
            problem = "This server does not offer scheduled tasks yet."
        } catch {
            problem = error.localizedDescription
        }
    }

    private func create() async {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let input = ScheduleInput(prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), cadence: cadence,
                                  hour: parts.hour ?? 8, minute: parts.minute ?? 0, weekday: weekday, email: emailMe)
        saving = true
        defer { saving = false }
        do {
            _ = try await model.api.createSchedule(input)
            prompt = ""
            note = "Scheduled. Olo will ask it at the time you chose."
            await load()
        } catch {
            note = "Could not schedule: \(error.localizedDescription)"
        }
    }

    private func update(_ task: ScheduledTask, enabled: Bool? = nil, email: Bool? = nil) async {
        do {
            _ = try await model.api.updateSchedule(.init(id: task.id, enabled: enabled, email: email))
            await load()
        } catch {
            note = "Could not update: \(error.localizedDescription)"
        }
    }

    private func remove(_ task: ScheduledTask) async {
        do {
            try await model.api.deleteSchedule(id: task.id)
            await load()
        } catch {
            note = "Could not delete: \(error.localizedDescription)"
        }
    }

    private func runNow(_ task: ScheduledTask) async {
        do {
            try await model.api.runScheduleNow(id: task.id)
            note = "Running now. The answer appears in its conversation in a minute or two."
            waitingId = task.id
        } catch {
            note = "Could not start: \(error.localizedDescription)"
        }
    }

    /// Polls every 3 seconds for up to three minutes, until the task's last run changes.
    private func followRun() async {
        guard let id = waitingId else { return }
        let before = tasks.first { $0.id == id }?.lastRunAt
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            await load()
            if let now = tasks.first(where: { $0.id == id })?.lastRunAt, now != before {
                waitingId = nil
                return
            }
        }
        waitingId = nil
    }
}

/// "Send a suggestion": emailed to the Olo team (feedback.suggest), with the account email
/// as reply-to when signed in. Settings > Feedback.
struct SuggestionSettings: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var sending = false
    @State private var note: String?

    var body: some View {
        Form {
            Section("Send a suggestion") {
                Text("An idea, something that got in your way, or a feature you want. It goes straight to the team.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .frame(minHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .accessibilityLabel("Your suggestion")
                HStack {
                    Button(sending ? "Sending..." : "Send Suggestion") { Task { await send() } }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 || sending || !model.canReachCloud)
                    if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            try await model.api.sendSuggestion(String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000)))
            text = ""
            note = "Thank you. Your suggestion is on its way to the team."
        } catch {
            note = "Not sent: \(error.localizedDescription)"
        }
    }
}
