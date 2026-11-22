import AppKit
import AppCore
import DesignSystem
import FileOps
import FSCore

/// One window: title-bar tab strip, navigation bar, command bar, split body,
/// status bar. Owns its `WindowState` and one `DirectoryModel` per visible tab.
@MainActor
final class WindowController: NSWindowController {
    let state: WindowState
    private let chrome = ExplorerChromeView()

    // MARK: - File operations (Phase 9 trunk)

    private let fileEngine = FileOperationEngine()
    private let trashStore = TrashStore()
    private var undoRecords: [UndoRecord] = []
    private var redoRecords: [UndoRecord] = []
    private var operationTask: Task<Void, Never>?

    var canUndo: Bool { !undoRecords.isEmpty }
    var canRedo: Bool { !redoRecords.isEmpty }
    var hasSelection: Bool { !chrome.contentContainer.selectedItems.isEmpty }
    var clipboardHasFiles: Bool { ClipboardStore.shared.readPasteboardFileURLs() != nil }

    init(state: WindowState) {
        self.state = state
        let window = MainWindow.make()

        super.init(window: window)

        window.contentView = chrome
        chrome.delegate = self
        chrome.install(tabStrip: chrome.tabStrip, titleBarHeight: 38)

        syncChrome()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize),
            name: NSWindow.didResizeNotification,
            object: window
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var windowState: WindowState { state }

    /// Status bar summary comes from the content container: enumerated count,
    /// selection count, selected bytes.
    var contentSelectionBytes: Int64 { chrome.selectionBytes }

    /// Route an open request from the content area: same tab by default,
    /// new tab when requested (⌘+open, middle-click).
    func open(url: URL, inNewTab: Bool) {
        if inNewTab {
            _ = state.addTab(directory: url)
        } else if let tab = state.selectedTab {
            tab.navigate(to: url)
        }
        ChromeCaches.persist(state)
        syncChrome()
    }

    @objc func menuRename() {
        chrome.contentContainer.beginRenameOfFirstSelection()
    }

    @objc func menuNewFolder() {
        chrome.contentContainer.newFolder()
    }

    @objc func menuMoveToTrash() {
        trashSelectedItems()
    }

    /// Focus the content table (after path submit, tab switching, navigation).
    func focusContent() {
        chrome.contentContainer.focusTable()
    }

    /// Window teardown: cancel everything that could outlive the window.
    func tearDown() {
        operationTask?.cancel()
        chrome.contentContainer.tearDown()
    }

    // MARK: - Clipboard actions (responder chain lands on the table)

    func copySelectedItems() {
        let urls = chrome.contentContainer.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        ClipboardStore.shared.copyItems(at: urls)
    }

    func cutSelectedItems() {
        let urls = chrome.contentContainer.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        ClipboardStore.shared.cutItems(at: urls)
        applyCutGhosting()
    }

