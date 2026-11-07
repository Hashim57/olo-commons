import SwiftUI
import OloKit

/// Skills (skills.*): named playbooks Olo applies when a request calls for them. The
/// server screens each one; the panel shows whether it is active, waiting for review,
/// quarantined or rejected, and lets the person create, delete or report one.
struct SkillsView: View {
    @Environment(AppModel.self) private var model
    @State private var skills: [Skill] = []
    @State private var loading = false
    @State private var error: String?
    @State private var note: String?
    @State private var creating = false
    @State private var reporting: Skill?
    @State private var reason = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let error { Text(error).foregroundStyle(.secondary) }
                if skills.isEmpty && error == nil && !loading {
                    Text("No skills yet. A skill is a short set of instructions Olo follows when a request matches it: how you want board papers written, say.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(skills) { skillCard($0) }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
        .sheet(isPresented: $creating) { NewSkillSheet { input in await create(input) } }
        .sheet(item: $reporting) { s in reportSheet(s) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Skills").font(.largeTitle.weight(.semibold))
            Text("Instructions Olo follows for a kind of request. Each skill is screened when it is saved: it cannot ask Olo to hide sources, skip checking or act outside Olo. There is no on and off switch; a skill is active, waiting for review, quarantined or rejected, and that is shown on each one.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("New Skill...") { creating = true }
                Button("Refresh") { Task { await load() } }.disabled(loading)
                if loading { ProgressView().controlSize(.small) }
                if let n = note { Text(n).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func skillCard(_ s: Skill) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(s.name).font(.headline)
                Text(s.statusLabel).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background((s.isActive ? Color.green : Color.orange).opacity(0.18), in: Capsule())
                if s.visibility == "shared" { Text("Shared").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if s.uses > 0 { Text("used \(s.uses)\u{00D7}").font(.caption).foregroundStyle(.secondary) }
            }
            Text(s.description).font(.callout).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Instructions") {
                Text(s.instructions).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            .font(.caption)
            if !s.triggers.isEmpty { Text("Triggers: \(s.triggers.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(s.flags.enumerated()), id: \.offset) { _, f in
                Label("\(f.rule): \"\(f.excerpt)\"", systemImage: f.severity == "block" ? "xmark.octagon" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(f.severity == "block" ? Color.red : Color.orange)
            }
            HStack {
                Button("Report...") { reporting = s; reason = "" }.controlSize(.small)
                Button("Delete", role: .destructive) { Task { await delete(s) } }.controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func reportSheet(_ s: Skill) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report \"\(s.name)\"").font(.title3.weight(.semibold))
            Text("Tell the research team what is wrong with this skill. The report carries the skill and your reason, nothing else.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Reason", text: $reason, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { reporting = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Send Report") {
                    let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                    reporting = nil
                    Task {
                        let sent = (try? await model.api.reportSkill(id: s.id, reason: r)) ?? false
                        note = sent ? "Reported. Thank you." : "The report could not be sent."
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func load() async {
        guard model.canReachCloud, model.api.token != nil else { error = "Sign in and connect to see your skills."; return }
        loading = true
        defer { loading = false }
        do { skills = try await model.api.listSkills(); error = nil }
        catch let e as TRPC.RemoteError where e.isNotFound { error = "This server has no skills yet." }
        catch { self.error = error.localizedDescription }
    }

    private func create(_ input: OloAPI.SkillCreateInput) async -> String? {
        do {
            let created = try await model.api.createSkill(input)
            note = created.message
            await load()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func delete(_ s: Skill) async {
        do { try await model.api.deleteSkill(id: s.id); skills.removeAll { $0.id == s.id } }
        catch { note = "Could not delete: \(error.localizedDescription)" }
    }
}

/// A new skill: name, what it is for, the instructions, trigger words, private or shared.
struct NewSkillSheet: View {
    /// Saves; returns a problem to show, or nil when done.
    let save: (OloAPI.SkillCreateInput) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    @State private var triggers = ""
    @State private var shared = false
    @State private var busy = false
    @State private var error: String?

    private var ready: Bool {
        Skill.nameRange.contains(name.trimmingCharacters(in: .whitespaces).count)
            && Skill.descriptionRange.contains(description.trimmingCharacters(in: .whitespaces).count)
            && Skill.instructionsRange.contains(instructions.trimmingCharacters(in: .whitespacesAndNewlines).count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New skill").font(.title2.weight(.semibold))
            TextField("Name (2 to 60 characters)", text: $name)
            TextField("What it is for (4 to 240 characters)", text: $description)
            Text("Instructions (10 to 4000 characters)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $instructions).font(.body).frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            TextField("Trigger words, comma separated (optional)", text: $triggers)
            Toggle("Share with others once reviewed", isOn: $shared)
            if let error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Save") { Task { await submit() } }.keyboardShortcut(.defaultAction).disabled(!ready || busy)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 520)
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        let words = triggers.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(12)
        let input = OloAPI.SkillCreateInput(name: name.trimmingCharacters(in: .whitespaces), description: description.trimmingCharacters(in: .whitespaces),
                                            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
                                            triggers: words.isEmpty ? nil : Array(words), visibility: shared ? "shared" : "private")
        if let problem = await save(input) { error = problem } else { dismiss() }
    }
}
