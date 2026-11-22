import Foundation
import FSCore
import Observation

/// Everything a tab remembers between visits.
public struct TabSnapshot: Sendable, Hashable, Codable {
    public var directoryPath: String
    public var sortCriteria: [SortCriterion]
    public var grouping: GroupingKey
    public var view: ViewKind
    public var showHidden: Bool
    public var showsDetailsPane: Bool
    public var showsPreviewPane: Bool
    public var backHistory: [String]
    public var forwardHistory: [String]

    public init(
        directoryPath: String,
        sortCriteria: [SortCriterion] = [.nameAscending],
        grouping: GroupingKey = .none,
        view: ViewKind = .details,
        showHidden: Bool = false,
        showsDetailsPane: Bool = true,
        showsPreviewPane: Bool = false,
        backHistory: [String] = [],
        forwardHistory: [String] = []
    ) {
        self.directoryPath = directoryPath
        self.sortCriteria = sortCriteria
        self.grouping = grouping
        self.view = view
        self.showHidden = showHidden
        self.showsDetailsPane = showsDetailsPane
        self.showsPreviewPane = showsPreviewPane
        self.backHistory = backHistory
        self.forwardHistory = forwardHistory
    }
}

/// Per-tab navigation state, independent of the UI.
@MainActor
@Observable
public final class TabState: Identifiable {
    public let id: UUID
    public var title: String
    public var iconSystemName: String
    public var directory: URL {
        didSet { title = Self.title(for: directory) }
    }
    public private(set) var backHistory: [URL] = []
    public private(set) var forwardHistory: [URL] = []
    public var view: ViewKind = .details
    public var sortCriteria: [SortCriterion] = [.nameAscending]
    public var grouping: GroupingKey = .none
    public var showHidden: Bool = false
    public var showsDetailsPane: Bool = true
    public var showsPreviewPane: Bool = false
    /// Selection is persisted per tab, addressed by item id.
    public var selectedItemIDs: Set<String> = []
    /// Scroll anchor id so restoration keeps the viewport stable.
    public var scrollAnchorID: String?

    public init(directory: URL) {
        self.id = UUID()
        self.directory = directory
        self.title = Self.title(for: directory)
        self.iconSystemName = "folder"
    }

    public init(snapshot: TabSnapshot) {
        self.id = UUID()
        let url = URL(fileURLWithPath: snapshot.directoryPath)
        self.directory = url
        self.title = Self.title(for: url)
        self.iconSystemName = "folder"
        self.view = snapshot.view
        self.sortCriteria = snapshot.sortCriteria
        self.grouping = snapshot.grouping
        self.showHidden = snapshot.showHidden
        self.showsDetailsPane = snapshot.showsDetailsPane
        self.showsPreviewPane = snapshot.showsPreviewPane
        self.backHistory = snapshot.backHistory.map { URL(fileURLWithPath: $0) }
        self.forwardHistory = snapshot.forwardHistory.map { URL(fileURLWithPath: $0) }
    }

    public var canGoBack: Bool { !backHistory.isEmpty }
    public var canGoForward: Bool { !forwardHistory.isEmpty }
    public var canGoUp: Bool { directory.path != "/" }

    public func navigate(to url: URL) {
        let target = url.standardizedFileURL
        guard target != directory else { return }
        backHistory.append(directory)
        forwardHistory.removeAll()
        directory = target
        selectedItemIDs.removeAll()
        scrollAnchorID = nil
    }

    public func goBack() {
        guard let previous = backHistory.popLast() else { return }
        forwardHistory.append(directory)
        directory = previous
        selectedItemIDs.removeAll()
    }

    public func goForward() {
        guard let next = forwardHistory.popLast() else { return }
        backHistory.append(directory)
        directory = next
        selectedItemIDs.removeAll()
    }

    public func goUp() {
        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path else { return }
        navigate(to: parent)
    }

    public var snapshot: TabSnapshot {
        TabSnapshot(
            directoryPath: directory.path,
            sortCriteria: sortCriteria,
            grouping: grouping,
            view: view,
            showHidden: showHidden,
            showsDetailsPane: showsDetailsPane,
            showsPreviewPane: showsPreviewPane,
            backHistory: backHistory.map(\.path),
            forwardHistory: forwardHistory.map(\.path)
        )
    }

    private static func title(for directory: URL) -> String {
        if directory.path == "/" { return "Macintosh HD" }
        let name = directory.lastPathComponent
        return name.isEmpty ? directory.path : name
    }
}

/// Window-level state: ordered tabs plus the interaction mode between them.
@MainActor
@Observable
public final class WindowState: Identifiable {
    public let id: UUID
    public var tabs: [TabState]
    public var selectedTabID: TabState.ID?
    public private(set) var recentlyClosed: [TabSnapshot] = []
    public var isFullScreen = false
    public var isSidebarVisible = true
    public var sidebarWidth: Double = 220
    public var detailsPaneWidth: Double = 280

