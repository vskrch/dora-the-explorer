import AppKit
import Foundation
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Byte-costed in-memory cache. `NSCache` is thread-safe and auto-evicts
/// under memory pressure — the bounded-memory story for visual previews.
final class ThumbnailCache {
    private let cache = NSCache<NSString, NSImage>()

    init(limitBytes: Int) {
        cache.totalCostLimit = limitBytes
    }

    func image(for request: ThumbnailService.Request) -> NSImage? {
        cache.object(forKey: request.key as NSString)
    }

    func store(_ image: NSImage, for request: ThumbnailService.Request) {
        let cost = max(1, request.pixelSize * request.pixelSize * 4 * 4)
        cache.setObject(image, forKey: request.key as NSString, cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

/// Thumbnail pipeline: bounded-concurrency `QLThumbnailGenerator` work with
/// per-request cancellation. Cells request by identity; the service either
/// delivers from memory cache (instant) or enqueues a QL job and delivers on
/// the main actor. Superseded requests are cancelled at the call site by
/// generation token, so a 120 fps scroll never stacks QL work.
public actor ThumbnailService {
    /// Identity of one preview slot: file id + content stamp + pixel size.
    public struct Request: Sendable, Hashable {
        public let fileID: String
        public let modificationDate: Date
        public let pixelSize: Int

        public init(fileID: String, modificationDate: Date, pixelSize: Int) {
            self.fileID = fileID
            self.modificationDate = modificationDate
            self.pixelSize = pixelSize
        }

        var key: String { "\(fileID)-\(Int(modificationDate.timeIntervalSince1970))-\(pixelSize)" }
    }

    /// Delivered on the main actor; a nil image means "no preview — keep the
    /// type icon". `versionedDelivery` is preferred: the token drops stale
    /// deliveries (the cell may have been reused).
    public typealias Delivery = @MainActor @Sendable (NSImage?) -> Void

    private let generator = QLThumbnailGenerator()
    private let cache: ThumbnailCache
    private let maxConcurrent: Int
    private var inFlight: [ThumbnailService.Request: Task<Void, Never>] = [:]
    private var queued: [(url: URL, request: Request, delivery: Delivery)] = []

    public init(cacheLimitBytes: Int = 96 * 1024 * 1024, maxConcurrent: Int = 5) {
        self.cache = ThumbnailCache(limitBytes: cacheLimitBytes)
        self.maxConcurrent = max(1, maxConcurrent)
    }

    /// Visual types that benefit from a preview row slot.
    public static func wantsPreview(contentType: UTType?, isDirectory: Bool) -> Bool {
        guard !isDirectory, let type = contentType else { return false }
        return type.conforms(to: .image)
            || type.conforms(to: .movie)
            || type.conforms(to: .video)
            || type.conforms(to: .audio)
            || type.conforms(to: .pdf)
    }

    public func cachedImage(for request: Request) -> NSImage? {
        cache.image(for: request)
    }

    /// Fire-and-forget: delivers on the main actor when ready (or never, if
    /// cancelled). Callers guard staleness with their own tokens.
    public func thumbnail(url: URL, request: Request, delivery: @escaping Delivery) {
        queued.append((url, request, delivery))
        drain()
    }

    /// Cancels everything queued and in flight and empties the caches.
    public func cancelAndPurge() {
        queued.removeAll()
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
        cache.removeAll()
    }

    private func drain() {
        while inFlight.count < maxConcurrent, let next = queued.first {
            queued.removeFirst()
            let task = Task {
                await run(url: next.url, request: next.request, delivery: next.delivery)
            }
            inFlight[next.request] = task
        }
    }

    private func run(url: URL, request: Request, delivery: @escaping Delivery) async {
        let image: NSImage? = await withCheckedContinuation { continuation in
            let qlRequest = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: request.pixelSize, height: request.pixelSize),
                scale: 2,
                representationTypes: [.thumbnail, .icon]
            )
            generator.generateBestRepresentation(for: qlRequest) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
        defer {
            inFlight[request] = nil
            drain()
        }
        if let image {
            cache.store(image, for: request)
        }
        guard image != nil else { return } // silent: caller keeps the type icon
        await MainActor.run {
            delivery(image)
        }
    }
}
