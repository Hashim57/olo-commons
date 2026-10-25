import SwiftUI
import OloKit

/// The sidebar: the library's panels, projects, folders and every conversation, with
/// search over titles here and over every message on helius-olo.io. The same sections
/// as the web sidebar and the iPhone drawer, so the three clients stay recognisable
/// as one product.
struct LibrarySidebar: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    @State private var newProject = false
    @State private var folderPrompt: UUID?
    @State private var newFolderName = ""

    private var query: String { filter.trimmingCharacters(in: .whitespaces) }

    private var filtered: [LocalConversation] {
        var list = model.conversations
        if let folder = model.folderFilter { list = list.filter { $0.folder == folder } }
        let f = query.lowercased()
        return f.isEmpty ? list : list.filter { $0.title.lowercased().contains(f) }
    }

    var body: some View {
        let selection = Binding<UUID?>(get: { model.panel == nil ? model.selection : nil },
                                       set: { if let id = $0 { model.open(id) } else { model.selection = nil } })
        List(selection: selection) {
            panelsSection
            projectsSection
            if !hits.isEmpty || searching { hitsSection }
            let pinned = filtered.filter(\.isPinned)
            if !pinned.isEmpty {
                Section("Pinned") { ForEach(pinned) { row($0) } }
            }
            Section {
                ForEach(filtered.filter { !$0.isPinned }) { row($0) }
            } header: {
                conversationsHeader
            }
        }
        .searchable(text: $filter, placement: .sidebar, prompt: "Search conversations")
        .task(id: query) { await searchServer() }
        .safeAreaInset(edge: .bottom) { AccountFooter() }
        .refreshable { await model.refreshConversations(); await model.refreshLibrary() }
        .sheet(isPresented: $newProject) { NewProjectSheet() }
        .alert("New Folder", isPresented: Binding(get: { folderPrompt != nil }, set: { if !$0 { folderPrompt = nil } })) {
            TextField("Folder name", text: $newFolderName)
            Button("Move") {
                if let id = folderPrompt { let name = newFolderName; Task { await model.setFolder(id, name) } }
                folderPrompt = nil
                newFolderName = ""
            }
            Button("Cancel", role: .cancel) { folderPrompt = nil; newFolderName = "" }
        } message: {
            Text("Folders group conversations on every device.")
        }
    }

    // MARK: Sections

    private var panelsSection: some View {
        Section("Library") {
            ForEach(LibraryPanel.allCases) { p in
                Button {
                    model.panel = p
                } label: {
                    Label(p.title, systemImage: p.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(model.panel == p ? Color.accentColor.opacity(0.18) : Color.clear)
            }
        }
    }

    private var projectsSection: some View {
        Section {
            projectRow(nil, name: "All conversations", symbol: "tray.full")
            ForEach(model.projects) { p in
                projectRow(p.id, name: p.name, symbol: "folder.badge.gearshape")
                    .contextMenu {
                        Button("Delete Project", role: .destructive) { Task { await model.deleteProject(p.id) } }
                    }
            }
        } header: {
            HStack {
                Text("Projects")
                Spacer()
                Button { newProject = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("New project: standing instructions and files for a kind of work")
            }
        }
    }

    private func projectRow(_ id: Int?, name: String, symbol: String) -> some View {
        Button {
            model.activeProjectId = id
        } label: {
            Label(name, systemImage: symbol).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(model.activeProjectId == id ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    private var hitsSection: some View {
        Section("In messages") {
            if searching && hits.isEmpty { ProgressView().controlSize(.small) }
            ForEach(hits) { h in
                Button {
                    model.openServerConversation(h.conversationId)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(h.conversationTitle).lineLimit(1)
                        Text(h.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var conversationsHeader: some View {
        HStack {
            Text(model.folderFilter ?? (model.user?.email ?? "Conversations")).lineLimit(1)
            Spacer()
            if !model.conversationFolders.isEmpty {
                Menu {
                    Button("All folders") { model.folderFilter = nil }
                    Divider()
                    ForEach(model.conversationFolders, id: \.self) { f in
                        Button(f) { model.folderFilter = f }
                    }
                } label: {
                    Image(systemName: model.folderFilter == nil ? "folder" : "folder.fill")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Show one folder")
            }
        }
    }

    // MARK: Rows

    private func row(_ c: LocalConversation) -> some View {
        HStack(spacing: 6) {
            if c.isPrivate {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).help(BrainText.privateExplainer)
            } else if c.serverId == nil {
                Image(systemName: "desktopcomputer").foregroundStyle(.secondary).help("Only on this Mac so far")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title).lineLimit(1)
                HStack(spacing: 6) {
                    Text(c.updatedAt, format: .relative(presentation: .named))
                    if c.isPrivate { Text(BrainText.onlyOnThisMac) }
                    if let f = c.folder, model.folderFilter == nil { Text(f).lineLimit(1) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.answering[c.id] != nil { ProgressView().controlSize(.mini) }
        }
        .tag(c.id)
        .contextMenu { rowMenu(c) }
    }

    @ViewBuilder
    private func rowMenu(_ c: LocalConversation) -> some View {
        Button(c.isPinned ? "Unpin" : "Pin") { Task { await model.setPinned(c.id, !c.isPinned) } }
        Menu("Move to Folder") {
            ForEach(model.conversationFolders, id: \.self) { f in
                Button(f) { Task { await model.setFolder(c.id, f) } }.disabled(c.folder == f)
            }
            if !model.conversationFolders.isEmpty { Divider() }
            Button("New Folder...") { folderPrompt = c.id }
            if c.folder != nil { Button("Remove from Folder") { Task { await model.setFolder(c.id, nil) } } }
        }
        .disabled(c.serverId == nil)
        Button("Copy Share Link") { Task { await model.copyShareLink(for: c.id) } }.disabled(c.serverId == nil)
        Divider()
        if c.serverId != nil {
            Button("Delete", role: .destructive) { Task { await model.deleteEverywhere(c.id) } }
        }
        Button(c.serverId == nil ? "Delete" : "Delete from This Mac", role: .destructive) { model.delete(c.id) }
    }

    // MARK: Server search

    private func searchServer() async {
        let q = query
        guard q.count >= 2, model.canReachCloud, model.api.token != nil else { hits = []; searching = false; return }
        searching = true
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
        if let found = try? await model.api.searchMessages(q), !Task.isCancelled { hits = found }
        searching = false
    }
}

/// A new project: a name, what it is for, and standing instructions for every question in it.
struct NewProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    @State private var kind = "general"
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New project").font(.title2.weight(.semibold))
            Text("A project holds standing instructions and reference files. Questions asked inside it carry them, on every device.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name)
            TextField("What it is for (optional)", text: $description)
            Picker("Kind", selection: $kind) {
                Text("General").tag("general")
                Text("Coding").tag("coding")
                Text("Research").tag("research")
                Text("Writing").tag("writing")
            }
            Text("Instructions for every question (optional)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $instructions).font(.body).frame(minHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Create") {
                    busy = true
                    Task {
                        await model.createProject(name: name.trimmingCharacters(in: .whitespaces),
                                                  description: description.isEmpty ? nil : description,
                                                  instructions: instructions.isEmpty ? nil : instructions, kind: kind)
                        busy = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 460)
    }
}

/// The panel chosen in the sidebar, in the detail column.
struct PanelHost: View {
    let panel: LibraryPanel

    var body: some View {
        Group {
            switch panel {
            case .build: BuildWithOloView()
            case .memory: MemoryView()
            case .artifacts: ArtifactsView(conversationId: nil)
            case .watching: MonitorsView()
            case .zeus: ZeusGraphView()
            case .skills: SkillsView()
            case .connectors: ConnectorsView()
            case .jobs: JobsView()
            }
        }
        .navigationTitle(panel.title)
    }
}

/// Unfinished work, surfaced on return: the newest nudge above the composer, as on the web.
struct NudgeBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let n = model.nudges.first {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bell")
                VStack(alignment: .leading, spacing: 2) {
                    Text(n.title).font(.callout.weight(.medium))
                    if !n.body.isEmpty { Text(n.body).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if let s = n.suggestion {
                        Button(s) { model.openNudge(n) }.buttonStyle(.link).font(.caption)
                    }
                }
                Spacer(minLength: 8)
                Button { Task { await model.markNudge(n, status: "dismissed") } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Dismiss")
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