    public init(tabs: [TabState]) {
        self.id = UUID()
        let resolved = tabs.isEmpty ? [TabState(directory: FileManager.default.homeDirectoryForCurrentUser)] : tabs
        self.tabs = resolved
        self.selectedTabID = resolved.first?.id
    }

    public var selectedTab: TabState? {
        guard let selectedTabID else { return tabs.first }
        return tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    public func addTab(directory: URL? = nil) -> TabState {
        let base = directory ?? selectedTab?.directory ?? FileManager.default.homeDirectoryForCurrentUser
        let tab = TabState(directory: base)
        tabs.append(tab)
        selectedTabID = tab.id
        return tab
    }

    public func duplicateSelectedTab() {
        guard let current = selectedTab else { return }
        let copy = TabState(snapshot: current.snapshot)
        if let index = tabs.firstIndex(where: { $0.id == current.id }) {
            tabs.insert(copy, at: index + 1)
        } else {
            tabs.append(copy)
        }
        selectedTabID = copy.id
    }

    @discardableResult
    public func closeTab(_ id: TabState.ID, keepSnapshot: Bool = true) -> TabSnapshot? {
        guard tabs.count > 1 || keepSnapshot == false,
              let index = tabs.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let removed = tabs.remove(at: index)
        if keepSnapshot {
            recentlyClosed.append(removed.snapshot)
            if recentlyClosed.count > 20 { recentlyClosed.removeFirst() }
        }
        if selectedTabID == id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
        return removed.snapshot
    }

    public func closeOtherTabs(keeping id: TabState.ID) {
        for tab in tabs where tab.id != id {
            _ = closeTab(tab.id)
        }
        selectedTabID = id
    }

    public func closeTabsToRight(of id: TabState.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        for tab in tabs[(index + 1)...] {
            _ = closeTab(tab.id)
        }
    }

    public func reopenLastClosedTab() -> TabState? {
        guard let snapshot = recentlyClosed.popLast() else { return nil }
        let tab = TabState(snapshot: snapshot)
        tabs.append(tab)
        selectedTabID = tab.id
        return tab
    }

    public func moveTab(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source), destination >= 0, destination <= tabs.count else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: min(destination, tabs.count))
    }

    public func selectTab(atIndex index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedTabID = tabs[index].id
    }

    public func cycleTab(forward: Bool) {
        guard tabs.count > 1, let current = selectedTabID,
              let index = tabs.firstIndex(where: { $0.id == current }) else { return }
        let next = forward
            ? (index + 1) % tabs.count
            : (index - 1 + tabs.count) % tabs.count
        selectedTabID = tabs[next].id
    }

    // MARK: - Persistence

    public struct PersistedWindow: Codable, Sendable {
        public var tabs: [TabSnapshot]
        public var selectedIndex: Int
        public var sidebarWidth: Double
        public var detailsPaneWidth: Double
        public var isSidebarVisible: Bool
    }

    public var persisted: PersistedWindow {
        PersistedWindow(
            tabs: tabs.map(\.snapshot),
            selectedIndex: tabs.firstIndex { $0.id == selectedTabID } ?? 0,
            sidebarWidth: sidebarWidth,
            detailsPaneWidth: detailsPaneWidth,
            isSidebarVisible: isSidebarVisible
        )
    }

    public static func restore(from persisted: PersistedWindow) -> WindowState {
        let tabs = persisted.tabs.map(TabState.init(snapshot:))
        let state = WindowState(tabs: tabs)
        state.selectedTabID = tabs.indices.contains(persisted.selectedIndex)
            ? tabs[persisted.selectedIndex].id
            : tabs.first?.id
        state.sidebarWidth = persisted.sidebarWidth
        state.detailsPaneWidth = persisted.detailsPaneWidth
        state.isSidebarVisible = persisted.isSidebarVisible
        return state
    }
}

/// Remembers open windows/tabs across launches (unless disabled in settings).
@MainActor
public final class WorkspaceStore {
    public struct PersistedWorkspace: Codable, Sendable {
        public var windows: [WindowState.PersistedWindow]
        public var isEnabled: Bool

        public init(windows: [WindowState.PersistedWindow], isEnabled: Bool) {
            self.windows = windows
            self.isEnabled = isEnabled
        }
    }

    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        url: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fenestra", isDirectory: true)
            .appendingPathComponent("workspace.json")
    ) {
        self.url = url
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() -> PersistedWorkspace? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(PersistedWorkspace.self, from: data)
        } catch {
            FenestraLog.shell.error("workspace decode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func save(_ workspace: PersistedWorkspace) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(workspace)
            try data.write(to: url, options: .atomic)
        } catch {
            FenestraLog.shell.error("workspace save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
