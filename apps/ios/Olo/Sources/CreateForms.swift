import OloKit
import SwiftUI

/// A new scheduled task, with the same choices as the Mac and the web: what to ask, how often,
/// at what time in this phone's time zone, and whether to email the answer.
struct NewScheduleSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let done: () -> Void
    @State private var prompt = ""
    @State private var cadence = "daily"
    @State private var weekday = 1
    @State private var time = Calendar.current.date(from: DateComponents(hour: 8, minute: 0)) ?? Date()
    @State private var emailMe = false
    @State private var saving = false
    @State private var problem: String?

    static let examples = ["What changed in UK housing policy this week?", "Summarise today's top technology news with sources.", "What is in my calendar today?"]
    static let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What should Olo ask?", text: $prompt, axis: .vertical).lineLimit(3...6)
                    ForEach(NewScheduleSheet.examples, id: \.self) { example in
                        Button(example) { prompt = example }.font(.footnote)
                    }
                } header: { Text("Question") }
                Section {
                    Picker("How often", selection: $cadence) {
                        Text("Every day").tag("daily")
                        Text("Weekdays").tag("weekdays")
                        Text("Once a week").tag("weekly")
                    }
                    if cadence == "weekly" {
                        Picker("Day", selection: $weekday) {
                            ForEach(0..<7, id: \.self) { i in Text(NewScheduleSheet.days[i]).tag(i) }
                        }
                    }
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    Toggle("Email me the answer", isOn: $emailMe)
                } footer: {
                    Text("Times are in \(TimeZone.current.identifier). Each run counts as one message.")
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }
            .navigationTitle("New scheduled task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Scheduling" : "Schedule") { Task { await create() } }
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 || saving)
                }
            }
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
            done()
            dismiss()
        } catch let e as TRPC.RemoteError where e.isNotFound {
            problem = "This server does not offer scheduled tasks yet."
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// A new skill: name, what it is for, the instructions, trigger words, private or shared. The
/// server screens every skill when it is saved and says what it decided.
struct NewSkillSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Called with the server's message once the skill is saved.
    let done: (String) -> Void
    @State private var name = ""
    @State private var purpose = ""
    @State private var instructions = ""
    @State private var triggers = ""
    @State private var shared = false
    @State private var busy = false
    @State private var problem: String?

    private var ready: Bool {
        Skill.nameRange.contains(name.trimmingCharacters(in: .whitespaces).count)
            && Skill.descriptionRange.contains(purpose.trimmingCharacters(in: .whitespaces).count)
            && Skill.instructionsRange.contains(instructions.trimmingCharacters(in: .whitespacesAndNewlines).count)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (2 to 60 characters)", text: $name)
                    TextField("What it is for (4 to 240 characters)", text: $purpose, axis: .vertical).lineLimit(1...4)
                }
                Section {
                    TextField("How Olo should handle this kind of request", text: $instructions, axis: .vertical).lineLimit(5...14)
                } header: { Text("Instructions (10 to 4000 characters)") }
                Section {
                    TextField("Trigger words, comma separated (optional)", text: $triggers)
                        .textInputAutocapitalization(.never)
                    Toggle("Share with others once reviewed", isOn: $shared)
                } footer: {
                    Text("A skill cannot ask Olo to hide sources, skip checking or act outside Olo.")
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }
            .navigationTitle("New skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await submit() } }.disabled(!ready || busy)
                }
            }
        }
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        let words = triggers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(12)
        let input = OloAPI.SkillCreateInput(name: name.trimmingCharacters(in: .whitespaces), description: purpose.trimmingCharacters(in: .whitespaces),
                                            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
                                            triggers: words.isEmpty ? nil : Array(words), visibility: shared ? "shared" : "private")
        do {
            let created = try await model.api.createSkill(input)
            done(created.message)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
