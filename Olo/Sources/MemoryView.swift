import AppKit
import SwiftUI
import OloKit

/// What Olo remembers about the person (memory.*). Every entry can be read, changed and
/// deleted; what Olo proposes after a conversation waits here until approved, and only
/// approved memories are recalled. Export saves a Markdown (or JSON) file the person owns.
@MainActor @Observable
final class MemoryController {
    var list: MemoryList?
    var loading = false
    var error: String?
    var note: String?
    private let api: OloAPI

    init(api: OloAPI) { self.api = api }

    func load() async {
        loading = true
        defer { loading = false }
        do { list = try await api.listMemories(); error = nil }
        catch let e as TRPC.RemoteError where e.isNotFound { error = "This server has no memory yet." }
        catch { self.error = error.localizedDescription }
    }

    private func run(_ what: String, _ work: () async throws -> Void) async {
        do { try await work(); await load() }
        catch { note = "Could not \(what): \(error.localizedDescription)" }
    }

    func approve(_ m: Memory) async { await run("approve the memory") { try await self.api.approveMemory(id: m.id) } }
    func delete(_ m: Memory) async { await run("delete the memory") { try await self.api.deleteMemory(id: m.id) } }
    func update(_ m: Memory, content: String) async { await run("change the memory") { try await self.api.updateMemory(id: m.id, content: content) } }
    func add(category: String, content: String) async { await run("add the memory") { _ = try await self.api.addMemory(category: category, content: content) } }
    func clear() async { await run("clear memory") { try await self.api.clearMemories() } }
    func setEnabled(_ on: Bool) async { await run(on ? "turn memory on" : "turn memory off") { try await self.api.setMemoryEnabled(on) } }

    /// Saves the export where the person chooses, as Markdown or JSON.
    func export(asJSON: Bool) async {
        do {
            let export = try await api.exportMemories()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = MemoryMarkdown.filename(extension: asJSON ? "json" : "md")
            panel.canCreateDirectories = true
            panel.title = "Export Memory"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let data: Data
            if asJSON {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                data = try enc.encode(export)
            } else {
                data = Data(MemoryMarkdown.render(export).utf8)
            }
            try data.write(to: url, options: [.atomic])
            note = "Exported \(export.memories.count) \(export.memories.count == 1 ? "memory" : "memories")."
        } catch {
            note = "Could not export: \(error.localizedDescription)"
        }
    }
}

struct MemoryView: View {
    @Environment(AppModel.self) private var model
    @State private var controller: MemoryController?
    @State private var editing: Memory?
    @State private var draft = ""
    @State private var adding = false
    @State private var addCategory = "profile"
    @State private var confirmClear = false

    var body: some View {
        Group {
            if let c = controller { content(c) } else { ProgressView() }
        }
        .task {
            if controller == nil { controller = MemoryController(api: model.api) }
            await controller?.load()
        }
    }

