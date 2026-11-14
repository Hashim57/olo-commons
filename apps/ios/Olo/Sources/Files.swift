import OloKit
import PDFKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Text from a file chosen in the Files app, read on the phone: PDF through PDFKit, rich text
/// through the system reader, and anything that is plain text. Other kinds are refused with a
/// plain sentence instead of being sent as noise.
enum FileReader {
    static let types: [UTType] = [.text, .sourceCode, .pdf, .json, .xml, .commaSeparatedText, .rtf]
    static let maxBytes = 20 * 1024 * 1024

    static func text(of url: URL) -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maxBytes { return nil }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return PDFDocument(url: url)?.string }
        if ext == "rtf" {
            return (try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))?.string
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        if data.prefix(8_192).contains(0) { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
    }

    static func attachment(for url: URL) -> Attachment? {
        guard let text = text(of: url), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Attachment(kind: .file, name: url.lastPathComponent, text: text)
    }
}

/// Projects (projects.*), the same as the Mac and the web: standing instructions and reference
/// files that go with every question asked inside the project.
struct ProjectsView: View {
    @EnvironmentObject var model: AppModel
    @State private var projects: [Project] = []
    @State private var state = "loading"
    @State private var showNew = false

    var body: some View {
        List {
            Section {
                Text("A project keeps instructions and reference files together. Ask inside a project and both go with every question.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let active = model.activeProject {
                    HStack {
                        Label("Asking in \(active.name)", systemImage: "checkmark.circle.fill").font(.subheadline)
                        Spacer()
                        Button("Stop") { model.activeProject = nil }.font(.footnote).buttonStyle(.borderless)
                    }
                }
            }
            if state == "loading" { ProgressView() }
            if state == "failed" { Text("Projects could not be loaded. Pull down to try again.").foregroundStyle(.secondary) }
            if state == "empty" { Text("No projects yet. Press + to make one.").foregroundStyle(.secondary) }
            ForEach(projects.filter { !$0.isArchived }) { p in
                NavigationLink {
                    ProjectDetailView(project: p, changed: { Task { await load() } })
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.name)
                        Text(p.description ?? p.kind.capitalized).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
        .navigationTitle("Projects and files")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { if model.signedIn { showNew = true } else { model.showSignIn = true } } label: { Image(systemName: "plus") }.accessibilityLabel("New project")
            }
        }
        .sheet(isPresented: $showNew) { NewProjectSheet(done: { Task { await load() } }) }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard model.api.token != nil else { state = "empty"; return }
        do {
            projects = try await model.api.listProjects()
            state = projects.isEmpty ? "empty" : "ready"
        } catch {
            state = "failed"
        }
    }
}

