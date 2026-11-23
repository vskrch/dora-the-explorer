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
///
/// Concurrency accounting: one dictionary slot per *running job* (UUID-keyed,
/// not request-keyed) so identical requests can never overcount or evict each
/// other's bookkeeping. A duplicate request while its job is queued/running
/// joins a waiters list instead of starting a second QL generation —
/// re-decoration while scrolling past the same item is the common case.
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
    /// type icon". Callers guard staleness with their own tokens.
    public typealias Delivery = @MainActor @Sendable (NSImage?) -> Void

    /// One running QL job. `qlRequest` is set synchronously when generation
    /// starts so `cancelAndPurge` can stop the actual QL work, not merely the
    /// Swift task around it.
    private final class InFlight {
        let request: Request
        var task: Task<Void, Never>?
        var qlRequest: QLThumbnailGenerator.Request?

        init(request: Request) {
            self.request = request
        }
    }

    private let generator = QLThumbnailGenerator()
    private let cache: ThumbnailCache
    private let maxConcurrent: Int
    private var inFlight: [UUID: InFlight] = [:]
    private var queued: [(url: URL, request: Request, delivery: Delivery)] = []
    /// Deliveries for requests whose job is already queued or running.
    private var waiters: [Request: [Delivery]] = [:]

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
        // A job for the same identity is already queued or running: join its
        // waiters instead of stacking duplicate QL work.
        if inFlight.values.contains(where: { $0.request == request })
            || queued.contains(where: { $0.request == request }) {
            waiters[request, default: []].append(delivery)
            return
        }
        queued.append((url, request, delivery))
        drain()
    }

    /// Cancels everything queued and in flight — including the underlying QL
    /// requests — and empties the cache.
    public func cancelAndPurge() {
        queued.removeAll()
        for job in inFlight.values {
            job.task?.cancel()
            if let qlRequest = job.qlRequest {
                generator.cancel(qlRequest)
            }
        }
        inFlight.removeAll()
        waiters.removeAll()
        cache.removeAll()
    }

    private func drain() {
        while inFlight.count < maxConcurrent, let next = queued.first {
            queued.removeFirst()
            let jobID = UUID()
            // The task closure captures only the id: the bookkeeping slot and
            // the task never reference each other directly.
            let job = InFlight(request: next.request)
            inFlight[jobID] = job
            job.task = Task {
                await run(jobID: jobID, url: next.url, request: next.request, delivery: next.delivery)
            }
        }
    }

    private func run(jobID: UUID, url: URL, request: Request, delivery: @escaping Delivery) async {
        let qlRequest = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: request.pixelSize, height: request.pixelSize),
            scale: 2,
            representationTypes: [.thumbnail, .icon]
        )
        inFlight[jobID]?.qlRequest = qlRequest

        let image: NSImage? = await withCheckedContinuation { continuation in
            generator.generateBestRepresentation(for: qlRequest) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }

        defer {
            inFlight[jobID] = nil
            waiters[request] = nil
            drain()
        }

        // Purged while this job ran: neither cache nor UI may receive the
        // result — the cache would instantly re-pollute after a purge.
        if Task.isCancelled { return }
        guard let image else { return } // silent: caller keeps the type icon
        cache.store(image, for: request)
        let extra = waiters[request] ?? []
        await MainActor.run {
            delivery(image)
            for waiter in extra { waiter(image) }
        }
    }
}
