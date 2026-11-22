import AppKit
import AppCore
import DesignSystem
import FSCore

/// One window: title-bar tab strip, navigation bar, command bar, split body,
/// status bar. Owns its `WindowState` and one `DirectoryModel` per visible tab.
@MainActor
final class WindowController: NSWindowController {
    let state: WindowState
    private let chrome = ExplorerChromeView()

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
        if state.tabs.isEmpty {
            // Last tab closed: close window unless app keeps it open.
            window?.performClose(nil)
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
