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
                Section {
                    NavigationLink { MemoryShelf() } label: { Label("Memory", systemImage: "brain") }
                    NavigationLink { ScheduleShelf() } label: { Label("Scheduled", systemImage: "clock.arrow.circlepath") }
                    NavigationLink { WatchShelf() } label: { Label("Watching", systemImage: "eye") }
                    NavigationLink { ArtifactShelf() } label: { Label("Artifacts", systemImage: "doc.richtext") }
                    NavigationLink { SkillShelf() } label: { Label("Skills", systemImage: "wand.and.stars") }
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
        .task { await reload() }
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
    var body: some View {
        Shelf(title: "Scheduled", emptyText: "No scheduled tasks. Create them on the Mac or the web and they will appear here.", load: { try await model.api.listSchedules() }) { t, reload in
            VStack(alignment: .leading, spacing: 6) {
                Text(t.title).font(.headline)
                Text(t.scheduleLine).font(.subheadline).foregroundStyle(.secondary)
                if let last = t.lastLine { Text(last).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Run now") { Task { try? await model.api.runScheduleNow(id: t.id); await reload() } }.font(.caption.weight(.semibold)).buttonStyle(.borderless)
                    Spacer()
                    Button("Delete", role: .destructive) { Task { try? await model.api.deleteSchedule(id: t.id); await reload() } }.font(.caption).buttonStyle(.borderless)
                }
            }
        }
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
        Shelf(title: "Artifacts", emptyText: "Nothing built yet. Ask Olo to build a page, a document or a chart.", load: { try await model.api.listArtifacts() }) { a, _ in
            NavigationLink {
                ScrollView { Text(a.code).font(.footnote.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
                    .navigationTitle(a.title).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { ShareLink(item: a.code) } }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(a.title)
                    Text(a.filename).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SkillShelf: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Shelf(title: "Skills", emptyText: "No skills yet. Create them on the Mac or the web.", load: { try await model.api.listSkills() }) { s, _ in
            VStack(alignment: .leading, spacing: 4) {
                Text(s.name).font(.headline)
                Text(s.description).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
