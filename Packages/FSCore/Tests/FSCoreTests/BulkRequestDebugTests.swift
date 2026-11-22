import Darwin
import Foundation
import Testing
@testable import FSCore

@Suite("Bulk request decode")
struct BulkRequestDebugTests {
    /// Enumerate via the public API and confirm every expected entry.
    @Test func enumeratesSmallDirectory() async throws {
        let fixture = try Fixture(name: "dora-req")
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

    /// THE regression test for the dead-fast-path bug: calls `getattrlistbulk`
    /// directly, hands the raw kernel buffer to the parser, and asserts every
    /// entry decoded with correct field values — no readdir fallback can
    /// mask a parser regression.
    @Test func parserDecodesRawKernelBuffer() throws {
        let fixture = try Fixture(name: "dora-bulk")
        defer { fixture.cleanup() }
        try fixture.write("alpha.txt", bytes: 10)
        try fixture.write("beta.md", bytes: 20)
        try fixture.write("gamma.swift", bytes: 30)
        _ = try fixture.directory("sub")

        let fd = open(fixture.root.path, O_RDONLY)
        #expect(fd >= 0, "open failed: \(errno)")
        defer { close(fd) }

        var attrList = BulkAttributeParser.makeAttrList()
        let bufferSize = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        let kernelEntryCount = getattrlistbulk(fd, &attrList, buffer, bufferSize, UInt64(FSOPT_REPORT_FULLSIZE))
        #expect(kernelEntryCount >= 4, "bulk call returned \(kernelEntryCount)")

        let parsed = BulkAttributeParser.parse(
            buffer: UnsafeRawBufferPointer(start: buffer, count: bufferSize),
            directory: fixture.root,
            showHidden: false
        )

        // Every entry the kernel reported was consumed (length-word stepping).
        #expect(parsed.entryCount == kernelEntryCount)
        #expect(parsed.isWellFormed)

        let byName = Dictionary(uniqueKeysWithValues: parsed.items.map { ($0.name, $0) })
        #expect(byName.count == 4, "got \(byName.keys.sorted())")
        #expect(byName["alpha.txt"]?.size == 10, "DATALENGTH decode")
        #expect(byName["beta.md"]?.size == 20, "DATALENGTH decode")
        #expect(byName["gamma.swift"]?.isDirectory == false, "OBJTYPE decode")
        #expect(byName["sub"]?.isDirectory == true, "OBJTYPE decode")
        #expect(parsed.items.allSatisfy { $0.id.contains("#") }, "FILEID decode")
        #expect(parsed.items.allSatisfy { $0.modified?.timeIntervalSinceNow ?? -999 > -120 }, "timespec decode")
    }

    /// Hard links in the same folder get name-disambiguated ids (no collapse).
    @Test func hardLinksGetDistinctIDs() async throws {
        let fixture = try Fixture(name: "dora-link")
        defer { fixture.cleanup() }
        try fixture.write("original.txt", bytes: 5)
        let original = fixture.root.appendingPathComponent("original.txt")
        let twin = fixture.root.appendingPathComponent("twin.txt")

        let linked = original.withUnsafeFileSystemRepresentation { existing -> Bool in
            guard let existing, let replicated = twin.path.withCString({ strdup($0) }) else {
                return false
            }
            defer { free(replicated) }
            return link(existing, replicated) == 0
        }
        guard linked else {
            Issue.record("could not create hard link fixture")
            return
        }

        let items = try await DirectoryEnumerator().items(in: fixture.root)
        let ids = Set(items.map(\.id))
        #expect(ids.count == items.count, "hard links collapsed to one id: \(ids)")
        #expect(Set(items.map(\.name)) == ["original.txt", "twin.txt"])
    }
}
