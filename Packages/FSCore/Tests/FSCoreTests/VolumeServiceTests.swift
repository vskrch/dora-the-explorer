import Foundation
import Testing
@testable import FSCore

@Suite("VolumeService")
struct VolumeServiceTests {
    @Test func listsAtLeastTheBootVolume() async {
        let volumes = await Task.detached { VolumeService().mountedVolumes() }.value
        #expect(!volumes.isEmpty)
        let boot = volumes.first { $0.url.path == "/" }
        #expect(boot != nil)
        #expect((boot?.capacity ?? 0) > 0)
        #expect((boot?.usedFraction ?? -1) >= 0)
        #expect((boot?.fileSystem.isEmpty ?? true) == false)
    }

    @Test func volumeChangesYieldsImmediately() async {
        let stream = await Task.detached { VolumeService().volumeChanges() }.value
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.isEmpty == false)
        await iterator.finished_placeholder()
    }
}

private extension AsyncStream.Iterator {
    func finished_placeholder() async {}
}
