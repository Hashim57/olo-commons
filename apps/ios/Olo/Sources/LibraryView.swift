import OloKit
import SwiftUI

/// The Library, with the same shelves as the Mac app's sidebar: what Olo remembers, what it does
/// on a schedule, what it is watching, what it has made, and its skills.
struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationStack {
            List {
                if !model.signedIn {
                    Section {
                        Text("Sign in to keep a library. The same account works on the web, the Mac and the iPhone.").font(.subheadline).foregroundStyle(.secondary)
                        Button("Sign in") { model.showSignIn = true }
                    }
                }
                Section("Make") {
                    NavigationLink { BuildHomeView() } label: { Label("Build with Olo", systemImage: "hammer") }
                    NavigationLink { ArtifactShelf() } label: { Label("Artifacts", systemImage: "doc.richtext") }
                    NavigationLink { ProjectsView() } label: { Label("Projects and files", systemImage: "folder") }
                }
                Section("Olo for you") {
                    NavigationLink { MemoryShelf() } label: { Label("Memory", systemImage: "brain") }
                    NavigationLink { ScheduleShelf() } label: { Label("Scheduled", systemImage: "clock.arrow.circlepath") }
                    NavigationLink { WatchShelf() } label: { Label("Watching", systemImage: "eye") }
                    NavigationLink { SkillShelf() } label: { Label("Skills", systemImage: "wand.and.stars") }
                }
                Section("Checked and connected") {
                    NavigationLink { ZeusGraphView() } label: { Label("What Zeus knows", systemImage: "point.3.connected.trianglepath.dotted") }
                    NavigationLink { ConnectorsView() } label: { Label("Mail and calendar", systemImage: "envelope.badge") }
                }
            }
            .navigationTitle("Library")
        }
    }
}

/// A shelf that loads a list from the account and says so plainly when it cannot.
struct Shelf<Item: Identifiable, Row: View>: View {
    let title: String
    let emptyText: String
    /// Change this to load the list again (after something was created).
    var refresh: Int = 0
    let load: () async throws -> [Item]
    @ViewBuilder let row: (Item, @escaping () async -> Void) -> Row
    @State private var items: [Item] = []
    @State private var state = "loading"

    private func reload() async {
        do { items = try await load(); state = items.isEmpty ? "empty" : "ready" } catch { state = "failed" }
    }

    var body: some View {
        List {
            if state == "loading" { ProgressView() }
            if state == "empty" { Text(emptyText).foregroundStyle(.secondary) }
            if state == "failed" { Text("This could not be loaded. Pull down to try again.").foregroundStyle(.secondary) }
            ForEach(items) { item in row(item, reload) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task(id: refresh) { await reload() }
    }
}

struct MemoryShelf: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Shelf(title: "Memory", emptyText: "Olo has not remembered anything yet. It asks before it keeps a memory.", load: { try await model.api.listMemories().memories }) { m, reload in
            VStack(alignment: .leading, spacing: 6) {
                Text(m.content)
                HStack {
                    Text(m.category.capitalized).font(.caption).foregroundStyle(.secondary)
                    if m.status != "approved" {
                        Button("Approve") { Task { try? await model.api.approveMemory(id: m.id); await reload() } }.font(.caption.weight(.semibold)).buttonStyle(.borderless)
                    }
                    Spacer()
                    Button("Forget", role: .destructive) { Task { try? await model.api.deleteMemory(id: m.id); await reload() } }.font(.caption).buttonStyle(.borderless)
                }
            }
        }
    }
}