    func pasteIntoCurrentTab() {
        guard let directory = state.selectedTab?.directory,
              let urls = ClipboardStore.shared.readPasteboardFileURLs() else { return }
        let isMove = ClipboardStore.shared.shouldPerformMove(for: urls)

        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            let outcome = isMove
                ? await self.fileEngine.move(sources: urls, to: directory)
                : await self.fileEngine.copy(sources: urls, to: directory)
            self.finishOperation(outcome)
            if isMove {
                ClipboardStore.shared.clearCutIntent()
                self.applyCutGhosting()
            }
        }
    }

    func trashSelectedItems() {
        let urls = chrome.contentContainer.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }

        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.fileEngine.trash(urls, store: self.trashStore)
            self.finishOperation(outcome)
        }
    }

    /// Drag-and-drop destination: same-volume drags move, cross-volume copy,
    /// Option forces copy, ⌘ forces move (mirrors the drag cursor).
    func dropItems(at urls: [URL], into destination: URL, asMove: Bool) {
        guard !urls.isEmpty else { return }
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            let outcome = asMove
                ? await self.fileEngine.move(sources: urls, to: destination)
                : await self.fileEngine.copy(sources: urls, to: destination)
            self.finishOperation(outcome)
        }
    }

    func performUndo() {
        guard let record = undoRecords.popLast() else { return }
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.fileEngine.applyUndo(record)
            if let redo = outcome.undo {
                self.redoRecords.append(redo)
            }
            self.reportFailures(outcome.failures)
        }
    }

    func performRedo() {
        guard let record = redoRecords.popLast() else { return }
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.fileEngine.applyUndo(record)
            if let undo = outcome.undo {
                self.undoRecords.append(undo)
            }
            self.reportFailures(outcome.failures)
        }
    }

    // MARK: - Operation completion

    private func finishOperation(_ outcome: OperationOutcome) {
        if let undo = outcome.undo {
            undoRecords.append(undo)
            if undoRecords.count > 100 { undoRecords.removeFirst() }
            redoRecords.removeAll()
        }
        reportFailures(outcome.failures)
    }

    private func reportFailures(_ failures: [FileOperationFailure]) {
        guard let failure = failures.first else { return }
        DoraLog.fileOps.error("operation failed for \(failure.source.lastPathComponent, privacy: .public): \(failure.reason, privacy: .public)")
        _ = NSApp.presentError(failure)
    }

    private func applyCutGhosting() {
        chrome.contentContainer.setCutPaths(ClipboardStore.shared.cutPaths)
    }

    /// Rebuilds chrome from `state`. Called on every tab/bookmark change.
    func syncChrome() {
        let tabs = state.tabs.map { tab in
            TabStripView.Tab(id: tab.id, title: tab.title, icon: NSImage(systemSymbolName: tab.iconSystemName, accessibilityDescription: nil), isClosable: state.tabs.count > 1)
        }
        chrome.tabStrip.tabs = tabs
        chrome.tabStrip.selectedID = state.selectedTab?.id
        chrome.applyTab(state.selectedTab)
        refreshStatus()
    }

    #if DEBUG
    /// Perf harness hook: time switching between 20 tabs (acceptance: < 16 ms).
    func measureTabSwitch() -> Duration {
        let clock = ContinuousClock()
        guard state.tabs.count > 1 else { return .zero }
        return clock.measure {
            for tab in state.tabs {
                state.selectedTabID = tab.id
                syncChrome()
            }
        }
    }
    #endif

    private func refreshStatus() {
        guard let tab = state.selectedTab else { return }
        chrome.statusBar.update(
            itemCount: chrome.itemCount,
            selectedCount: tab.selectedItemIDs.count,
            selectedBytes: chrome.selectionBytes,
            detailsVisible: tab.showsDetailsPane,
            previewVisible: tab.showsPreviewPane
        )
    }

    @objc private func windowDidResize() {
        chrome.layoutChrome()
    }

    func newTab(directory: URL? = nil) {
        _ = state.addTab(directory: directory)
        syncChrome()
    }

    func closeTab(_ id: TabState.ID) {
        _ = state.closeTab(id)
        chrome.contentContainer.closeTab(id)
        if state.tabs.isEmpty {
            // Last tab closed: the window follows (Reopen Closed Tab can
            // bring the tab back on this or any window).
            window?.performClose(nil)
            return
        }
        syncChrome()
    }

    func closeCurrentTab() {
        guard let id = state.selectedTab?.id else { return }
        closeTab(id)
    }

    func reopenClosedTab() {
        _ = state.reopenLastClosedTab()
        syncChrome()
    }

    func duplicateCurrentTab() {
        state.duplicateSelectedTab()
        syncChrome()
    }

    func tearOffTab(_ id: TabState.ID, at point: NSPoint) {
        guard state.tabs.count > 1,
              let index = state.tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = state.tabs.remove(at: index)
        if state.selectedTabID == id {
            state.selectedTabID = state.tabs[min(index, state.tabs.count - 1)].id
        }
        syncChrome()

        let newWindowState = WindowState(tabs: [tab])
        let controller = WindowRegistry.shared.openWindow(state: newWindowState)
        controller.window?.setFrameOrigin(point)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func cycleTab(forward: Bool) {
        state.cycleTab(forward: forward)
        syncChrome()
    }

    func selectTab(at index: Int) {
        state.selectTab(atIndex: index)
        syncChrome()
    }

    func applyWindowMenuShortcuts() {
        window?.standardWindowButton(.closeButton)?.isHidden = false
    }
}

// MARK: - Chrome delegate

extension WindowController: ExplorerChromeViewDelegate {
    func chromeDidRequestBack() { navigate { $0.goBack() } }
    func chromeDidRequestForward() { navigate { $0.goForward() } }
    func chromeDidRequestUp() { navigate { $0.goUp() } }
    func chromeDidRequestRefresh() { chrome.reloadDirectory() }

    func chromeDidRequestPath(_ path: String) {
        navigate { tab in
            let expanded = (path as NSString).expandingTildeInPath
            tab.navigate(to: URL(fileURLWithPath: expanded))
        }
    }

    func chromeDidToggleDetailsPane() {
        state.selectedTab?.showsDetailsPane.toggle()
        ChromeCaches.persist(state)
        syncChrome()
    }

    func chromeDidTogglePreviewPane() {
        state.selectedTab?.showsPreviewPane.toggle()
        ChromeCaches.persist(state)
        syncChrome()
    }

    func chromeDidChangeCounts() {
        refreshStatus()
    }

    func chromeDidRequestNavigate(to url: URL) {
        navigate { tab in
            tab.navigate(to: url)
        }
    }

    private func navigate(_ action: (TabState) -> Void) {
        guard let tab = state.selectedTab else { return }
        action(tab)
        ChromeCaches.persist(state)
        syncChrome()
        if window?.isKeyWindow == true {
            focusContent()
        }
    }
}

/// Small persistence helpers for window chrome settings.
@MainActor
enum ChromeCaches {
    private static let sidebarKey = "window.lastSidebarWidth"
    private static let detailsKey = "window.lastDetailsWidth"

    static func persist(_ state: WindowState) {
        UserDefaults.standard.set(state.sidebarWidth, forKey: sidebarKey)
        UserDefaults.standard.set(state.detailsPaneWidth, forKey: detailsKey)
    }

    static func restore(into state: WindowState) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: sidebarKey) != nil {
            state.sidebarWidth = defaults.double(forKey: sidebarKey)
        }
        if defaults.object(forKey: detailsKey) != nil {
            state.detailsPaneWidth = defaults.double(forKey: detailsKey)
        }
    }
}
