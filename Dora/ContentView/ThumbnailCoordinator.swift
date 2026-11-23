import AppKit
import FSCore
import Thumbnails
import UniformTypeIdentifiers

/// One shared pipeline for the details view's inline previews.
///
/// Every cell request carries an identity token (the item id); deliveries
/// check it before landing, so a 120 fps scroll through a photo folder never
/// paints a stale preview into a reused cell — and cancelled work is bounded
/// by the service's concurrency cap.
@MainActor
final class ThumbnailCoordinator {
    static let shared = ThumbnailCoordinator()

    private let service = ThumbnailService()
    /// Monotonic request stamp; deliveries validate against the slot's stamp.
    private var generation = 0

    private init() {}

    /// Fills `target` for `item` — instantly from cache when possible,
    /// asynchronously from Quick Look otherwise (bounded concurrency).
    func decorate(cell: FileNameCellView, item: FileItem) {
        cell.currentToken = nil
        guard ThumbnailService.wantsPreview(contentType: item.contentType, isDirectory: item.isDirectory),
              let modified = item.modified else {
            cell.showTypeIcon(for: item)
            return
        }

        let token = nextGeneration()
        cell.currentToken = token

        let request = ThumbnailService.Request(
            fileID: item.id,
            modificationDate: modified,
            pixelSize: 44 // 22 pt rows slot × 2x pixels
        )

        Task { [weak cell] in
            if let cached = await service.cachedImage(for: request) {
                guard let cell, cell.currentToken == token else { return }
                cell.showPreview(cached)
                return
            }
            await service.thumbnail(url: item.url, request: request) { [weak cell] image in
                guard let cell, cell.currentToken == token, let image else { return }
                cell.showPreview(image)
            }
        }
    }

    /// Drops caches and cancels every QL job in flight. Called on window
    /// teardown — the last consumer of this shared pipeline went away, so no
    /// preview work for its folders should survive it.
    ///
    /// (Deliberately NOT called per navigation: the byte-costed cache is the
    /// fast path for bouncing between folders, and other windows may still be
    /// showing previews from these directories.)
    func purge() {
        generation &+= 1
        Task { await service.cancelAndPurge() }
    }

    private func nextGeneration() -> Int {
        generation &+= 1
        return generation
    }
}
