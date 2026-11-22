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
    weak var delegate: (any ExplorerChromeViewDelegate)?

    let tabStrip = TabStripView()
    private let navigationBar = NavigationBarView()
    private let commandBar = CommandBarView()
    let statusBar = StatusBarView()

    private let splitView = NSSplitView()
    private let sidebar = SidebarPlaceholderView()
    let contentContainer = ContentViewContainer()
    private let detailsPane = DetailsPlaceholderView()

    private let tabStripBackground = ChromeBackgroundView(material: .toolbar)
    /// Item count of the visible tab's last completed enumeration.
    var itemCount: Int { contentContainer.itemCount }
    /// Bytes of the visible tab's current selection.
    var selectionBytes: Int64 { contentContainer.selectionBytes }

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
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        detailsPane.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(contentContainer)
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

        contentContainer.onOpenURL = { [weak self] url, inNewTab in
            guard let self, let controller = self.window?.windowController as? WindowController else { return }
            controller.open(url: url, inNewTab: inNewTab)
        }
        contentContainer.onCountsChanged = { [weak self] in
            self?.delegate?.chromeDidChangeCounts()
        }

        commandBar.onNew = { [weak self] in
            self?.presentNewMenu()
        }
        commandBar.onSort = { [weak self] in
            self?.presentSortMenu()
        }
        commandBar.onView = { [weak self] in
            self?.presentViewMenu()
        }

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

        contentContainer.activate(tab: tab)
    }

    var currentDirectory: URL? {
        (window?.windowController as? WindowController)?.state.selectedTab?.directory
    }

    func reloadDirectory() {
        contentContainer.reload()
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

    // MARK: - Command bar menus

    private func presentNewMenu() {
        let menu = NSMenu()
        let folderItem = NSMenuItem(title: "New Folder", action: #selector(newFolderAction), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)
        popBelowCommandBar(menu)
    }

    @objc private func newFolderAction() {
        contentContainer.newFolder()
    }

    private func presentSortMenu() {
        guard let tab = (window?.windowController as? WindowController)?.state.selectedTab else { return }
        let menu = NSMenu(title: "Sort")

        let keys: [(String, SortCriterion.Key)] = [
            ("Name", .name),
            ("Date Modified", .dateModified),
            ("Type", .type),
            ("Size", .size),
        ]
        let primary = tab.sortCriteria.first ?? .nameAscending
        for (title, key) in keys {
            let item = NSMenuItem(title: title, action: #selector(sortByAction(_:)), keyEquivalent: "")
            item.target = self
            item.state = primary.key == key ? .on : .off
            item.representedObject = key.rawValue
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let ascendingItem = NSMenuItem(title: "Ascending", action: #selector(sortDirectionAction(_:)), keyEquivalent: "")
        ascendingItem.target = self
        ascendingItem.state = primary.ascending ? .on : .off
        menu.addItem(ascendingItem)

        menu.addItem(.separator())
        let groupMenu = NSMenu(title: "Group by")
        let groupings: [(String, GroupingKey)] = [
            ("None", .none),
            ("Type", .type),
            ("Date Modified", .dateModified),
            ("Size", .size),
        ]
        for (title, grouping) in groupings {
            let item = NSMenuItem(title: title, action: #selector(groupByAction(_:)), keyEquivalent: "")
            item.target = self
            item.state = tab.grouping == grouping ? .on : .off
            item.representedObject = grouping.rawValue
            groupMenu.addItem(item)
        }
        menu.setSubmenu(groupMenu, for: menu.addItem(withTitle: "Group by", action: nil, keyEquivalent: ""))

        popBelowCommandBar(menu)
    }

    @objc private func sortByAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let key = SortCriterion.Key(rawValue: rawValue),
              let tab = (window?.windowController as? WindowController)?.state.selectedTab else { return }
        let current = tab.sortCriteria.first ?? .nameAscending
        let criteria = current.key == key
            ? [SortCriterion(key: key, ascending: !current.ascending)] + tab.sortCriteria.dropFirst().filter { $0.key != key }
            : [SortCriterion(key: key, ascending: true)]
        applySort(criteria, to: tab)
    }

    @objc private func sortDirectionAction(_ sender: NSMenuItem) {
        guard let tab = (window?.windowController as? WindowController)?.state.selectedTab,
              let primary = tab.sortCriteria.first else { return }
        var criteria = tab.sortCriteria
        criteria[0] = SortCriterion(key: primary.key, ascending: !primary.ascending)
        applySort(criteria, to: tab)
    }

    @objc private func groupByAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let grouping = GroupingKey(rawValue: rawValue),
              let tab = (window?.windowController as? WindowController)?.state.selectedTab else { return }
        tab.grouping = grouping
        contentContainer.applyGrouping(grouping)
    }

    private func applySort(_ criteria: [SortCriterion], to tab: TabState) {
        tab.sortCriteria = criteria
        contentContainer.applySort(criteria)
    }

    private func presentViewMenu() {
        guard let tab = (window?.windowController as? WindowController)?.state.selectedTab else { return }
        let menu = NSMenu(title: "View")

        let hiddenItem = NSMenuItem(title: "Show Hidden Items", action: #selector(toggleHiddenAction), keyEquivalent: "")
        hiddenItem.target = self
        hiddenItem.state = tab.showHidden ? .on : .off
        menu.addItem(hiddenItem)

        popBelowCommandBar(menu)
    }

    @objc private func toggleHiddenAction() {
        guard let tab = (window?.windowController as? WindowController)?.state.selectedTab else { return }
        tab.showHidden.toggle()
        contentContainer.applyShowHidden(tab.showHidden)
    }

    private func popBelowCommandBar(_ menu: NSMenu) {
        guard let contentView = window?.contentView else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 8, y: commandBar.frame.minY + 4), in: contentView)
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
    override func accessibilityLabel() -> String? { "Dora the Explorer window" }
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
