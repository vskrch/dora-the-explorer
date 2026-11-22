import CoreServices
import Foundation

/// One coalesced change to a watched directory.
public struct DirectoryChange: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case inserted([String])
        case removed([String])
        case modified([String])
        case renamed(from: [String], to: [String])
        case rescan
    }

    public let kind: Kind
    public let timestamp: Date

    public init(kind: Kind, timestamp: Date = Date()) {
        self.kind = kind
        self.timestamp = timestamp
    }
}

/// FSEvents-based watcher for a single directory (non-recursive unless asked).
///
/// Uses file-level events, CF types and no deferral with a 0.1 s latency so the
/// UI reflects external changes almost immediately. Events are queued on a
/// serial background queue — never on the main thread — and coalesced into a
/// single `DirectoryChange` per callback.
public final class DirectoryWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (DirectoryChange) -> Void

    private let directory: URL
    private let recursive: Bool
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.dorasoft.dora.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private var stopped = false

    public init(directory: URL, recursive: Bool = false, handler: @escaping Handler) {
        self.directory = directory
        self.recursive = recursive
        self.handler = handler
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil, !stopped else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
                | (recursive ? kFSEventStreamCreateFlagWatchRoot : 0)
        )

        let paths = [directory.path] as CFArray
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, eventCount, eventPaths, eventFlags, _ in
                guard let info else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.handleEvents(
                    count: Int(eventCount),
                    paths: eventPaths,
                    flags: eventFlags
                )
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else {
            DoraLog.fsCore.error("FSEventStreamCreate failed for \(self.directory.path, privacy: .public)")
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
            DoraLog.fsCore.error("FSEventStreamStart failed for \(self.directory.path, privacy: .public)")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    public func stop() {
        lock.lock()
        guard let stream, !stopped else {
            stopped = true
            lock.unlock()
            return
        }
        stopped = true
        self.stream = nil
        lock.unlock()

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func handleEvents(count: Int, paths: UnsafeMutableRawPointer, flags: UnsafePointer<FSEventStreamEventFlags>) {
        guard let cfPaths = unsafeBitCast(paths, to: CFArray?.self) else { return }
        let pathArray = cfPaths as? [String] ?? []
        let watchedInode = Self.inode(of: directory)

        var inserted: [String] = []
        var removed: [String] = []
        var modified: [String] = []
        var rootChanged = false

        for index in 0..<count {
            let eventFlags = flags[index]
            guard index < pathArray.count else { continue }
            let path = pathArray[index]
            if eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                rootChanged = true
                continue
            }
            if !recursive {
                // Compare the parent by inode: the registered path and the event
                // path can differ (symlinks, /private/var vs /var).
                let parentPath = (path as NSString).deletingLastPathComponent
                guard Self.inode(of: URL(fileURLWithPath: parentPath)) == watchedInode else { continue }
            }
            let name = (path as NSString).lastPathComponent
            if name.isEmpty { continue }

            if eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 {
                removed.append(name)
            } else if eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 {
                inserted.append(name)
            } else if eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 {
                removed.append(name)
            } else {
                modified.append(name)
            }
        }

        let change: DirectoryChange?
        if rootChanged {
            change = DirectoryChange(kind: .rescan)
        } else if !removed.isEmpty && !inserted.isEmpty {
            // FSEvents reports renames as removed+created with no inode pairing,
            // so hand both sides to the model, which resolves them by identity.
            change = DirectoryChange(kind: .rescan)
        } else if !inserted.isEmpty {
            change = DirectoryChange(kind: .inserted(dedupe(inserted)))
        } else if !removed.isEmpty {
            change = DirectoryChange(kind: .removed(dedupe(removed)))
        } else if !modified.isEmpty {
            change = DirectoryChange(kind: .modified(dedupe(modified)))
        } else {
            change = nil
        }

        if let change {
            handler(change)
        }
    }

    private func dedupe(_ names: [String]) -> [String] {
        Array(Set(names)).sorted()
    }

    private static func inode(of url: URL) -> UInt64 {
        var info = stat()
        let ok = url.path.withCString { lstat($0, &info) == 0 }
        return ok ? info.st_ino : 0
    }
}
