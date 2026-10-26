import SwiftUI
import Observation
import OloKit

/// The chosen folder as a tree, read lazily: a folder's contents are listed the first time it
/// is expanded and kept until something in it changes. The same ignore rules as the reviews
/// (.git, node_modules, build output, hidden files, .gitignore patterns) apply.
@MainActor @Observable
final class BuildFileTree {
    struct Entry: Hashable {
        /// Relative to the folder, "/" separated; "" is the folder itself.
        let path: String
        let name: String
        let isDirectory: Bool
    }

    struct Row: Hashable {
        let entry: Entry
        let depth: Int
    }

    static let maxRows = 5_000

    private(set) var expanded: Set<String> = []
    /// Bumped when a listing is dropped, so the rows are read again.
    private(set) var version = 0
    /// Where "New File..." and "New Folder..." put things: the folder last clicked ("" is the top).
    var targetFolder = ""

    @ObservationIgnored weak var workspace: BuildWorkspace?
    @ObservationIgnored private var listings: [String: [Entry]] = [:]

    func reset() {
        listings = [:]
        expanded = []
        targetFolder = ""
        version += 1
    }

    /// Every visible row, top to bottom.
    func rows() -> [Row] {
        _ = version
        var out: [Row] = []
        func walk(_ dir: String, depth: Int) {
            for e in children(of: dir) {
                if out.count >= BuildFileTree.maxRows { return }
                out.append(Row(entry: e, depth: depth))
                if e.isDirectory && expanded.contains(e.path) { walk(e.path, depth: depth + 1) }
            }
        }
        walk("", depth: 0)
        return out
    }

    func toggle(_ dir: String) {
        if expanded.contains(dir) {
            expanded.remove(dir)
        } else {
            expanded.insert(dir)
        }
        targetFolder = dir
    }

    /// Expands a folder and every folder above it.
    func expand(_ dir: String) {
        var parts: [String] = []
        for p in dir.split(separator: "/") {
            parts.append(String(p))
            expanded.insert(parts.joined(separator: "/"))
        }
        targetFolder = dir
    }

    /// Lists the folder holding `rel` again next time.
    func invalidate(parentOf rel: String) {
        let parent = (rel as NSString).deletingLastPathComponent
        listings[parent] = nil
        version += 1
    }

    func refresh() {
        listings = [:]
        version += 1
    }

    private func children(of dir: String) -> [Entry] {
        if let cached = listings[dir] { return cached }
        guard let root = workspace?.folderURL, let ignore = workspace?.ignore else { return [] }
        let url = dir.isEmpty ? root : root.appendingPathComponent(dir)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])) ?? []
        var entries: [Entry] = []
        for item in items {
            let name = item.lastPathComponent
            let rel = dir.isEmpty ? name : dir + "/" + name
            let values = try? item.resourceValues(forKeys: Set(keys))
            // Symbolic links are left out: they can point outside the folder, or loop.
            if values?.isSymbolicLink == true { continue }
            let isDir = values?.isDirectory ?? false
            // A folder is ignored when a file inside it would be.
            if ignore.ignores(isDir ? rel + "/olo-probe-file" : rel) { continue }
            entries.append(Entry(path: rel, name: name, isDirectory: isDir))
        }
        entries.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        listings[dir] = entries
        return entries
    }

    /// An SF Symbol for the file's type.
    static func icon(for entry: Entry, expanded: Bool) -> String {
        if entry.isDirectory { return expanded ? "folder.fill" : "folder" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "js", "mjs", "cjs", "jsx", "ts", "tsx", "mts", "java", "kt", "c", "cc", "cpp", "h", "hpp", "m", "mm", "cs", "go", "rs", "dart", "php", "sol":
            return "curlybraces"
        case "json": return "curlybraces.square"
        case "py", "rb", "pl", "lua", "r": return "chevron.left.forwardslash.chevron.right"
        case "sh", "bash", "zsh", "fish", "ps1": return "terminal"
        case "html", "htm", "xml", "vue", "svelte": return "chevron.left.slash.chevron.right"
        case "css", "scss", "sass", "less": return "paintbrush"
        case "md", "txt", "rtf": return "doc.plaintext"
        case "yaml", "yml", "toml", "ini", "cfg", "conf", "plist", "env": return "gearshape"
        case "sql": return "cylinder"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "ico": return "photo"
        case "pdf": return "doc.richtext"
        case "csv", "tsv": return "tablecells"
        default: return "doc"
        }
    }
}

/// The left column: the folder's files, New File and New Folder.
struct BuildFileTreeView: View {
    @Environment(AppModel.self) private var model
    @State private var naming: NewItemKind?
    @State private var draft = ""

    enum NewItemKind: Identifiable {
        case file, folder
        var id: Int { self == .file ? 0 : 1 }
    }

    var body: some View {
        let ws = model.buildWorkspace
        VStack(spacing: 0) {
            header
            Divider()
            BuildFileList()
            Divider()
            HStack(spacing: 6) {
                Button("New File...") { begin(.file) }
                Button("New Folder...") { begin(.folder) }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(8)
        }
        .alert(naming == .folder ? "New Folder" : "New File", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField(naming == .folder ? "src/utils" : "src/main.swift", text: $draft)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) { naming = nil }
        } message: {
            Text("A path inside \(ws.folderName). Folders on the way are made for you.")
        }
    }

    private var header: some View {
        let ws = model.buildWorkspace
        return HStack(spacing: 6) {
            Label(ws.folderName, systemImage: "folder")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button { ws.tree.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Read the folder again")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func begin(_ kind: NewItemKind) {
        let folder = model.buildWorkspace.tree.targetFolder
        draft = folder.isEmpty ? "" : folder + "/"
        naming = kind
    }

    private func create() {
        let kind = naming
        naming = nil
        let name = draft
        draft = ""
        if kind == .folder {
            model.buildWorkspace.editor.createFolder(name)
        } else {
            model.buildWorkspace.editor.createFile(name)
        }
    }
}

struct BuildFileList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ws = model.buildWorkspace
        let tree = ws.tree
        let rows = tree.rows()
        let open = ws.editor.currentPath
        List {
            if rows.isEmpty {
                Text("No files Olo can show here yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.self) { row in
                BuildFileRow(row: row, expanded: tree.expanded.contains(row.entry.path), isOpen: row.entry.path == open)
            }
        }
        .listStyle(.sidebar)
        .frame(maxHeight: .infinity)
    }
}

struct BuildFileRow: View {
    let row: BuildFileTree.Row
    let expanded: Bool
    let isOpen: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let entry = row.entry
        HStack(spacing: 4) {
            Image(systemName: entry.isDirectory ? (expanded ? "chevron.down" : "chevron.right") : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(entry.isDirectory ? 1 : 0)
                .frame(width: 10)
            Image(systemName: BuildFileTree.icon(for: entry, expanded: expanded))
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .fontWeight(isOpen ? .semibold : .regular)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 12)
        .contentShape(Rectangle())
        .onTapGesture { activate() }
        .listRowBackground(isOpen ? Color.accentColor.opacity(0.15) : Color.clear)
        .help(entry.path)
    }

    private func activate() {
        let ws = model.buildWorkspace
        let entry = row.entry
        if entry.isDirectory {
            ws.tree.toggle(entry.path)
        } else {
            ws.tree.targetFolder = (entry.path as NSString).deletingLastPathComponent
            ws.editor.open(entry.path)
        }
    }
}
