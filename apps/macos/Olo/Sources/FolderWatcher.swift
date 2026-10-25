import CoreServices
import Foundation

/// Watches a folder tree with FSEvents, file by file, and reports the paths of files that were
/// created, changed or renamed (an editor's atomic save shows up as a rename). Any editor works,
/// since only the saves on disk are seen. Events are coalesced for 0.3 seconds by FSEvents; the
/// workspace debounces further per file.
///
/// FSEventStreamCreate takes a C function pointer, so the callback cannot capture anything: the
/// watcher reaches itself through the context's info pointer (Unmanaged, unretained; the stream
/// is invalidated before the watcher goes away).
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "olo.build.folderwatcher", qos: .utility)
    private let onChange: @Sendable ([String]) -> Void

    init(onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    /// Starts watching `path` and everything under it. False when FSEvents refuses.
    @discardableResult
    func start(path: String) -> Bool {
        stop()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            // With kFSEventStreamCreateFlagUseCFTypes the paths arrive as a CFArray of CFString.
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            var changed: [String] = []
            let fileFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
            let removedFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
            let interesting = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified
                                                      | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemInodeMetaMod)
            for i in 0..<min(count, paths.count) {
                let flags = eventFlags[i]
                guard flags & fileFlag != 0, flags & interesting != 0 else { continue }
                // A file removed and not recreated has nothing to review.
                if flags & removedFlag != 0 && !FileManager.default.fileExists(atPath: paths[i]) { continue }
                changed.append(paths[i])
            }
            if !changed.isEmpty { watcher.onChange(changed) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
