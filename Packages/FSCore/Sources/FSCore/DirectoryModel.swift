import Foundation
import Observation

/// Immutable, `Sendable` snapshot the table renders from. The model swaps the
/// whole snapshot on the main actor so AppKit never reads mutated state.
public struct DirectorySnapshot: Sendable, Equatable {
    public let generation: UInt64
    public let groups: [ItemGroup]
    public let totalCount: Int

    public init(generation: UInt64, groups: [ItemGroup], totalCount: Int) {
        self.generation = generation
        self.groups = groups
        self.totalCount = totalCount
    }

    public var flatItems: [FileItem] {
        groups.flatMap(\.items)
    }

    public func indexOfItem(withID id: FileItem.ID) -> Int? {
        var running = 0
        for group in groups {
            if let offset = group.items.firstIndex(where: { $0.id == id }) {
                return running + offset
            }
            running += group.items.count
        }
        return nil
    }
}

/// Main-actor model behind the Details view.
///
/// Enumeration runs in `DirectoryEnumerator` (off-main), sorting/grouping in
/// `DirectorySorter` (off-main for large folders). Diffs from `DirectoryWatcher`
/// patch the loaded item set and re-sort incrementally, preserving selection and
/// scroll anchor because rows are addressed by item id, not row index.
@MainActor
@Observable
public final class DirectoryModel {
    public struct ViewSettings: Sendable, Hashable, Codable {
        public var sortCriteria: [SortCriterion]
        public var grouping: GroupingKey
        /// Column identifiers in display order (Details view).
        public var columns: [String]
        public var showHidden: Bool

        public init(
            sortCriteria: [SortCriterion] = [.nameAscending],
            grouping: GroupingKey = .none,
            columns: [String] = ["name", "dateModified", "type", "size"],
            showHidden: Bool = false
        ) {
            self.sortCriteria = sortCriteria
            self.grouping = grouping
            self.columns = columns
            self.showHidden = showHidden
        }
    }

    public private(set) var snapshot = DirectorySnapshot(generation: 0, groups: [], totalCount: 0)
    public private(set) var isLoading = false
    public private(set) var loadError: (any Error)?
    public private(set) var firstBatchLatency: Duration?

    /// Fired on the main actor after every published snapshot change
    /// (first batch, completed load, live-update regroup).
    public var onPublish: (@MainActor () -> Void)?

    public var directory: URL { didSet { reload() } }
    public var settings: ViewSettings {

        didSet {
            guard settings != oldValue else { return }
            if settings.showHidden != oldValue.showHidden {
                // Hidden items are excluded at enumeration time: changing the
                // flag needs a fresh pass to add/remove them.
                reload()
            } else {
                regroup()
            }
        }
    }

    private let enumerator = DirectoryEnumerator()
    private let sorter: @Sendable ([FileItem], [SortCriterion], GroupingKey) -> [ItemGroup]
    private var itemsByID: [FileItem.ID: FileItem] = [:]
    private var loadTask: Task<Void, Never>?
    private var watcher: DirectoryWatcher?
    private var generation: UInt64 = 0

    public init(
        directory: URL,
        settings: ViewSettings = ViewSettings(),
        sorter: @escaping @Sendable ([FileItem], [SortCriterion], GroupingKey) -> [ItemGroup] = { items, criteria, grouping in
            FileGrouper.groups(for: items, settings: .init(key: grouping, sortCriteria: criteria))
        }
    ) {
        self.directory = directory
        self.settings = settings
        self.sorter = sorter
    }

    deinit {
        // Load and watch tasks are cancelled by `reload()` / `stopWatching()` on
        // the main actor; a deinit from another isolation domain can't touch them.
    }

    // MARK: - Loading

