import Testing
@testable import Thumbnails

@Test func packageLoads() {
    #expect(ThumbnailRequest(itemID: "a", pixelSize: 128).pixelSize == 128)
}
