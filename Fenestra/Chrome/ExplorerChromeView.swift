import AppKit
import AppCore
import DesignSystem
import FSCore

@MainActor
protocol ExplorerChromeViewDelegate: AnyObject {
    func chromeDidRequestBack()
    func chromeDidRequestForward()
    func chromeDidRequestUp()
    func chromeDidRequestRefresh()
    func chromeDidRequestPath(_ path: String)
    func chromeDidToggleDetailsPane()
    func chromeDidTogglePreviewPane()
    /// Enumerated item count changed; the status bar should refresh.
    func chromeDidChangeCounts()
}

/// Root content view of a window. Lays out Explorer's four rows plus the split
/// body using manual layout so resizing never triggers a SwiftUI pass.
@MainActor
final class ExplorerChromeView: NSView {
    weak var delegate: ExplorerChromeViewDelegate?

    let tabStrip = TabStripView()
    private let navigationBar = NavigationBarView()
    private let commandBar = CommandBarView()
    let statusBar = StatusBarView()

    private let splitView = NSSplitView()
    private let sidebar = SidebarPlaceholderView()
    private let contentHost = ContentPlaceholderView()
    private let detailsPane = DetailsPlaceholderView()

    private let tabStripBackground = ChromeBackgroundView(material: .toolbar)
    private var model: DirectoryModel?
    /// Item count of the last completed enumeration of the visible tab.
    private(set) var itemCount = 0

    private let tabStripHeight: CGFloat = 38
    private let navigationBarHeight: CGFloat = 40
    private let commandBarHeight: CGFloat = 40
    private let statusBarHeight: CGFloat = 24
    private let sidebarWidth: CGFloat = 220
    private let detailsWidth: CGFloat = 260
    private var leadingTrafficLightInset: CGFloat = 78

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        build()
        wire()
        hookAccessibilityChanges()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - Construction

    private func build() {
        tabStripBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabStripBackground)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.delegate = self

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        detailsPane.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(contentHost)
        splitView.addArrangedSubview(detailsPane)