    private func content(_ c: MemoryController) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(c)
                if let err = c.error { Text(err).foregroundStyle(.secondary) }
                if let list = c.list {
                    enabledRow(c, list)
                    if !list.proposed.isEmpty { proposedSection(c, list) }
                    categories(c, list)
                    if list.memories.isEmpty && c.error == nil {
                        Text("Nothing remembered yet. Olo proposes memories after conversations in which you tell it something durable about yourself or your work.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                footer(c)
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editing) { m in editSheet(c, m) }
        .sheet(isPresented: $adding) { addSheet(c) }
        .confirmationDialog("Forget everything Olo remembers about you?", isPresented: $confirmClear) {
            Button("Clear Memory", role: .destructive) { Task { await c.clear() } }
        } message: { Text("Every memory is deleted on helius-olo.io. Conversations are not affected.") }
    }

    private func header(_ c: MemoryController) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Memory").font(.largeTitle.weight(.semibold))
            Text("Things you've told Olo that it keeps between conversations. Each reply says which of these shaped it. Change or remove anything here.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Olo only keeps what you state yourself, and never health, money, politics, religion or similar details, even if you mention them. Nothing Olo picks out of a conversation is kept until you approve it here.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                if let list = c.list {
                    Text("\(list.memories.count) of \(list.cap) memories" + (list.nearCap ? " (nearly full: the least used are retired when the limit is reached)" : ""))
                        .font(.caption).foregroundStyle(list.nearCap ? Color.orange : Color.secondary)
                }
                Menu("Export") {
                    Button("As Markdown...") { Task { await c.export(asJSON: false) } }
                    Button("As JSON...") { Task { await c.export(asJSON: true) } }
                }
                .fixedSize().controlSize(.small)
                Button("Add...") { adding = true }.controlSize(.small)
                if c.loading { ProgressView().controlSize(.small) }
                if let n = c.note { Text(n).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func enabledRow(_ c: MemoryController, _ list: MemoryList) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Remember things I tell Olo")
                Text(list.enabled ? "On. New facts are proposed after each conversation and kept once you approve them." : "Off. Nothing new is proposed, and existing memories are not used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { list.enabled }, set: { on in Task { await c.setEnabled(on) } }))
                .toggleStyle(.switch).labelsHidden()
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func proposedSection(_ c: MemoryController, _ list: MemoryList) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Waiting for your approval").font(.headline)
            Text("Olo picked these out of recent conversations. They are not recalled until you approve them.").font(.caption).foregroundStyle(.secondary)
            ForEach(list.proposed) { m in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.content).fixedSize(horizontal: false, vertical: true)
                        Text(MemoryCategory.label(m.category)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Approve") { Task { await c.approve(m) } }.controlSize(.small).buttonStyle(.borderedProminent)
                    Button("Reject") { Task { await c.delete(m) } }.controlSize(.small)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private func categories(_ c: MemoryController, _ list: MemoryList) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(MemoryCategory.order, id: \.self) { category in
                let items = list.approved.filter { $0.category == category }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(MemoryCategory.label(category)).font(.headline)
                        Text(MemoryCategory.blurb(category)).font(.caption).foregroundStyle(.secondary)
                        ForEach(items) { m in memoryRow(c, m) }
                    }
                }
            }
        }
    }

    private func memoryRow(_ c: MemoryController, _ m: Memory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(m.content).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if m.uses > 0 { Text("used \(m.uses)\u{00D7}").font(.caption2).foregroundStyle(.secondary) }
            Button { editing = m; draft = m.content } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Change")
            Button { Task { await c.delete(m) } } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete")
        }
        .padding(.vertical, 3)
    }

    private func footer(_ c: MemoryController) -> some View {
        HStack {
            Button("Clear Memory...", role: .destructive) { confirmClear = true }
                .disabled((c.list?.memories.isEmpty) ?? true)
            Spacer()
        }
        .padding(.top, 8)
    }

    private func editSheet(_ c: MemoryController, _ m: Memory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change a memory").font(.title3.weight(.semibold))
            TextField("Memory", text: $draft, axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder)
            Text("\(draft.count) of \(MemoryCategory.maxLength) characters; at least \(MemoryCategory.minLength).").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { editing = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    editing = nil
                    Task { await c.update(m, content: text) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!lengthOK(draft))
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func addSheet(_ c: MemoryController) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a memory").font(.title3.weight(.semibold))
            Text("Something durable you want Olo to know, in your own words. Added by hand, it is approved at once.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Category", selection: $addCategory) {
                ForEach(MemoryCategory.order, id: \.self) { Text(MemoryCategory.label($0)).tag($0) }
            }
            TextField("Memory", text: $draft, axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder)
            Text("\(draft.count) of \(MemoryCategory.maxLength) characters; at least \(MemoryCategory.minLength).").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { adding = false; draft = "" }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    adding = false
                    draft = ""
                    Task { await c.add(category: addCategory, content: text) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!lengthOK(draft))
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func lengthOK(_ s: String) -> Bool {
        let n = s.trimmingCharacters(in: .whitespacesAndNewlines).count
        return n >= MemoryCategory.minLength && n <= MemoryCategory.maxLength
    }
}
