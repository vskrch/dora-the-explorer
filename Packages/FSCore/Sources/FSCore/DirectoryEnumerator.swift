import Darwin
import Foundation
import os

/// Fast directory listing.
///
/// `getattrlistbulk(2)` is used first for the entries it returns in one call
/// (typically all of them in a single kernel batch). On this machine/macOS build
/// subsequent calls on the same fd return a malformed, stale buffer, so entries
/// not covered by that batch fall back to a `readdir` + `stat` walk. Both paths
/// run off-main and stream results in `Configuration.batchSize` batches.
public actor DirectoryEnumerator {
    public struct Configuration: Sendable {
        public var batchSize: Int
        public var showHidden: Bool
        public var treatPackagesAsFiles: Bool

        public init(batchSize: Int = 500, showHidden: Bool = false, treatPackagesAsFiles: Bool = false) {
            self.batchSize = max(1, batchSize)
            self.showHidden = showHidden
            self.treatPackagesAsFiles = treatPackagesAsFiles
        }
    }

    public enum EnumerationError: Error, Sendable, Equatable {
        case notADirectory(String)
        case openFailed(path: String, errno: Int32)
    }

    public init() {}

    /// Streams batches for `directory`, already filtered by `showHidden`.
    /// Cancelling the consuming task stops at the next batch boundary.
    public nonisolated func batches(
        of directory: URL,
        configuration: Configuration = Configuration()
    ) -> AsyncThrowingStream<[FileItem], any Error> {
        AsyncThrowingStream<[FileItem], any Error> { continuation in
            let task = Task.detached(priority: .userInitiated) {
                assertNotMainThreadForIO()
                let state = EnumerationSignpost(name: "enumerate")
                defer { state.end() }
                do {
                    try Self.enumerate(directory: directory, configuration: configuration) { batch, isFirst in
                        if isFirst { state.markFirstBatch() }
                        state.addEntries(batch.count)
                        if Task.isCancelled { throw CancellationError() }
                        continuation.yield(batch)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One-shot result (tests, small folders).
    public nonisolated func items(
        in directory: URL,
        configuration: Configuration = Configuration()
    ) async throws -> [FileItem] {
        var all: [FileItem] = []
        for try await batch in batches(of: directory, configuration: configuration) {
            all.append(contentsOf: batch)
        }
        return all
    }

    // MARK: - Implementation

    private static func enumerate(
        directory: URL,
        configuration: Configuration,
        emit: ([FileItem], Bool) throws -> Void
    ) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EnumerationError.notADirectory(directory.path)
        }

        let fd = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard fd >= 0 else {
            throw EnumerationError.openFailed(path: directory.path, errno: errno)
        }
        defer { close(fd) }

        var emittedFirst = false
        var seenNames = Set<String>()

        // Pass 1: bulk attributes for whatever the kernel hands back in one call.
        var attrList = BulkAttributeParser.makeAttrList()
        let bufferSize = 512 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        let bulkCount = getattrlistbulk(fd, &attrList, buffer, bufferSize, UInt64(FSOPT_REPORT_FULLSIZE))
        if bulkCount > 0 {
            let parsed = BulkAttributeParser.parse(
                buffer: UnsafeRawBufferPointer(start: buffer, count: bufferSize),
                directory: directory,
                showHidden: configuration.showHidden
            )
            var batch: [FileItem] = []
            batch.reserveCapacity(min(parsed.items.count, configuration.batchSize))
            for item in parsed.items {
                seenNames.insert(item.name)
                batch.append(item)
                if batch.count == configuration.batchSize {
                    try emit(batch, !emittedFirst)
                    emittedFirst = true
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if !batch.isEmpty {
                try emit(batch, !emittedFirst)
                emittedFirst = true
            }
        }

        // Pass 2: readdir + lstat for everything bulk did not return.
        try enumerateWithReadDir(
            directory: directory,
            configuration: configuration,
            excluding: seenNames,
            emittedFirst: &emittedFirst,
            emit: emit
        )
    }

    private static func enumerateWithReadDir(
        directory: URL,
        configuration: Configuration,
        excluding: Set<String>,
        emittedFirst: inout Bool,
        emit: ([FileItem], Bool) throws -> Void
    ) throws {
        guard let dir = directory.withUnsafeFileSystemRepresentation({ path -> UnsafeMutablePointer<DIR>? in
            guard let path else { return nil }
            return opendir(path)
        }) else {
            throw EnumerationError.openFailed(path: directory.path, errno: errno)
        }
        defer { closedir(dir) }

        var batch: [FileItem] = []
        batch.reserveCapacity(configuration.batchSize)

        while let entry = readdir(dir) {
            if Task.isCancelled { return }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name.isEmpty || name == "." || name == ".." || excluding.contains(name) { continue }

            let url = directory.appendingPathComponent(name)
            var info = stat()
            let ok = url.withUnsafeFileSystemRepresentation { path -> Bool in
                guard let path else { return false }
                return lstat(path, &info) == 0
            }
            guard ok else { continue }

            let mode = info.st_mode & S_IFMT
            let isDirectory = mode == S_IFDIR
            let isSymlink = mode == S_IFLNK
            let isPackage = isDirectory
                && BulkAttributeParser.isPackageExtension((name as NSString).pathExtension)
            let isHidden = name.hasPrefix(".") || (info.st_flags & UInt32(UF_HIDDEN)) != 0
            if !configuration.showHidden && isHidden { continue }

            let created = Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec))
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            let accessed = Date(timeIntervalSince1970: TimeInterval(info.st_atimespec.tv_sec))

            // Identity: `getattrlistbulk` vends the POSIX inode for
            // ATTR_CMN_FILEID, so this matches the bulk pass and
            // `FileItem.resolveID` exactly. Hard links disambiguate with a
            // name suffix (nlink > 1).
            let id = info.st_nlink > 1
                ? "\(directory.standardizedFileURL.path)#\(info.st_ino)#\(name)"
                : "\(directory.standardizedFileURL.path)#\(info.st_ino)"

            batch.append(
                FileItem(
                    id: id,
                    url: url,
                    name: name,
                    isDirectory: isDirectory,
                    isPackage: isPackage,
                    isSymlink: isSymlink,
                    isHidden: isHidden,
                    size: isDirectory ? nil : Int64(info.st_size),
                    allocatedSize: Int64(info.st_blocks) * 512,
                    created: created,
                    modified: modified,
                    accessed: accessed,
                    flags: info.st_flags
                )
            )
            if batch.count == configuration.batchSize {
                try emit(batch, !emittedFirst)
                emittedFirst = true
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty {
            try emit(batch, !emittedFirst)
            emittedFirst = true
        }
    }
}

/// Signpost interval for one enumeration, plus first-batch events.
final class EnumerationSignpost: @unchecked Sendable {
    private let name: StaticString
    private let state: OSSignpostIntervalState
    private let signpostID: OSSignpostID
    private let lock = NSLock()
    private var ended = false
    private var sawFirstBatch = false

    init(name: StaticString) {
        self.name = name
        self.signpostID = OSSignpostID(log: OSSignposter.loggerForCategory(DoraLog.subsystem, "perf"))
        self.state = Signposter.performance.beginInterval(name, id: signpostID)
    }

    func markFirstBatch() {
        lock.lock()
        defer { lock.unlock() }
        guard !sawFirstBatch else { return }
        sawFirstBatch = true
        Signposter.performance.emitEvent(name, id: signpostID, "first-batch")
    }

    func addEntries(_ count: Int) {
        Signposter.performance.emitEvent(name, id: signpostID, "entries \(count)")
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return }
        ended = true
        Signposter.performance.endInterval(name, state)
    }
}