        for view in [tabStrip, navigationBar, commandBar, splitView, statusBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        tabStripBackground.addSubview(tabStrip)
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tabStrip.leadingAnchor.constraint(equalTo: tabStripBackground.leadingAnchor, constant: 78),
            tabStrip.trailingAnchor.constraint(equalTo: tabStripBackground.trailingAnchor, constant: -8),
            tabStrip.bottomAnchor.constraint(equalTo: tabStripBackground.bottomAnchor, constant: -4),
            tabStrip.heightAnchor.constraint(equalToConstant: 28),
        ])

        navigationBar.heightAnchor.constraint(equalToConstant: navigationBarHeight).isActive = true
        commandBar.heightAnchor.constraint(equalToConstant: commandBarHeight).isActive = true
        statusBar.heightAnchor.constraint(equalToConstant: statusBarHeight).isActive = true

        NSLayoutConstraint.activate([
            tabStripBackground.topAnchor.constraint(equalTo: topAnchor),
            tabStripBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabStripBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabStripBackground.heightAnchor.constraint(equalToConstant: tabStripHeight),

            navigationBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            navigationBar.topAnchor.constraint(equalTo: tabStripBackground.bottomAnchor),
            navigationBar.heightAnchor.constraint(equalToConstant: navigationBarHeight),

            commandBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            commandBar.topAnchor.constraint(equalTo: navigationBar.bottomAnchor),

            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.topAnchor.constraint(equalTo: commandBar.bottomAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        sidebar.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        detailsPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        detailsPane.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true
    }

    /// Pins the glass strip into the title bar area. Called once by the window
    /// controller with the resolved title-bar height.
    func install(tabStrip strip: TabStripView, titleBarHeight: CGFloat) {
        // The title-bar glass strip is pinned in `build()`; the tab strip sits
        // inside it with the traffic lights reserved on the leading side.
        leadingTrafficLightInset = 78
        layoutChrome()
    }

    private func wire() {
        tabStrip.onSelect = { [weak self] id in
            self?.onTabSelected(id)
        }
        tabStrip.onClose = { [weak self] id in
            (self?.window?.windowController as? WindowController)?.closeTab(id)
        }
        tabStrip.onMiddleClickClose = { [weak self] id in
            (self?.window?.windowController as? WindowController)?.closeTab(id)
        }
        tabStrip.onNewTab = { [weak self] in
            (self?.window?.windowController as? WindowController)?.newTab(directory: self?.currentDirectory)
        }
        tabStrip.onDragOut = { [weak self] id, point in
            guard let self else { return }
            let windowPoint = self.window?.convertPoint(fromScreen: point) ?? point
            (self.window?.windowController as? WindowController)?.tearOffTab(id, at: windowPoint)
        }
        tabStrip.contextMenuProvider = { [weak self] id in
            self?.tabContextMenu(for: id)
        }

        navigationBar.onBack = { [weak self] in self?.delegate?.chromeDidRequestBack() }
        navigationBar.onForward = { [weak self] in self?.delegate?.chromeDidRequestForward() }
        navigationBar.onUp = { [weak self] in self?.delegate?.chromeDidRequestUp() }
        navigationBar.onRefresh = { [weak self] in self?.delegate?.chromeDidRequestRefresh() }
        navigationBar.onPathSubmitted = { [weak self] path in self?.delegate?.chromeDidRequestPath(path) }

        statusBar.onToggleDetails = { [weak self] in self?.delegate?.chromeDidToggleDetailsPane() }
        statusBar.onTogglePreview = { [weak self] in self?.delegate?.chromeDidTogglePreviewPane() }
    }

    // MARK: - State application

    func applyTab(_ tab: TabState?) {
        guard let tab else { return }
        navigationBar.update(
            path: tab.directory.path,
            canGoBack: tab.canGoBack,
            canGoForward: tab.canGoForward,
            canGoUp: tab.canGoUp
        )
        sidebar.update(directory: tab.directory)
        detailsPane.isHidden = !tab.showsDetailsPane
        splitView.setPosition(tab.showsDetailsPane ? splitView.frame.width - detailsWidth : splitView.frame.width, ofDividerAt: 1)

        let model = DirectoryModel(directory: tab.directory)
        self.model = model
        itemCount = 0
        model.reload()

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, self.model === model else { return }
            let snapshot = model.snapshot
            self.itemCount = snapshot.totalCount
            self.contentHost.update(directory: tab.directory, itemCount: snapshot.totalCount)
            self.delegate?.chromeDidChangeCounts()
        }
    }

    var currentDirectory: URL? {
        (window?.windowController as? WindowController)?.state.selectedTab?.directory
    }

    func reloadDirectory() {
        model?.reload()
    }

    func layoutChrome() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func focusPathFieldIfPossible() {
        navigationBar.focusPathField()
    }

    // MARK: - Tabs

    private func onTabSelected(_ id: TabState.ID) {
        guard let controller = window?.windowController as? WindowController else { return }
        controller.state.selectedTabID = id
        controller.syncChrome()
    }

    private func tabContextMenu(for id: TabState.ID) -> NSMenu {
        guard let controller = window?.windowController as? WindowController else { return NSMenu() }
        let menu = NSMenu()

        menu.addItem(withTitle: "New tab", action: #selector(WindowController.menuNewTab), keyEquivalent: "").target = controller
        menu.addItem(withTitle: "Duplicate tab", action: #selector(WindowController.menuDuplicateTab), keyEquivalent: "").target = controller
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close tab", action: #selector(WindowController.menuCloseTab), keyEquivalent: "").target = controller
        menu.addItem(withTitle: "Close other tabs", action: #selector(WindowController.menuCloseOtherTabs), keyEquivalent: "").target = controller
        menu.addItem(withTitle: "Close tabs to the right", action: #selector(WindowController.menuCloseTabsToRight), keyEquivalent: "").target = controller
        menu.addItem(withTitle: "Move to new window", action: #selector(WindowController.menuMoveToNewWindow), keyEquivalent: "").target = controller
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reopen closed tab", action: #selector(WindowController.menuReopenClosedTab), keyEquivalent: "").target = controller
        return menu
    }

    private func hookAccessibilityChanges() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @objc private func accessibilityChanged() {
        tabStripBackground.refreshAppearance()
        needsDisplay = true
    }

    // MARK: - Accessibility

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Fenestra window" }
}

extension ExplorerChromeView: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMinimumPosition
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMaximumPosition
    }

    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        dividerIndex == 1 && (window?.windowController as? WindowController)?.state.selectedTab?.showsDetailsPane == false
    }
}
