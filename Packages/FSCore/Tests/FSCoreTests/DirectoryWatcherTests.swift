import Foundation
import Testing
@testable import FSCore

@Suite("DirectoryWatcher", .serialized)
struct DirectoryWatcherTests {
    @Test func detectsCreateDeleteAndRename() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let box = ChangeBox()
        let watcher = DirectoryWatcher(directory: fixture.root) { change in
            box.append(change)
        }
        watcher.start()
        defer { watcher.stop() }

        // Give the stream a moment to attach.
        try await Task.sleep(for: .milliseconds(200))

        _ = try fixture.write("created.txt")
        let sawCreate = await waitUntil(timeout: 1.0) { box.mentions("created.txt") }
        #expect(sawCreate, "watcher missed create within 1 s: \(box.snapshot)")

        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("created.txt"))
        let sawDelete = await waitUntil(timeout: 1.0) {
            box.snapshot.contains { $0.containsRemoval(of: "created.txt") }
        }
        #expect(sawDelete, "watcher missed delete within 1 s: \(box.snapshot)")

        _ = try fixture.write("renamed-source.txt")
        try await Task.sleep(for: .milliseconds(250))
        try FileManager.default.moveItem(
            at: fixture.root.appendingPathComponent("renamed-source.txt"),
            to: fixture.root.appendingPathComponent("renamed-destination.txt")
        )
        let sawRename = await waitUntil(timeout: 1.0) {
            box.snapshot.contains { change in
                if case .rescan = change.kind { return true }
                return change.containsRemoval(of: "renamed-source")
                    || change.mentions("renamed-destination.txt")
            }
        }
        #expect(sawRename, "watcher missed rename within 1 s: \(box.snapshot)")
    }

    @Test func stopsWithoutCrash() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let watcher = DirectoryWatcher(directory: fixture.root) { _ in }
        watcher.start()
        watcher.stop()
        watcher.stop()
    }

    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return predicate()
    }
}

final class ChangeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DirectoryChange] = []

    func append(_ change: DirectoryChange) {
        lock.lock()
        storage.append(change)
        lock.unlock()
    }

    var snapshot: [DirectoryChange] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func mentions(_ name: String) -> Bool {
        snapshot.contains { $0.mentions(name) }
    }
}

extension DirectoryChange {
    func mentions(_ name: String) -> Bool {
        switch kind {
        case .inserted(let names), .removed(let names), .modified(let names):
            return names.contains(name)
        case .renamed(let from, let to):
            return from.contains(name) || to.contains(name)
        case .rescan:
            return true
        }
    }

    func containsRemoval(of name: String) -> Bool {
        switch kind {
        case .removed(let names):
            return names.contains(name)
        case .rescan:
            return true
        default:
            return false
        }
    }
}
