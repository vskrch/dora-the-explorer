import Foundation
import Observation

/// Immutable, `Sendable` snapshot the table renders from. The model swaps the
/// whole snapshot on the main actor so AppKit never reads mutated state.
///
/// Memory contract: `items` is the single owner of every `FileItem` — the
/// identity map is an 8-byte-per-row index. Groups reference IDs only.
public struct DirectorySnapshot: Sendable, Equatable {
    public let generation: UInt64
    public let groups: [ItemGroup]
    /// The one and only copy of the loaded items, enumeration order.
    public let items: [FileItem]
    /// id → index into `items`.
    public let identity: [FileItem.ID: Int]
    public let totalCount: Int

    public init(
        generation: UInt64,
        groups: [ItemGroup],
        items: [FileItem],
        identity: [FileItem.ID: Int]
    ) {
        self.generation = generation
        self.groups = groups
        self.items = items
        self.identity = identity
        self.totalCount = items.count
    }

    /// Convenience for tests (groups referencing externally owned items).
    public init(generation: UInt64, groups: [ItemGroup], items: [FileItem]) {
        let identity = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.init(generation: generation, groups: groups, items: items, identity: identity)
    }

    /// Small empty snapshot.
    public static let empty = DirectorySnapshot(
        generation: 0, groups: [], items: [], identity: [:]
    )

    /// The single item-copy lookup every view uses.
    public func item(withID id: FileItem.ID) -> FileItem? {
        guard let index = identity[id], items.indices.contains(index) else { return nil }
        return items[index]
    }

    /// Items in display (grouped/sorted) order.
    public var flatItems: [FileItem] {
        groups.flatMap { group in
            group.ids.compactMap { id in item(withID: id) }
        }
    }

    public func indexOfItem(withID id: FileItem.ID) -> Int? {
        var running = 0
        for group in groups {
            if let offset = group.ids.firstIndex(of: id) {
                return running + offset
            }
            running += group.ids.count
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

    public private(set) var snapshot = DirectorySnapshot.empty
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
    /// Single owner of every loaded item value.
    private var currentItems: [FileItem] = []
    /// id → index into `currentItems`; patched in O(k) on diffs.
    private var currentIdentity: [FileItem.ID: Int] = [:]
    private var loadTask: Task<Void, Never>?
    /// In-flight watcher refreshes — cancelled alongside loads so a
    /// superseded directory never mutates its replacement's listing.
    private var refreshTasks: [Task<Void, Never>] = []
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
        currentItems.removeAll(keepingCapacity: true)
        currentIdentity.removeAll(keepingCapacity: true)
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
                        guard let self, !Task.isCancelled else { return }
                        // Paint the first batch immediately: sort + group
                        // off-main with the CURRENT settings (users can change
                        // sort mid-load; stale criteria would be re-imposed by
                        // this publish).
                        let freshSettings = self.settings
                        let prepared = await Self.prepare(loaded, freshSettings, sorter: sorter)
                        guard !Task.isCancelled else { return }
                        self.currentItems = prepared.items
                        self.currentIdentity = prepared.identity
                        self.firstBatchLatency = clock.now - start
                        self.publish(groups: prepared.groups)
                    }
                }
                guard let self, !Task.isCancelled else { return }
                let freshEndSettings = self.settings
                let prepared = await Self.prepare(loaded, freshEndSettings, sorter: sorter)
                self.currentItems = prepared.items
                self.currentIdentity = prepared.identity
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

    /// Sort and group off the main actor for any directory size. Returns the
    /// single item array plus its identity map — one copy, referenced by ids.
    private static func prepare(
        _ items: [FileItem],
        _ settings: ViewSettings,
        sorter: @escaping @Sendable ([FileItem], [SortCriterion], GroupingKey) -> [ItemGroup]
    ) async -> (groups: [ItemGroup], items: [FileItem], identity: [FileItem.ID: Int]) {
        await Task.detached(priority: .userInitiated) {
            let identity = Dictionary(
                items.enumerated().map { ($1.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            return (
                sorter(items, settings.sortCriteria, settings.grouping),
                items,
                identity
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
        refreshTasks.forEach { $0.cancel() }
        refreshTasks.removeAll()
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
            let eventDirectory = directory
            let task = Task { [weak self] in
                guard let self else { return }
                await self.refresh(names: toRefresh, for: eventDirectory)
            }
            refreshTasks.removeAll { $0.isCancelled }
            refreshTasks.append(task)
        case .renamed:
            reload()
        }
    }

    private func refresh(names: Set<String>, for eventDirectory: URL) async {
        // Freshness gate: if the model navigated away while the detached
        // resolve ran, these names belong to the wrong folder — drop them.
        guard eventDirectory == directory else { return }

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

        var structureChanged = false
        // One pass, not one scan per name: a mass event (git checkout, bulk
        // delete) can carry thousands of names, and per-name `firstIndex`
        // made that O(k·n) ON THE MAIN ACTOR. Filter once, rebuild identity
        // in the same pass, then merge the (O(n), single-alloc) result.
        let resolvedNames = Set(resolved.map(\.name))
        let missingNames = names.subtracting(resolvedNames)
        if !missingNames.isEmpty {
            var kept: [FileItem] = []
            kept.reserveCapacity(currentItems.count - missingNames.count)
            var keptIdentity: [FileItem.ID: Int] = [:]
            keptIdentity.reserveCapacity(currentItems.count - missingNames.count)
            for item in currentItems where !missingNames.contains(item.name) {
                keptIdentity[item.id] = kept.count
                kept.append(item)
            }
            for (id, index) in keptIdentity {
                currentIdentity[id] = index
            }
            for item in currentItems where missingNames.contains(item.name) {
                currentIdentity[item.id] = nil
            }
            currentItems = kept
            structureChanged = true
        }

        for item in resolved {
            if let index = currentIdentity[item.id] {
                currentItems[index] = item // in-place metadata refresh
            } else {
                currentIdentity[item.id] = currentItems.count
                currentItems.append(item)
                structureChanged = true
            }
        }

        if structureChanged || !resolved.isEmpty {
            regroup()
        }
    }

    private func regroup() {
        let items = currentItems
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
            items: currentItems,
            identity: currentIdentity
        )
        onPublish?()
    }

    // MARK: - Introspection for the UI

    public var items: [FileItem] { snapshot.flatItems }

    public func item(withID id: FileItem.ID) -> FileItem? {
        snapshot.item(withID: id)
    }

    /// Sums file sizes for a selection. Folders report nil (`FileItem.size`), so
    /// they contribute nothing — matching Explorer's status bar for mixed selections.
    public func size(ofIDs ids: Set<FileItem.ID>) -> Int64 {
        var total: Int64 = 0
        for id in ids { total += snapshot.item(withID: id)?.size ?? 0 }
        return total
    }

    /// Total bytes of a selection, computed off-main for large sets.
    public func totalSize() async -> Int64 {
        let sizes = items.compactMap(\.size)
        return sizes.reduce(0, +)
    }
}