struct ScheduleShelf: View {
    @EnvironmentObject var model: AppModel
    @State private var showNew = false
    @State private var refresh = 0
    var body: some View {
        Shelf(title: "Scheduled", emptyText: "No scheduled tasks yet. Press + to have Olo ask something for you every day or every week.", refresh: refresh, load: { try await model.api.listSchedules() }) { t, reload in
            VStack(alignment: .leading, spacing: 6) {
                Text(t.title).font(.headline)
                Text(t.scheduleLine + (t.enabled ? "" : " (paused)")).font(.subheadline).foregroundStyle(.secondary)
                if let last = t.lastLine { Text(last).font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 14) {
                    Button("Run now") { Task { try? await model.api.runScheduleNow(id: t.id); await reload() } }.font(.caption.weight(.semibold)).buttonStyle(.borderless)
                    Button(t.enabled ? "Pause" : "Resume") { Task { _ = try? await model.api.updateSchedule(OloAPI.ScheduleUpdate(id: t.id, enabled: !t.enabled)); await reload() } }.font(.caption).buttonStyle(.borderless)
                    Button(t.email ? "Stop emailing" : "Email me") { Task { _ = try? await model.api.updateSchedule(OloAPI.ScheduleUpdate(id: t.id, email: !t.email)); await reload() } }.font(.caption).buttonStyle(.borderless)
                    Spacer()
                    Button("Delete", role: .destructive) { Task { try? await model.api.deleteSchedule(id: t.id); await reload() } }.font(.caption).buttonStyle(.borderless)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { if model.signedIn { showNew = true } else { model.showSignIn = true } } label: { Image(systemName: "plus") }.accessibilityLabel("New scheduled task")
            }
        }
        .sheet(isPresented: $showNew) { NewScheduleSheet(done: { refresh += 1 }) }
    }
}

struct WatchShelf: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Shelf(title: "Watching", emptyText: "Nothing is being watched. Watch a claim from an answer and Olo re-checks it for you.", load: { try await model.api.listMonitors() }) { m, reload in
            VStack(alignment: .leading, spacing: 6) {
                Text(m.claim)
                Text("Was \(m.baselineVerdict). Checked every \(m.intervalDays) days.").font(.caption).foregroundStyle(.secondary)
                if let note = m.changeNote, !note.isEmpty { Text(note).font(.caption).foregroundStyle(.orange) }
                Button("Stop watching", role: .destructive) { Task { try? await model.api.unwatch(monitorId: m.id); await reload() } }.font(.caption).buttonStyle(.borderless)
            }
        }
    }
}

struct ArtifactShelf: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Shelf(title: "Artifacts", emptyText: "Nothing built yet. Ask Olo to build a page, a document or a chart, or open Build with Olo.", load: { try await model.api.listArtifacts() }) { a, reload in
            NavigationLink {
                ArtifactDetailView(artifact: a, deleted: { Task { await reload() } })
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(a.title)
                    Text(a.suggestedFilename).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SkillShelf: View {
    @EnvironmentObject var model: AppModel
    @State private var showNew = false
    @State private var refresh = 0
    @State private var note: String?
    var body: some View {
        Shelf(title: "Skills", emptyText: "No skills yet. A skill is a short set of instructions Olo follows when a request matches it. Press + to write one.", refresh: refresh, load: { try await model.api.listSkills() }) { s, reload in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(s.name).font(.headline)
                    Spacer()
                    Text(s.statusLabel).font(.caption).foregroundStyle(.secondary)
                }
                Text(s.description).font(.subheadline).foregroundStyle(.secondary)
                if !s.triggers.isEmpty { Text("Triggers: \(s.triggers.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
                Button("Delete", role: .destructive) { Task { try? await model.api.deleteSkill(id: s.id); await reload() } }.font(.caption).buttonStyle(.borderless)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let note { Text(note).font(.footnote).padding(10).frame(maxWidth: .infinity).background(.bar).onTapGesture { self.note = nil } }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { if model.signedIn { showNew = true } else { model.showSignIn = true } } label: { Image(systemName: "plus") }.accessibilityLabel("New skill")
            }
        }
        .sheet(isPresented: $showNew) { NewSkillSheet(done: { message in note = message; refresh += 1 }) }
    }
}
