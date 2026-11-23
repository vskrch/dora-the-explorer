import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Thumbnails

@Suite("Thumbnail policy")
struct ThumbnailPolicyTests {
    @Test func visualTypesWantPreviews() {
        #expect(ThumbnailService.wantsPreview(contentType: .png, isDirectory: false))
        #expect(ThumbnailService.wantsPreview(contentType: .jpeg, isDirectory: false))
        #expect(ThumbnailService.wantsPreview(contentType: .mpeg4Movie, isDirectory: false))
        #expect(ThumbnailService.wantsPreview(contentType: .pdf, isDirectory: false))
        #expect(ThumbnailService.wantsPreview(contentType: UTType(filenameExtension: "wav"), isDirectory: false))
    }

    @Test func foldersAndOpaqueTypesDoNot() {
        #expect(!ThumbnailService.wantsPreview(contentType: nil, isDirectory: false))
        #expect(!ThumbnailService.wantsPreview(contentType: .png, isDirectory: true))
        #expect(!ThumbnailService.wantsPreview(contentType: .zip, isDirectory: false))
        #expect(!ThumbnailService.wantsPreview(contentType: .plainText, isDirectory: false))
    }

    @Test func requestKeysDifferByContentStampAndPixelSize() {
        let base = ThumbnailService.Request(fileID: "a-1", modificationDate: Date(timeIntervalSince1970: 100), pixelSize: 44)
        let differentPixel = ThumbnailService.Request(fileID: "a-1", modificationDate: Date(timeIntervalSince1970: 100), pixelSize: 88)
        let differentStamp = ThumbnailService.Request(fileID: "a-1", modificationDate: Date(timeIntervalSince1970: 200), pixelSize: 44)
        let differentFile = ThumbnailService.Request(fileID: "b-2", modificationDate: Date(timeIntervalSince1970: 100), pixelSize: 44)
        #expect(Set([base.key, differentPixel.key, differentStamp.key, differentFile.key]).count == 4)
    }
}
