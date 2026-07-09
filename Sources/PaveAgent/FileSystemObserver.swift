#if os(macOS)
import CoreServices
import Foundation
import PaveKit

/// One FSEventStream over the configured watched folders. FSEvents always
/// watches the full subtree under a path; we ignore which descendant
/// changed and just re-reads the immediate children of the watched folder
/// itself on every batch, no recursion into the result.
final class FileSystemObserver {
    private let onChange: (RawChange) -> Void
    private let onError: (String) -> Void
    private let queue = DispatchQueue(label: "com.bbrizly.pave.fsevents")

    /// Expanded absolute path paired with the original tilde path from
    /// config, so callback paths can be matched and RawChange still carries
    /// the same folder string the config (and the ledger) uses.
    private let folders: [(expanded: String, original: String)]

    private var stream: FSEventStreamRef?

    init(folders: [String], onChange: @escaping (RawChange) -> Void, onError: @escaping (String) -> Void) {
        self.folders = folders.map { (($0 as NSString).expandingTildeInPath, $0) }
        self.onChange = onChange
        self.onError = onError
    }

    func start() {
        guard !folders.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let paths = folders.map { $0.expanded } as CFArray
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, Self.callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags
        ) else {
            onError("file observation failed")
            return
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            onError("file observation failed")
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let callback: FSEventStreamCallback = { _, clientInfo, _, eventPaths, _, _ in
        guard let clientInfo else { return }
        let observer = Unmanaged<FileSystemObserver>.fromOpaque(clientInfo).takeUnretainedValue()
        let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
        guard let paths = cfArray as? [String] else { return }
        observer.handle(paths: paths)
    }

    private func handle(paths: [String]) {
        var touched: Set<String> = []   // original tilde folders touched this batch
        for path in paths {
            for f in folders where path == f.expanded || path.hasPrefix(f.expanded + "/") {
                touched.insert(f.original)
            }
        }
        for original in touched {
            guard let f = folders.first(where: { $0.original == original }) else { continue }
            let snap = Self.snapshot(of: f.expanded)
            onChange(.folderChanged(folder: original, snapshot: snap))
        }
    }

    private static func snapshot(of expandedFolder: String) -> [FileStat] {
        let url = URL(fileURLWithPath: expandedFolder)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return items.compactMap { item -> FileStat? in
            guard let id = fileID(for: item) else { return nil }
            return FileStat(fileID: id, name: item.lastPathComponent)
        }
    }

    /// URLResourceValues has no plain UInt64 file id (fileResourceIdentifier
    /// is an opaque NSCopying box, not a number), so identity comes from
    /// st_ino via stat(). Stable for the lifetime of a file on one volume,
    /// which is all the move-detection window in EventNormalizer needs.
    private static func fileID(for url: URL) -> UInt64? {
        var info = stat()
        let ok = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return stat(path, &info) == 0
        }
        return ok ? UInt64(info.st_ino) : nil
    }
}
#endif
