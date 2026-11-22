import AppKit
import Darwin
import Foundation

/// Mounted volume summary for the navigation pane and status surfaces.
public struct VolumeInfo: Sendable, Hashable, Identifiable {
    public let id: String
    public let url: URL
    public let name: String
    public let fileSystem: String
    public let capacity: Int64?
    public let available: Int64?
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let isNetwork: Bool
    public let isInternal: Bool
    public let isReadOnly: Bool

    public var usedFraction: Double? {
        guard let capacity, capacity > 0, let available else { return nil }
        return 1 - (Double(available) / Double(capacity))
    }

    public var isLowSpace: Bool {
        (usedFraction ?? 0) >= 0.9
    }
}

/// Lists mounted volumes and observes mount/unmount.
public final class VolumeService: @unchecked Sendable {
    private let keys: [URLResourceKey] = [
        .volumeNameKey,
        .volumeIsRemovableKey,
        .volumeIsEjectableKey,
        .volumeIsLocalKey,
        .volumeIsInternalKey,
        .volumeIsReadOnlyKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeURLForRemountingKey,
    ]

    public init() {}

    /// All mounted volumes that expose a user-facing root, internal first.
    public nonisolated func mountedVolumes() -> [VolumeInfo] {
        assertNotMainThreadForIO()
        let fileSystems = MountTable.fileSystemTypes()

        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        var volumes: [VolumeInfo] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let name = values.volumeName ?? url.lastPathComponent
            let isLocal = values.volumeIsLocal ?? true
            let fsType = fileSystems[url.path] ?? "Unknown"
            volumes.append(
                VolumeInfo(
                    id: url.path,
                    url: url,
                    name: name,
                    fileSystem: fsType,
                    capacity: values.volumeTotalCapacity.map(Int64.init),
                    available: values.volumeAvailableCapacityForImportantUsage,
                    isRemovable: values.volumeIsRemovable ?? false,
                    isEjectable: values.volumeIsEjectable ?? false,
                    isNetwork: !isLocal,
                    isInternal: values.volumeIsInternal ?? false,
                    isReadOnly: values.volumeIsReadOnly ?? false
                )
            )
        }
        return volumes.sorted { lhs, rhs in
            if lhs.isInternal != rhs.isInternal { return lhs.isInternal }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Emits the current volume list immediately, then on every mount/unmount/rename.
    public nonisolated func volumeChanges() -> AsyncStream<[VolumeInfo]> {
        AsyncStream { continuation in
            let initial = Task.detached(priority: .utility) {
                continuation.yield(VolumeService().mountedVolumes())
            }

            let center = NSWorkspace.shared.notificationCenter
            let names: [Notification.Name] = [
                NSWorkspace.didMountNotification,
                NSWorkspace.didUnmountNotification,
                NSWorkspace.didRenameVolumeNotification,
            ]
            let tokens = ObserverBag(names.map { name in
                center.addObserver(forName: name, object: nil, queue: nil) { _ in
                    Task.detached(priority: .utility) {
                        continuation.yield(VolumeService().mountedVolumes())
                    }
                }
            })

            continuation.onTermination = { _ in
                initial.cancel()
                for token in tokens.tokens {
                    center.removeObserver(token)
                }
            }
        }
    }

    /// Ejects a volume. The result callback runs on a background queue.
    public nonisolated func eject(_ volume: VolumeInfo, completion: @escaping @Sendable ((any Error)?) -> Void) {
        assertNotMainThreadForIO()
        FileManager.default.unmountVolume(
            at: volume.url,
            options: [.allPartitionsAndEjectDisk, .withoutUI]
        ) { error in
            if let error {
                FenestraLog.fsCore.error(
                    "eject failed for \(volume.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            completion(error)
        }
    }
}

/// Filesystem type per mount point, read from `getmntinfo(3)`.
private enum MountTable {
    static func fileSystemTypes() -> [String: String] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [:] }

        var result: [String: String] = [:]
        result.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let entry = buffer.advanced(by: index).pointee
            let type = withUnsafeBytes(of: entry.f_fstypename) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let mountPoint = withUnsafeBytes(of: entry.f_mntonname) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            result[mountPoint] = type
        }
        return result
    }
}