struct NewProjectSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let done: () -> Void
    @State private var name = ""
    @State private var summary = ""
    @State private var instructions = ""
    @State private var kind = "general"
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("What it is about (optional)", text: $summary, axis: .vertical).lineLimit(1...3)
                    Picker("Kind", selection: $kind) {
                        Text("General").tag("general")
                        Text("Coding").tag("coding")
                        Text("Research").tag("research")
                        Text("Writing").tag("writing")
                    }
                }
                Section {
                    TextField("How Olo should work in this project (optional)", text: $instructions, axis: .vertical).lineLimit(4...12)
                } header: { Text("Instructions") }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }
            .navigationTitle("New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
        }
    }

    private func create() async {
        busy = true
        defer { busy = false }
        let about = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let rules = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let p = try await model.api.createProject(OloAPI.ProjectCreateInput(name: name.trimmingCharacters(in: .whitespaces), description: about.isEmpty ? nil : about,
                                                                               instructions: rules.isEmpty ? nil : rules, kind: kind))
            model.activeProject = p
            done()
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// One project: its instructions, its files, and the switch that asks inside it.
struct ProjectDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let changed: () -> Void
    @State private var files: [ProjectFile] = []
    @State private var context: ProjectContext?
    @State private var instructions = ""
    @State private var picking = false
    @State private var note: String?
    @State private var busy = false
    @State private var confirmDelete = false

    private var isActive: Bool { model.activeProject?.id == project.id }

    var body: some View {
        List {
            Section {
                Toggle("Ask inside this project", isOn: Binding(get: { isActive }, set: { model.activeProject = $0 ? project : nil }))
            } footer: {
                Text("While this is on, the project's instructions and files go with every question you ask in the Olo tab.")
            }
            Section("Instructions") {
                TextField("How Olo should work in this project", text: $instructions, axis: .vertical).lineLimit(3...12)
                Button("Save instructions") { Task { await saveInstructions() } }
                    .disabled(busy || instructions == (project.instructions ?? ""))
            }
            Section {
                if files.isEmpty { Text("No files yet.").foregroundStyle(.secondary) }
                ForEach(files) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(f.sizeBytes), countStyle: .file) + (f.isIncluded ? "" : ", not included")).font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { Task { await remove(f) } }
                    }
                }
                Button { picking = true } label: { Label("Add a file", systemImage: "doc.badge.plus") }.disabled(busy)
            } header: { Text("Files") } footer: {
                if let c = context {
                    Text("\(c.filesIncluded) file\(c.filesIncluded == 1 ? "" : "s") go with each question (\(c.charactersUsed) of \(c.budget) characters)" + (c.truncated ? ". Some text is left out to fit." : "."))
                } else {
                    Text("PDF, text, Markdown, CSV, JSON and source files. The text is read on this iPhone and stored with the project.")
                }
            }
            if let note { Section { Text(note).font(.footnote).foregroundStyle(.secondary) } }
            Section {
                Button("Delete project", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: FileReader.types, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await add(urls) } }
        }
        .confirmationDialog("Delete this project and its files?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete project", role: .destructive) { Task { await deleteProject() } }
        }
        .task {
            instructions = project.instructions ?? ""
            await load()
        }
    }

    private func load() async {
        if let list = try? await model.api.listProjectFiles(projectId: project.id) { files = list }
        context = try? await model.api.projectContext(projectId: project.id)
    }

    private func add(_ urls: [URL]) async {
        busy = true
        defer { busy = false }
        var refused: [String] = []
        for url in urls {
            guard let text = FileReader.text(of: url), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { refused.append(url.lastPathComponent); continue }
            do {
                _ = try await model.api.addProjectFile(OloAPI.ProjectFileInput(projectId: project.id, name: url.lastPathComponent, content: text))
            } catch {
                note = "\(url.lastPathComponent) could not be added: \(error.localizedDescription)"
            }
        }
        if !refused.isEmpty { note = "No text could be read from: " + refused.joined(separator: ", ") + "." }
        await load()
    }

    private func remove(_ f: ProjectFile) async {
        do {
            try await model.api.deleteProjectFile(id: f.id)
            await load()
        } catch {
            note = "Could not remove the file: \(error.localizedDescription)"
        }
    }

    private func saveInstructions() async {
        busy = true
        defer { busy = false }
        do {
            try await model.api.updateProject(OloAPI.ProjectUpdateInput(projectId: project.id, instructions: instructions))
            note = "Instructions saved."
            changed()
        } catch {
            note = "Could not save: \(error.localizedDescription)"
        }
    }

    private func deleteProject() async {
        do {
            try await model.api.deleteProject(id: project.id)
            if isActive { model.activeProject = nil }
            changed()
            dismiss()
        } catch {
            note = "Could not delete: \(error.localizedDescription)"
        }
    }
}

/// The row above the composer: files from the Files app that go with the next question,
/// and the project the question is asked in.
struct AttachmentBar: View {
    @EnvironmentObject var model: AppModel
    @Binding var picking: Bool
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.attachments.isEmpty || model.activeProject != nil || note != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let p = model.activeProject {
                            tag(icon: "folder", text: p.name) { model.activeProject = nil }
                        }
                        ForEach(model.attachments) { a in
                            tag(icon: "doc", text: a.name) { model.attachments.removeAll { $0.id == a.id } }
                        }
                        if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: FileReader.types, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var refused: [String] = []
            for url in urls {
                if let a = FileReader.attachment(for: url) { model.attachments.append(a) } else { refused.append(url.lastPathComponent) }
            }
            note = refused.isEmpty ? nil : "No text could be read from " + refused.joined(separator: ", ")
        }
    }

    private func tag(icon: String, text: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Remove \(text)")
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }
}
