import Foundation
import Testing
@testable import FSCore

@Suite("DirectoryModel", .serialized)
@MainActor
struct DirectoryModelTests {
    @Test func loadsAndSortsContents() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.generateFiles(count: 20)
        _ = try fixture.directory("folder")

        let model = DirectoryModel(directory: fixture.root)
        model.reload()
        try await waitUntil { !model.isLoading && model.snapshot.totalCount == 21 }

        let names = model.items.map(\.name)
        #expect(names.first == "folder")
        #expect(names.count == 21)
    }

    @Test func changingSortRepublishesWithoutReloading() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.write("a.txt", bytes: 100)
        _ = try fixture.write("b.txt", bytes: 50)

        let model = DirectoryModel(directory: fixture.root)
        model.reload()
        try await waitUntil { !model.isLoading && model.snapshot.totalCount == 2 }

        let byName = model.items.map(\.name)
        model.settings.sortCriteria = [SortCriterion(key: .size, ascending: true)]
        try await waitUntil { model.items.map(\.name) == ["b.txt", "a.txt"] }
        #expect(byName == ["a.txt", "b.txt"])
    }

    @Test func loadErrorIsSurfaced() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("dora-missing-\(UUID().uuidString)")
        let model = DirectoryModel(directory: missing)
        model.reload()
        try await waitUntil { model.loadError != nil }
        #expect(model.snapshot.totalCount == 0)
    }

    @Test func firstBatchLatencyIsRecorded() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.generateFiles(count: 3_000)

        let model = DirectoryModel(directory: fixture.root)
        model.reload()
        try await waitUntil { model.firstBatchLatency != nil }
        #expect(model.firstBatchLatency != nil)
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("condition not met within \(timeout)s")
    }
}