    public func reload() {
        loadTask?.cancel()
        watcher?.stop()
        watcher = nil
        itemsByID.removeAll(keepingCapacity: true)
        loadError = nil
        isLoading = true
        publish()

        let directory = self.directory
        let settings = self.settings
        let enumerator = self.enumerator
        let sorter = self.sorter

        loadTask = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            var loaded: [FileItem] = []
            var publishedFirstBatch = false
            do {
                let stream = enumerator.batches(
                    of: directory,
                    configuration: .init(batchSize: 500, showHidden: settings.showHidden)
                )
                for try await batch in stream {
                    if Task.isCancelled { return }
                    loaded.append(contentsOf: batch)

                    if !publishedFirstBatch {
                        publishedFirstBatch = true
                        // Paint the first batch immediately: sort + group
                        // off-main, then publish the Sendable result.
                        let prepared = await Self.prepare(loaded, settings)
                        guard let self, !Task.isCancelled else { return }
                        self.itemsByID = prepared.index
                        self.firstBatchLatency = clock.now - start
                        self.publish(groups: prepared.groups)
                    }
                }
                guard let self, !Task.isCancelled else { return }
                let prepared = await Self.prepare(loaded, settings)
                self.itemsByID = prepared.index
                self.isLoading = false
                self.publish(groups: prepared.groups)
                self.startWatching()
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.loadError = error
                self.isLoading = false
                self.publish()
                DoraLog.fsCore.error("load failed for \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Sort, group and index off the main actor for any directory size.
    private static func prepare(
        _ items: [FileItem],
        _ settings: ViewSettings
    ) async -> (groups: [ItemGroup], index: [FileItem.ID: FileItem]) {
        await Task.detached(priority: .userInitiated) {
            (
                FileGrouper.groups(
                    for: items,
                    settings: .init(key: settings.grouping, sortCriteria: settings.sortCriteria)
                ),
                Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            )
        }.value
    }

    // MARK: - Lifecycle

    /// Cancels in-flight enumeration and stops the FSEvents watcher. Called
    /// when a tab or window goes away, so no watcher keeps shipping disk
    /// events into a dead view.
    public func cancelLoads() {
        loadTask?.cancel()
        loadTask = nil
        watcher?.stop()
        watcher = nil
    }

    // MARK: - Live updates

    private func startWatching() {
        watcher?.stop()
        let directory = self.directory
        let watcher = DirectoryWatcher(directory: directory) { [weak self] change in
            Task { @MainActor [weak self] in
                self?.apply(change)
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    private func apply(_ change: DirectoryChange) {
        switch change.kind {
        case .rescan:
            reload()
        case .inserted(let names), .removed(let names), .modified(let names):
            guard !names.isEmpty else { return }
            // Names are cheap to resolve; a full metadata refresh happens anyway
            // for the affected entries only, keeping the rest of the snapshot.
            let toRefresh = Set(names)
            Task { [weak self] in
                guard let self else { return }
                await self.refresh(names: toRefresh)
            }
        case .renamed:
            reload()
        }
    }

    private func refresh(names: Set<String>) async {
        let directory = self.directory
        let showHidden = settings.showHidden
        let resolved: [FileItem] = await Task.detached(priority: .utility) {
            var result: [FileItem] = []
            for name in names {
                let url = directory.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
                if let item = try? FileItem(url: url) {
                    if showHidden || !item.isHidden {
                        result.append(item)
                    }
                }
            }
            return result
        }.value

        guard !Task.isCancelled else { return }
        let existingNames = Set(snapshot.flatItems.map(\.name))
        for name in names where !resolved.contains(where: { $0.name == name }) {
            if existingNames.contains(name) { // deleted or renamed away
                itemsByID = itemsByID.filter { $0.value.name != name }
            }
        }
        for item in resolved {
            itemsByID[item.id] = item
        }
        regroup()
    }

    private func regroup() {
        let items = Array(itemsByID.values)
        let criteria = settings.sortCriteria
        let grouping = settings.grouping
        let sorter = self.sorter

        if items.count > DirectorySorter.offMainThreshold {
            Task { [weak self] in
                let groups = await Task.detached(priority: .userInitiated) {
                    sorter(items, criteria, grouping)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.publish(groups: groups)
            }
        } else {
            publish(groups: sorter(items, criteria, grouping))
        }
    }

    // MARK: - Snapshot

    private func publish(groups: [ItemGroup]? = nil) {
        generation &+= 1
        let resolvedGroups = groups ?? snapshot.groups
        snapshot = DirectorySnapshot(
            generation: generation,
            groups: resolvedGroups,
            totalCount: itemsByID.count
        )
        onPublish?()
    }

    // MARK: - Introspection for the UI

    public var items: [FileItem] { snapshot.flatItems }

    public func item(withID id: FileItem.ID) -> FileItem? {
        itemsByID[id]
    }

    /// Sums file sizes for a selection.Folders report nil (`FileItem.size`), so
    /// they contribute nothing — matching Explorer's status bar for mixed selections.
    public func size(ofIDs ids: Set<FileItem.ID>) -> Int64 {
        var total: Int64 = 0
        for id in ids { total += itemsByID[id]?.size ?? 0 }
        return total
    }

    /// Total bytes of a selection, computed off-main for large sets.
    public func totalSize() async -> Int64 {
        let sizes = items.compactMap(\.size)
        return sizes.reduce(0, +)
    }
}
