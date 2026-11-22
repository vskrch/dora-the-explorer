import Foundation
import FSCore

/// How the engine resolves "destination already exists".
public enum ConflictPolicy: Sendable, Hashable {
    /// Stop the operation with an error on the first conflict.
    case fail
    /// Leave the destination untouched and continue with other items.
    case skip
    /// Overwrite the destination.
    case replace
    /// Auto-rename the incoming item Windows-style: "name (2).ext".
    case keepBoth
}

public struct FileOperationFailure: Sendable, Error, LocalizedError {
    public let source: URL
    public let reason: String
    /// True when the failure is just "a newer operation superseded this one"
    /// — never worth an error sheet or a log.
    public var isCancellation: Bool

    public init(source: URL, reason: String, isCancellation: Bool = false) {
        self.source = source
        self.reason = reason
        self.isCancellation = isCancellation
    }

    public var errorDescription: String? { reason }
}

/// A step that reverses one completed item operation.
public enum UndoStep: Sendable {
    /// Move an item back to where it came from.
    case moveBack(from: URL, to: URL)
    /// Trash items that this operation created (undo of copy).
    case trashCreated([URL])
    /// Restore trashed items to their original locations.
    case restoreFromTrash([(trashURL: URL, original: URL)])
}

/// Everything needed to undo one completed operation (and redo it again).
public struct UndoRecord: Sendable {
    public let title: String
    public let steps: [UndoStep]

    public init(title: String, steps: [UndoStep]) {
        self.title = title
        self.steps = steps
    }
}

/// Result of one engine operation.
public struct OperationOutcome: Sendable {
    public var succeeded: [URL] = []
    public var skipped: [URL] = []
    public var failures: [FileOperationFailure] = []
    public var undo: UndoRecord?

    public init() {}
}

