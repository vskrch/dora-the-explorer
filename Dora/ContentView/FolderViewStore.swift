import Foundation
import FSCore

/// Remembers how each folder was last viewed: sort, grouping, columns,
/// "show hidden". Windows-style per-folder memory, persisted as one JSON file
/// keyed by directory path. Path keys keep the store trivially portable;
/// volume/fileID keys arrive with the settings database (Phase 16).
@MainActor
final class FolderViewStore {
    struct Entry: Codable, Equatable {
        var sortCriteria: [SortCriterion]?
        var grouping: GroupingKey?
        var columns: [String]?
        var columnWidths: [String: Double]?
        var showHidden: Bool?
    }

    private struct Store: Codable {
        var entries: [String: Entry]
    }

    private var cache: [String: Entry]
    private let url: URL
    private let queue = DispatchQueue(label: "com.dorasoft.dora.folderviews", qos: .utility)
    private var saveItem: DispatchWorkItem?

    init(url: URL = FolderViewStore.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let store = try? JSONDecoder().decode(Store.self, from: data) {
            cache = store.entries
        } else {
            cache = [:]
        }
    }

    static var defaultURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dora the Explorer", isDirectory: true)
            .appendingPathComponent("folder-views.json")
    }

    func entry(for directory: URL) -> Entry? {
        cache[directory.standardizedFileURL.path]
    }

    func save(_ entry: Entry, for directory: URL) {
        let key = directory.standardizedFileURL.path
        cache[key] = entry
        schedulePersist()
    }

    func removeEntry(for directory: URL) {
        cache[directory.standardizedFileURL.path] = nil
        schedulePersist()
    }

    /// One entry per folder the user actually configured; kicked oldest-first.
    func prune(maxEntries: Int = 500) {
        guard cache.count > maxEntries else { return }
        let drop = cache.count - maxEntries
        let survivors = cache
            .sorted(by: { $0.key < $1.key })
            .dropFirst(drop)
            .map { ($0.key, $0.value) }
        cache = Dictionary(uniqueKeysWithValues: survivors)
        schedulePersist()
    }

    /// Writes the cache to disk right now (used by tests and termination paths).
    func flushNow() {
        saveItem?.cancel()
        saveItem = nil
        FolderViewStore.persist(cache, to: url)
    }

    private func schedulePersist() {
        saveItem?.cancel()
        let snapshot = cache
        let url = self.url
        let item = DispatchWorkItem { Self.persist(snapshot, to: url) }
        saveItem = item
        queue.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private static func persist(_ entries: [String: Entry], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(Store(entries: entries))
            try data.write(to: url, options: .atomic)
        } catch {
            DoraLog.ui.error("folder view store save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
