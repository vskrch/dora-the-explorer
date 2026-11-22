import Foundation
import Testing
@testable import FSCore

@Suite("Bulk request decode")
struct BulkRequestDebugTests {
    @Test func parsesAllEntriesOfSmallDirectory() async throws {
        let fixture = try Fixture(name: "fenestra-req")
        defer { fixture.cleanup() }
        try fixture.write("alpha.txt", bytes: 10)
        try fixture.write("beta.md", bytes: 20)
        _ = try fixture.directory("sub")

        let items = try await DirectoryEnumerator().items(in: fixture.root)
        #expect(Set(items.map(\.name)) == ["alpha.txt", "beta.md", "sub"])
        let sub = try #require(items.first { $0.name == "sub" })
        #expect(sub.isDirectory)
        let alpha = try #require(items.first { $0.name == "alpha.txt" })
        #expect(alpha.size == 10)
        #expect(alpha.modified != nil)
    }
}
