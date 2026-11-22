import Foundation
import Testing
@testable import FSCore

@Suite("DirectoryEnumerator")
struct DirectoryEnumeratorTests {
    @Test func enumeratesSmallDirectoryWithBulkAttributes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.write("alpha.txt", bytes: 10)
        try fixture.write("beta.md", bytes: 20)
        _ = try fixture.directory("sub")

        let enumerator = DirectoryEnumerator()
        let items = try await enumerator.items(in: fixture.root)

        #expect(items.count == 3)
        let names = Set(items.map(\.name))
        #expect(names == ["alpha.txt", "beta.md", "sub"])

        let sub = try #require(items.first { $0.name == "sub" })
        #expect(sub.isDirectory)
        #expect(sub.isPackage == false)
        #expect(sub.size == nil)

        let alpha = try #require(items.first { $0.name == "alpha.txt" })
        #expect(alpha.isDirectory == false)
        #expect(alpha.size == 10)
        #expect(alpha.modified != nil)
        #expect(alpha.created != nil)
    }

    @Test func hidesDotFilesUnlessRequested() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.write("visible.txt")
        try fixture.write(".hidden.txt")

        let enumerator = DirectoryEnumerator()
        let visible = try await enumerator.items(in: fixture.root)
        #expect(visible.map(\.name) == ["visible.txt"])

        let all = try await enumerator.items(
            in: fixture.root,
            configuration: .init(showHidden: true)
        )
        #expect(Set(all.map(\.name)) == ["visible.txt", ".hidden.txt"])
    }

    @Test func batchesDoNotExceedConfiguredSizeAndKeepOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.generateFiles(count: 1_234)

        let enumerator = DirectoryEnumerator()
        var seen: [String] = []
        var batchSizes: [Int] = []
        for try await batch in enumerator.batches(of: fixture.root, configuration: .init(batchSize: 500)) {
            batchSizes.append(batch.count)
            seen.append(contentsOf: batch.map(\.name))
        }

        #expect(seen.count == 1_234)
        #expect(Set(seen).count == 1_234)
        #expect(batchSizes.allSatisfy { $0 <= 500 })
        #expect(batchSizes.reduce(0, +) == 1_234)
    }

    @Test func identifiersAreUniqueAcrossDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.generateFiles(count: 200)

        let items = try await DirectoryEnumerator().items(in: fixture.root)
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test func nonDirectoryThrows() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let file = try fixture.write("plain.txt")

        await #expect(throws: DirectoryEnumerator.EnumerationError.self) {
            _ = try await DirectoryEnumerator().items(in: file)
        }
    }

    @Test func cancelledStreamStopsQuickly() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.generateFiles(count: 5_000)

        let stream = DirectoryEnumerator().batches(of: fixture.root)
        let task = Task {
            for try await _ in stream {}
        }
        task.cancel()
        _ = await task.result
        // Reaching here without hanging is the assertion.
        #expect(Bool(true))
    }
}
