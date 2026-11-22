import Foundation
import Testing
@testable import FSCore

@Suite("DirectoryEnumerator performance", .serialized, .tags(.performance))
struct DirectoryEnumeratorPerformanceTests {
    /// Budget: first batch for a 100k-file directory under 100 ms on Apple Silicon.
    @Test func firstBatchOf100kFilesUnderBudget() async throws {
        let fixture = try Fixture(name: "dora-perf")
        defer { fixture.cleanup() }
        try fixture.generateFiles(count: 100_000)

        let enumerator = DirectoryEnumerator()
        let root = fixture.root
        let clock = ContinuousClock()

        let measurement = try await Task.detached { () -> (first: Duration, total: Duration) in
            let start = clock.now
            var first: Duration?
            for try await _ in enumerator.batches(of: root) {
                if first == nil { first = clock.now - start }
            }
            return (first ?? .zero, clock.now - start)
        }.value

        let firstMs = Double(measurement.first.components.attoseconds) / 1e15
            + Double(measurement.first.components.seconds) * 1000
        let totalMs = Double(measurement.total.components.attoseconds) / 1e15
            + Double(measurement.total.components.seconds) * 1000

        print(String(format: "[perf] 100k first batch: %.1f ms, full enumeration: %.1f ms", firstMs, totalMs))
        #expect(firstMs > 0)
        #expect(firstMs < 100, "first batch took \(firstMs) ms (budget 100 ms)")
    }
}

extension Tag {
    @Tag static var performance: Self
}
