import Foundation
import Testing
import FileOps

@Suite("File operation engine")
struct FileOperationEngineTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fileops-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFile(_ dir: URL, _ name: String, content: String = "x") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func copyCreatesItemsAndUndoRemovesThem() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeFile(dir, "a.txt", content: "hello")
        let destination = dir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let engine = FileOperationEngine()
        let outcome = await engine.copy(sources: [source], to: destination)
        let target = destination.appendingPathComponent("a.txt")
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(outcome.succeeded.count == 1)
        #expect(outcome.failures.isEmpty)

        let undo = try #require(outcome.undo)
        let undoOutcome = await engine.applyUndo(undo)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(undoOutcome.failures.isEmpty)

        // Redo brings it back (from the Trash restore).
        if let redo = undoOutcome.undo {
            _ = await engine.applyUndo(redo)
            #expect(FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test func keepBothRenamesConflictsWindowsStyle() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try makeFile(dir, "seed-dest.txt", content: "unused")
        let destination = dir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try makeFile(destination, "notes.txt", content: "original")
        let sourceDir = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let source = try makeFile(sourceDir, "notes.txt", content: "new")

        let engine = FileOperationEngine()
        let outcome = await engine.copy(sources: [source], to: destination, policy: .keepBoth)
        #expect(outcome.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("notes (2).txt").path))
        let kept = try String(contentsOf: destination.appendingPathComponent("notes.txt"), encoding: .utf8)
        #expect(kept == "original")
    }

    @Test func skipPolicyLeavesDestinationIntact() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try makeFile(destination, "a.txt", content: "dest")
        let source = try makeFile(dir, "a.txt", content: "src")

        let engine = FileOperationEngine()
        let outcome = await engine.copy(sources: [source], to: destination, policy: .skip)
        #expect(outcome.succeeded.isEmpty)
        #expect(outcome.skipped.contains(source))
        let kept = try String(contentsOf: destination.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(kept == "dest")
    }

    @Test func replaceParksOriginalInTrashAndUndoRestoresIt() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try makeFile(destination, "a.txt", content: "old")
        let source = try makeFile(dir, "a.txt", content: "new")

        let engine = FileOperationEngine()
        let outcome = await engine.copy(sources: [source], to: destination, policy: .replace)
        let replaced = try String(contentsOf: destination.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(replaced == "new")
        #expect(outcome.failures.isEmpty)

        let undo = try #require(outcome.undo)
        _ = await engine.applyUndo(undo)
        let restored = try String(contentsOf: destination.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(restored == "old")
    }

    @Test func moveRelocatesAndUndoMovesBack() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = try makeFile(dir, "mv.txt", content: "data")

        let engine = FileOperationEngine()
        let outcome = await engine.move(sources: [source], to: destination)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("mv.txt").path))

        let undo = try #require(outcome.undo)
        let undoOutcome = await engine.applyUndo(undo)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(undoOutcome.failures.isEmpty)
    }

    @Test func trashRecordsOriginalsAndUndoRestores() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TrashStore(url: dir.appendingPathComponent("trash.json"))
        let file = try makeFile(dir, "gone.txt", content: "bye")
        let fileTrashPath = file.path

        let engine = FileOperationEngine()
        let outcome = await engine.trash([file], store: store)
        #expect(!FileManager.default.fileExists(atPath: fileTrashPath))
        #expect(outcome.succeeded.count == 1)

        let trashURL = try #require(outcome.succeeded.first)
        let original = await store.original(for: trashURL)
        #expect(original?.path == fileTrashPath)

        let undo = try #require(outcome.undo)
        _ = await engine.applyUndo(undo)
        #expect(FileManager.default.fileExists(atPath: fileTrashPath))
        let restored = try String(contentsOf: URL(fileURLWithPath: fileTrashPath), encoding: .utf8)
        #expect(restored == "bye")
    }

    @Test func copyIntoDirectoryWithSameSubfolderReportsConflictFail() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // destination dir is inside the source dir; copying dir into itself
        // must not recurse or hang — either succeed or record a clear failure.
        let source = dir.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try makeFile(source, "inner.txt")

        let engine = FileOperationEngine()
        let outcome = await engine.copy(sources: [source], to: source, policy: .keepBoth)
        #expect(!outcome.failures.isEmpty || !outcome.succeeded.isEmpty)
    }
}

@Suite("Trash store")
struct TrashStoreTests {
    @Test func recordPersistsAcrossReopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trash-store-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trash-origin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = TrashStore(url: url)
        await store.record([(tempDir, URL(fileURLWithPath: "/Users/x/original.txt"))])

        let reopened = TrashStore(url: url)
        let original = await reopened.original(for: tempDir)
        #expect(original == URL(fileURLWithPath: "/Users/x/original.txt"))
        let all = await reopened.allRecords()
        #expect(all.count == 1)
    }

    @Test func pruneDropsVanishedEntries() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trash-store-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let existing = FileManager.default.temporaryDirectory
            .appendingPathComponent("still-here-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: existing) }

        let store = TrashStore(url: url)
        await store.record([
            (existing, URL(fileURLWithPath: "/Users/x/keep.txt")),
            (URL(fileURLWithPath: "/nonexistent/trash/path"), URL(fileURLWithPath: "/Users/x/drop.txt")),
        ])

        await store.prune()
        let all = await store.allRecords()
        #expect(all.count == 1)
        #expect(all.first?.original == URL(fileURLWithPath: "/Users/x/keep.txt"))
    }
}