/// The file operations engine. An actor: every call runs off the main thread,
/// each item is executed with copyfile-safe FileManager calls, and the results
/// are returned as plain `Sendable` values.
///
/// Design notes (Phase 9 trunk):
/// - `move` uses `FileManager.moveItem`, which is an atomic rename on the same
///   volume and a copy+verify+delete across volumes.
/// - Conflicts default to `.keepBoth` (never silent data loss); the Explorer
///   conflict sheet ships with the progress window pass.
/// - Cancellation is cooperative: checked between items, throws
///   `CancellationError` with completed work intact.
public actor FileOperationEngine {
    public init() {}

    // MARK: - Copy

    /// A folder can't be copied into itself (recursion would try to nest
    /// forever, leaving junk trees behind).
    private static func isDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let c = candidate.standardizedFileURL.path
        let a = ancestor.standardizedFileURL.path
        return c == a || c.hasPrefix(a + "/")
    }

    /// Restores items parked by `.replace` after the follow-up operation
    /// failed — without this, a failed copy after a park leaves the user's
    /// original in the Trash with no undo record and no bookkeeping.
    private func revert(parked: [(trashURL: URL, original: URL)]) {
        let manager = FileManager.default
        for item in parked where manager.fileExists(atPath: item.trashURL.path) {
            do {
                try manager.createDirectory(
                    at: item.original.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try manager.moveItem(at: item.trashURL, to: item.original)
            } catch {
                // The parked item stays in the Trash — recoverable manually.
                DoraLog.fileOps.error("failed to restore parked original \(item.original.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Copies each source into `destinationDir`.
    public func copy(
        sources: [URL],
        to destinationDir: URL,
        policy: ConflictPolicy = .keepBoth
    ) -> OperationOutcome {
        var outcome = OperationOutcome()
        var created: [URL] = []
        var parked: [(trashURL: URL, original: URL)] = []
        var steps: [UndoStep] = []

        for source in sources {
            if Task.isCancelled {
                outcome.failures.append(FileOperationFailure(source: source, reason: "cancelled", isCancellation: true))
                break
            }
            if source.hasDirectoryPath && Self.isDescendant(destinationDir, of: source) {
                outcome.failures.append(FileOperationFailure(
                    source: source,
                    reason: "Can't copy a folder into itself."
                ))
                continue
            }
            switch resolve(source: source, in: destinationDir, policy: policy, isMove: false) {
            case .failure(let reason):
                outcome.failures.append(FileOperationFailure(source: source, reason: reason))
            case .skip:
                outcome.skipped.append(source)
            case .proceed(let target):
                do {
                    try FileManager.default.copyItem(at: source, to: target)
                    created.append(target)
                    outcome.succeeded.append(target)
                } catch {
                    outcome.failures.append(FileOperationFailure(source: source, reason: error.localizedDescription))
                }
            case .replaced(let target, let parkedItem):
                do {
                    try FileManager.default.copyItem(at: source, to: target)
                    created.append(target)
                    parked.append(parkedItem)
                    outcome.succeeded.append(target)
                } catch {
                    // The park left the user's original in the Trash —
                    // put it back before reporting the failure.
                    revert(parked: [parkedItem])
                    outcome.failures.append(FileOperationFailure(source: source, reason: error.localizedDescription))
                }
            }
        }

        if !created.isEmpty {
            // Order matters: trash the copies first, then restore anything the
            // policy parked, so the originals land back at their exact paths.
            steps.append(.trashCreated(created))
            if !parked.isEmpty { steps.append(.restoreFromTrash(parked)) }
            outcome.undo = UndoRecord(title: "Copy \(created.count) item(s)", steps: steps)
        }
        return outcome
    }

    // MARK: - Move

    /// Moves each source into `destinationDir` (atomic rename within a volume,
    /// copy+delete across volumes — `FileManager.moveItem` does both).
    public func move(
        sources: [URL],
        to destinationDir: URL,
        policy: ConflictPolicy = .keepBoth
    ) -> OperationOutcome {
        var outcome = OperationOutcome()
        var undoSteps: [UndoStep] = []
        var moved: [URL] = []
        var parked: [(trashURL: URL, original: URL)] = []

        for source in sources {
            if Task.isCancelled {
                outcome.failures.append(FileOperationFailure(source: source, reason: "cancelled", isCancellation: true))
                break
            }
            if source.hasDirectoryPath && Self.isDescendant(destinationDir, of: source) {
                outcome.failures.append(FileOperationFailure(
                    source: source,
                    reason: "Can't move a folder into itself."
                ))
                continue
            }
            switch resolve(source: source, in: destinationDir, policy: policy, isMove: true) {
            case .failure(let reason):
                outcome.failures.append(FileOperationFailure(source: source, reason: reason))
            case .skip:
                outcome.skipped.append(source)
            case .proceed(let target):
                do {
                    try FileManager.default.moveItem(at: source, to: target)
                    moved.append(target)
                    undoSteps.append(.moveBack(from: target, to: source))
                    outcome.succeeded.append(target)
                } catch {
                    outcome.failures.append(FileOperationFailure(source: source, reason: error.localizedDescription))
                }
            case .replaced(let target, let parkedItem):
                do {
                    try FileManager.default.moveItem(at: source, to: target)
                    moved.append(target)
                    undoSteps.append(.moveBack(from: target, to: source))
                    parked.append(parkedItem)
                    outcome.succeeded.append(target)
                } catch {
                    // The park left the user's original in the Trash —
                    // put it back before reporting the failure.
                    revert(parked: [parkedItem])
                    outcome.failures.append(FileOperationFailure(source: source, reason: error.localizedDescription))
                }
            }
        }

        if !moved.isEmpty {
            if !parked.isEmpty { undoSteps.append(.restoreFromTrash(parked)) }
            outcome.undo = UndoRecord(title: "Move \(moved.count) item(s)", steps: undoSteps)
        }
        return outcome
    }

    // MARK: - Trash

    /// Moves items to the Trash and records original locations so Restore
    /// works everywhere (macOS "Put Back" is Finder-private).
    public func trash(_ sources: [URL], store: TrashStore) async -> OperationOutcome {
        var outcome = OperationOutcome()
        var restoreSteps: [(trashURL: URL, original: URL)] = []

        for source in sources {
            if Task.isCancelled {
                outcome.failures.append(FileOperationFailure(source: source, reason: "cancelled", isCancellation: true))
                break
            }
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: source, resultingItemURL: &resulting)
                let trashURL = (resulting as URL?) ?? source
                restoreSteps.append((trashURL, source))
                outcome.succeeded.append(trashURL)
            } catch {
                outcome.failures.append(FileOperationFailure(source: source, reason: error.localizedDescription))
            }
        }

        if !restoreSteps.isEmpty {
            await store.record(restoreSteps)
            outcome.undo = UndoRecord(
                title: "Trash \(restoreSteps.count) item(s)",
                steps: [.restoreFromTrash(restoreSteps)]
            )
        }
        return outcome
    }

    // MARK: - Undo / Redo

    /// Applies the inverse steps of a record. Returns a record that undoes
    /// *this* operation (for redo).
    public func applyUndo(_ record: UndoRecord) -> OperationOutcome {
        var outcome = OperationOutcome()
        // Inverses collected in execution order; redo replays them REVERSED —
        // undoing [first…last] must redo [last…first] or a `.replace` park
        // pattern collapses into "(2)" renames and re-trashed originals.
        var stepInverses: [UndoStep] = []

        for step in record.steps {
            if Task.isCancelled { break }
            switch step {
            case .moveBack(let from, let to):
                do {
                    try FileManager.default.createDirectory(
                        at: to.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.moveItem(at: from, to: to)
                    stepInverses.append(.moveBack(from: to, to: from))
                } catch {
                    outcome.failures.append(FileOperationFailure(source: from, reason: error.localizedDescription))
                }

            case .trashCreated(let urls):
                var trashed: [(trashURL: URL, original: URL)] = []
                for url in urls {
                    do {
                        var resulting: NSURL?
                        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                        trashed.append(((resulting as URL?) ?? url, url))
                    } catch {
                        outcome.failures.append(FileOperationFailure(source: url, reason: error.localizedDescription))
                    }
                }
                if !trashed.isEmpty {
                    stepInverses.append(.restoreFromTrash(trashed))
                }

            case .restoreFromTrash(let pairs):
                var restored: [URL] = []
                for pair in pairs {
                    do {
                        try FileManager.default.createDirectory(
                            at: pair.original.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        let collisionFree = Self.availableDestination(
                            for: pair.original,
                            in: pair.original.deletingLastPathComponent()
                        )
                        try FileManager.default.moveItem(at: pair.trashURL, to: collisionFree)
                        restored.append(collisionFree)
                    } catch {
                        outcome.failures.append(FileOperationFailure(source: pair.trashURL, reason: error.localizedDescription))
                    }
                }
                if !restored.isEmpty {
                    stepInverses.append(.trashCreated(restored))
                }
            }
        }

        if !stepInverses.isEmpty {
            outcome.undo = UndoRecord(
                title: "Redo: \(record.title)",
                steps: stepInverses.reversed()
            )
        }
        return outcome
    }

    // MARK: - Conflict resolution

    /// Resolved conflict outcome for one source.
    private enum Resolution: Sendable {
        case proceed(URL)
        case skip
        /// Skip with an error recorded for this source.
        case failure(String)
        /// Overwrote an existing destination; the original is parked in the
        /// Trash so the operation stays undoable.
        case replaced(target: URL, parked: (trashURL: URL, original: URL))
    }

    /// Resolves the destination for one source under the policy.
    private func resolve(
        source: URL,
        in destinationDir: URL,
        policy: ConflictPolicy,
        isMove: Bool
    ) -> Resolution {
        let proposed = destinationDir.appendingPathComponent(source.lastPathComponent)
        let manager = FileManager.default

        // Self-operation guard, BEFORE any policy: without it, `.replace`
        // parks the SOURCE ITSELF in the Trash when the destination folder
        // already contains the source. Same-spot moves are Finder no-ops.
        guard proposed.standardizedFileURL != source.standardizedFileURL else {
            return .skip
        }

        guard manager.fileExists(atPath: proposed.path) else {
            return .proceed(proposed)
        }

        switch policy {
        case .fail:
            return .failure("An item named “\(source.lastPathComponent)” already exists.")
        case .skip:
            return .skip
        case .keepBoth:
            return .proceed(Self.availableDestination(for: proposed, in: destinationDir))
        case .replace:
            // Park the overwritten original in the Trash; deleting outright
            // would make the operation irreversible.
            do {
                var resulting: NSURL?
                try manager.trashItem(at: proposed, resultingItemURL: &resulting)
                let parked = (resulting as URL?) ?? proposed
                return .replaced(target: proposed, parked: (parked, proposed))
            } catch {
                return .failure(error.localizedDescription)
            }
        }
    }

    /// "name.txt" -> "name (2).txt", "(3)", … until free.
    private static func availableDestination(for proposed: URL, in directory: URL) -> URL {
        let manager = FileManager.default
        if !manager.fileExists(atPath: proposed.path) {
            return proposed
        }
        let basename = proposed.deletingPathExtension().lastPathComponent
        let ext = proposed.pathExtension

        for index in 2...9999 {
            let candidate = ext.isEmpty
                ? "\(basename) (\(index))"
                : "\(basename) (\(index)).\(ext)"
            let url = directory.appendingPathComponent(candidate)
            if !manager.fileExists(atPath: url.path) {
                return url
            }
        }
        return directory.appendingPathComponent("untitled \(UUID().uuidString)")
    }
}

/// Remembers original locations of trashed items so Restore works from any
/// window (macOS's Put Back is Finder-private). One small JSON file, written
/// atomically on every mutation — record sizes stay tiny.
public actor TrashStore {
    private struct Records: Codable {
        var originals: [String: String] = [:]  // trash path -> original path
    }

    private let url: URL
    private var cache: Records

    public init(url: URL = TrashStore.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Records.self, from: data) {
            cache = decoded
        } else {
            cache = Records()
        }
    }

    public static var defaultURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dora the Explorer", isDirectory: true)
            .appendingPathComponent("trash-records.json")
    }

    /// Writes the cache to disk right now.
    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(cache)
            try data.write(to: url, options: .atomic)
        } catch {
            DoraLog.fileOps.error("trash store save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Records one batch of (trash URL, original URL) pairs.
    public func record(_ pairs: [(trashURL: URL, original: URL)]) {
        guard !pairs.isEmpty else { return }
        for pair in pairs {
            cache.originals[pair.trashURL.path] = pair.original.path
        }
        persist()
    }

    /// Original location of a trashed item, if known.
    public func original(for trashURL: URL) -> URL? {
        guard let path = cache.originals[trashURL.path] else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// All known originals — used to build Restore-all lists.
    public func allRecords() -> [(trashURL: URL, original: URL)] {
        cache.originals.map { key, value in
            (URL(fileURLWithPath: key), URL(fileURLWithPath: value))
        }
    }

    /// Drops records whose trash URL no longer exists.
    public func prune() {
        var removed = false
        let manager = FileManager.default
        let stale = cache.originals.filter { !manager.fileExists(atPath: $0.key) }
        for key in stale.keys {
            cache.originals[key] = nil
            removed = true
        }
        if removed { persist() }
    }
}
