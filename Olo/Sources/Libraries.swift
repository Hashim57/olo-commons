import AppKit
import Observation
import OloKit

/// The copy of Olo Commons kept on this Mac for offline answers. It is a small
/// JSON file (about 1 MB), refreshed at most every six hours while online; the
/// search index is built once, in the background, at low priority.
@MainActor @Observable
final class CommonsLibrary {
    private(set) var atomCount = 0
    private(set) var builtAt: String?
    private(set) var updating = false
    private(set) var lastError: String?
    @ObservationIgnored private var index: SearchIndex<Atom>?
    private let store: LocalStore

    init(store: LocalStore) { self.store = store }

    func loadFromDisk() async {
        guard index == nil, let data = store.snapshotData() else { return }
        await install(data)
    }

    func refreshIfStale(force: Bool = false) async {
        if !force, let age = store.snapshotAge(), age < 6 * 3600 { await loadFromDisk(); return }
        guard !updating else { return }
        updating = true
        defer { updating = false }
        for url in CommonsSnapshot.urls {
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 60
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
                if await install(data) {
                    store.saveSnapshot(data)
                    lastError = nil
                    return
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        await loadFromDisk()
    }

    @discardableResult
    private func install(_ data: Data) async -> Bool {
        let built = await Task.detached(priority: .utility) { () -> (CommonsSnapshot, SearchIndex<Atom>)? in
            guard let snap = try? CommonsSnapshot.decode(data) else { return nil }
            return (snap, SearchIndex(snap.atoms, title: \.title, text: \.text))
        }.value
        guard let built else { return false }
        index = built.1
        atomCount = built.0.atoms.count
        builtAt = built.0.builtAt
        return true
    }

    func search(_ q: String, limit: Int = 6) -> [Passage] {
        guard let index else { return [] }
        return index.search(q, limit: limit).map {
            Passage(title: $0.doc.title, text: $0.doc.text, url: $0.doc.url, origin: "\($0.doc.source), \($0.doc.licence)")
        }
    }
}

/// Folders you choose to let Olo search. Access is kept with a security-scoped
/// bookmark (the sandbox's way of remembering your choice); the files are read
/// only when you ask Olo to index them, never watched in the background.
@MainActor @Observable
final class FolderLibrary {
    struct Folder: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var bookmark: Data
    }

    struct Chunk: Sendable {
        let file: String
        let path: String
        let text: String
    }

    private(set) var folders: [Folder] = []
    private(set) var fileCount = 0
    private(set) var chunkCount = 0
    private(set) var indexing = false
    private(set) var lastIndexed: Date?
    @ObservationIgnored private var index: SearchIndex<Chunk>?
    private let defaultsKey = "folders.v1"

    nonisolated static let maxFiles = 3_000
    nonisolated static let maxTextPerFile = 400_000

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey), let list = try? JSONDecoder().decode([Folder].self, from: data) {
            folders = list
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(folders) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Let Olo Search"
        panel.message = "Olo reads these folders only when you index them, and sends a passage only with a question you ask."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bm = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) else { continue }
            if !folders.contains(where: { $0.name == url.path }) { folders.append(Folder(name: url.path, bookmark: bm)) }
        }
        save()
        Task { await reindex() }
    }

    func remove(_ folder: Folder) {
        folders.removeAll { $0.id == folder.id }
        save()
        Task { await reindex() }
    }

    func reindex() async {
        guard !indexing else { return }
        indexing = true
        defer { indexing = false }
        let bookmarks = folders.map(\.bookmark)
        let result = await Task.detached(priority: .utility) { FolderLibrary.walk(bookmarks) }.value
        let built = await Task.detached(priority: .utility) { SearchIndex(result.1, title: \.file, text: \.text) }.value
        index = built
        fileCount = result.0
        chunkCount = result.1.count
        lastIndexed = Date()
    }

    /// Reads every readable file under the folders (synchronous; always called off the main thread).
    nonisolated static func walk(_ bookmarks: [Data]) -> (Int, [Chunk]) {
        var files = 0
        var chunks: [Chunk] = []
        let skip: Set<String> = ["node_modules", ".git", "build", "dist", "DerivedData", "Pods"]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        for bm in bookmarks {
            var stale = false
            guard let root = try? URL(resolvingBookmarkData: bm, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            let ok = root.startAccessingSecurityScopedResource()
            defer { if ok { root.stopAccessingSecurityScopedResource() } }
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = walker.nextObject() as? URL {
                if files >= maxFiles { break }
                if skip.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
                guard (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true, FileExtractor.canRead(url) else { continue }
                guard let text = FileExtractor.text(of: url) else { continue }
                files += 1
                for piece in Chunker.chunks(String(text.prefix(maxTextPerFile))) {
                    chunks.append(Chunk(file: url.lastPathComponent, path: url.path, text: piece))
                }
            }
        }
        return (files, chunks)
    }

    func search(_ q: String, limit: Int = 4) -> [Passage] {
        guard let index else { return [] }
        return index.search(q, limit: limit).filter { $0.score > 1.5 }.map {
            Passage(title: $0.doc.file, text: $0.doc.text, url: URL(fileURLWithPath: $0.doc.path).absoluteString, origin: "Your files")
        }
    }

    /// Indexes on first use only, so nothing runs at launch.
    func ensureIndexed() async {
        if index == nil, !folders.isEmpty { await reindex() }
    }
}
