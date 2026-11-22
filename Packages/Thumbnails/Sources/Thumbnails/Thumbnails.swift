import Foundation

/// Placeholder surface for the thumbnail pipeline (Phase 6).
public struct ThumbnailRequest: Sendable, Hashable {
    public let itemID: String
    public let pixelSize: Int

    public init(itemID: String, pixelSize: Int) {
        self.itemID = itemID
        self.pixelSize = pixelSize
    }
}
