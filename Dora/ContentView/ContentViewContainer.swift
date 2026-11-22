import AppKit
import AppCore
import FileOps
import FSCore
import os

/// Owns one `DirectoryModel` per open tab, hosts the active content view,
/// and is the *single* consumer of model publishes — it refreshes the table,
/// the overlay states and the status counts on every change. The split view's
/// content pane.
///
/// Selection is ID-addressed and lives on `TabState`; the table never derives
/// selection from indexes across publishes, so live updates can't shift it.
@MainActor
final class ContentViewContainer: NSView {
    /// `url, openInNewTab`
    var onOpenURL: ((_ url: URL, _ inNewTab: Bool) -> Void)?
    var onCountsChanged: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    /// Backspace in the content table navigates back.
    var onBackRequested: (() -> Void)?
    /// Everything the content area asks its owner to do to FILES.
    var onIntent: ((_ intent: Intent) -> Void)?

    enum Intent {
        case cut, copy, paste, trash
        case drop(urls: [URL], destination: URL, asMove: Bool)
    }

    private struct TabBox {
        let model: DirectoryModel
        var collapsedGroups: Set<String> = []
    }

    private var tabBoxes: [TabState.ID: TabBox] = [:]
    private var activeTabID: TabState.ID?
    private let details = DetailsViewController(columns: FileColumn.defaultOrder)
    private var folderViews: FolderViewStore { FolderViewStore.shared }
    private let signposter = OSSignposter(subsystem: DoraLog.subsystem, category: "perf")

    /// Pending helper-op tasks (new folder hand-off, rename). Cancelled on
    /// teardown so nothing outlives the window.
    private var helperTask: Task<Void, Never>?

    // Overlay states
    private let emptyState = EmptyStateView()
    private let loadingIndicator = NSProgressIndicator()
    private let errorView = FolderErrorView()

    private var tab: TabState?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        addSubview(details.view)
        details.view.frame = bounds
        details.view.autoresizingMask = [.width, .height]

        buildOverlays()
        wireDetails()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Wiring

    private func wireDetails() {
        details.onOpen = { [weak self] item, inNewTab in
            self?.open(item: item, inNewTab: inNewTab)
        }
        details.onSelectionChanged = { [weak self] ids in
            guard let self, let tab = self.tab else { return }
            tab.selectedItemIDs = ids
            tab.scrollAnchorID = ids.first
            self.onSelectionChanged?()
            self.onCountsChanged?()
        }
        details.onSortChanged = { [weak self] criteria in
            guard let self, let tab = self.tab, let box = self.tabBoxes[tab.id] else { return }
            tab.sortCriteria = criteria
            box.model.settings.sortCriteria = criteria
            self.persistFolderView(for: tab, model: box.model)
        }
        details.onColumnsChanged = { [weak self] columns, widths in
            guard let self, let tab = self.tab, let box = self.tabBoxes[tab.id] else { return }
            var settings = box.model.settings
            settings.columns = columns.map(\.rawValue)
            box.model.settings = settings
            self.persistFolderView(for: tab, model: box.model, widths: widths)
        }
        details.onGroupToggled = { [weak self] groupID in
            guard let self, let tabID = self.activeTabID, var box = self.tabBoxes[tabID] else { return }
            if box.collapsedGroups.contains(groupID) {
                box.collapsedGroups.remove(groupID)
            } else {
                box.collapsedGroups.insert(groupID)
            }
            self.tabBoxes[tabID] = box
        }
        details.onRenameCommitted = { [weak self] item, newName in
            self?.performRename(item: item, to: newName)
        }
        details.onNavigateBack = { [weak self] in
            self?.onBackRequested?()
        }
        details.onDropFiles = { [weak self] urls, destination, asMove in
            self?.onIntent?(.drop(urls: urls, destination: destination, asMove: asMove))
        }
        details.onClipboardAction = { [weak self] intent in
            switch intent {
            case .cut: self?.onIntent?(.cut)
            case .copy: self?.onIntent?(.copy)
            case .paste: self?.onIntent?(.paste)
            case .trash: self?.onIntent?(.trash)
            }
        }
        details.onNewFolderRequested = { [weak self] in
            self?.newFolder()
        }
        details.onRefreshRequested = { [weak self] in
            self?.reload()
        }
        details.onToggleHiddenRequested = { [weak self] in
            guard let self, let tab = self.tab else { return }
            self.applyShowHidden(!tab.showHidden)
        }
        errorView.onRetry = { [weak self] in
            self?.reload()
        }
    }

    private func open(item: FileItem, inNewTab: Bool) {
        if item.isDirectory {
            onOpenURL?(item.url, inNewTab)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    // MARK: - Tab lifecycle

    func activate(tab: TabState) {
        let state = signposter.beginInterval("content.activate")
        defer { signposter.endInterval("content.activate", state) }

        if let oldID = activeTabID, oldID != tab.id, let oldBox = tabBoxes[oldID] {
            oldBox.model.onPublish = nil
        }
        // Kill a pending New-Folder hand-off from another tab.
        helperTask?.cancel()

        self.tab = tab
        activeTabID = tab.id

        let box: TabBox
        if let existing = tabBoxes[tab.id] {
            box = existing
            applyTabSettings(tab: tab, to: box.model)
        } else {
            let model = DirectoryModel(directory: tab.directory, settings: settings(for: tab))
            applyTabSettings(tab: tab, to: model)
            box = TabBox(model: model)
            tabBoxes[tab.id] = box
        }

        // Publishes drive everything: table refresh, overlays, status counts.
        box.model.onPublish = { [weak self] in
            self?.handlePublish()
        }

        if box.model.directory != tab.directory {
            box.model.directory = tab.directory // triggers reload
        } else if box.model.snapshot.totalCount == 0 && !box.model.isLoading {
            box.model.reload()
        }

        details.attach(model: box.model, columns: FileColumn.ordered(box.model.settings.columns))
        if let stored = folderViews.entry(for: tab.directory) {
            details.applyColumnWidths(stored.columnWidths ?? [:])
        }
        details.setSelectedItemIDs(Set(tab.selectedItemIDs), revealingAnchor: tab.scrollAnchorID)
        handlePublish()
    }

    /// Releases a closed tab's model and watcher. Without this, closed tabs
    /// leak a live FSEvents stream and their full snapshots.
    func closeTab(_ id: TabState.ID) {
        guard let box = tabBoxes.removeValue(forKey: id) else { return }
        box.model.onPublish = nil
        box.model.cancelLoads()
        if activeTabID == id {
            activeTabID = nil
        }
    }

    /// Window teardown: cancel everything that could outlive the view.
    func tearDown() {
        helperTask?.cancel()
        for (id, box) in tabBoxes {
            box.model.onPublish = nil
            box.model.cancelLoads()
            tabBoxes.removeValue(forKey: id)
        }
        activeTabID = nil
        tab = nil
    }

    /// Tab state (sort/group/hidden) always wins over stored folder memory for
    /// the live session; the store only feeds first visits.
    private func applyTabSettings(tab: TabState, to model: DirectoryModel) {
        var settings = model.settings
        settings.sortCriteria = tab.sortCriteria
        settings.grouping = tab.grouping
        settings.showHidden = tab.showHidden
        model.settings = settings
    }

    private func settings(for tab: TabState) -> DirectoryModel.ViewSettings {
        let stored = folderViews.entry(for: tab.directory)
        return DirectoryModel.ViewSettings(
            sortCriteria: tab.sortCriteria,
            grouping: tab.grouping,
            columns: stored?.columns ?? FileColumn.defaultOrder.map(\.rawValue),
            showHidden: tab.showHidden
        )
    }

    private func persistFolderView(for tab: TabState, model: DirectoryModel, widths: [String: Double]? = nil) {
        var entry = folderViews.entry(for: tab.directory) ?? FolderViewStore.Entry()
        entry.sortCriteria = model.settings.sortCriteria
        entry.grouping = model.settings.grouping
        entry.columns = model.settings.columns
        if let widths { entry.columnWidths = widths }
        entry.showHidden = model.settings.showHidden
        folderViews.save(entry, for: tab.directory)
    }

    // MARK: - Publishing

    /// Sole publish consumer: re-renders the table with ID-addressed
    /// selection and a captured viewport anchor, then refreshes overlays and
    /// the status bar.
    private func handlePublish() {
        guard let tab, let box = tabBoxes[tab.id] else { return }
        let anchor = details.visibleAnchorItemID
        details.applySnapshot(
            snapshot: box.model.snapshot,
            selection: Set(tab.selectedItemIDs),
            collapsedGroupIDs: box.collapsedGroups,
            anchorItemID: anchor
        )
        updateOverlays(for: box.model)
        onCountsChanged?()
    }

    func reload() {
        guard let tab else { return }
        tabBoxes[tab.id]?.model.reload()
    }

    func applySort(_ criteria: [SortCriterion]) {
        guard let tab, let box = tabBoxes[tab.id] else { return }
        tab.sortCriteria = criteria
        box.model.settings.sortCriteria = criteria
        persistFolderView(for: tab, model: box.model)
    }

    func applyGrouping(_ grouping: GroupingKey) {
        guard let tab, let box = tabBoxes[tab.id] else { return }
        tab.grouping = grouping
        box.model.settings.grouping = grouping
        persistFolderView(for: tab, model: box.model)
    }

    func applyShowHidden(_ show: Bool) {
        guard let tab, let box = tabBoxes[tab.id] else { return }
        tab.showHidden = show
        box.model.settings.showHidden = show // changed flag reloads internally
        persistFolderView(for: tab, model: box.model)
    }

    // MARK: - Introspection for the status bar

    var itemCount: Int {
        guard let tab, let box = tabBoxes[tab.id] else { return 0 }
        return box.model.snapshot.totalCount
    }

    var selectionCount: Int {
        tab?.selectedItemIDs.count ?? 0
    }

    var selectionBytes: Int64 {
        guard let tab, let box = tabBoxes[tab.id] else { return 0 }
        return box.model.size(ofIDs: Set(tab.selectedItemIDs))
    }

    var selectedItems: [FileItem] {
        guard let tab, let box = tabBoxes[tab.id] else { return [] }
        return tab.selectedItemIDs.compactMap { box.model.item(withID: $0) }
    }

    var currentDirectory: URL? {
        tab?.directory
    }

    // MARK: - Focus & ghosting passthroughs

    func focusTable() {
        if let window = details.view.window {
            window.makeFirstResponder(details.table)
        }
    }

    func setCutPaths(_ paths: Set<String>) {
        details.setCutPaths(paths)
    }

    // MARK: - Actions

    func beginRenameOfFirstSelection() {
        details.beginRenameOfFirstSelection()
    }

    /// Performs the rename off the main actor (cross-volume moves are full
    /// copies); validation already ran in the view controller.
    private func performRename(item: FileItem, to newName: String) {
        let destination = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        helperTask?.cancel()
        helperTask = Task { [weak self] in
            let failure: (any Error)? = await Task.detached(priority: .userInitiated) {
                do {
                    try FileManager.default.moveItem(at: item.url, to: destination)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let failure {
                DoraLog.fileOps.error("rename failed for \(item.url.path, privacy: .public): \(failure.localizedDescription, privacy: .public)")
                self?.presentErrorOnMain(failure)
            } else {
                DoraLog.fileOps.info("renamed \(item.name, privacy: .public)")
            }
        }
    }

    private func presentErrorOnMain(_ error: any Error) {
        _ = NSApp.presentError(error)
    }

    /// Creates "New Folder" with the next free suffix, then selects it and
    /// starts an inline rename — exactly like Windows Explorer. Probing and
    /// creation run off the main thread; the FSEvents watcher brings the new
    /// folder into the snapshot.
    func newFolder() {
        guard let tab else { return }
        let directory = tab.directory
        let tabID = tab.id

        helperTask?.cancel()
        helperTask = Task { [weak self] in
            let outcome: Result<String, any Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let name = Self.uniqueFolderName(in: directory)
                    try FileManager.default.createDirectory(
                        at: directory.appendingPathComponent(name),
                        withIntermediateDirectories: false
                    )
                    return .success(name)
                } catch {
                    return .failure(error)
                }
            }.value

            switch outcome {
            case .success(let name):
                DoraLog.fileOps.info("created folder \(name, privacy: .public)")
                self?.selectAndRenameCreatedFolder(named: name, in: tabID)
            case .failure(let error):
                DoraLog.fileOps.error("new folder failed: \(error.localizedDescription, privacy: .public)")
                self?.presentErrorOnMain(error)
            }
        }
    }

    private nonisolated static func uniqueFolderName(in directory: URL) -> String {
        let base = "New Folder"
        var candidate = base
        var index = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base) (\(index))"
            index += 1
        }
        return candidate
    }

    private func selectAndRenameCreatedFolder(named name: String, in tabID: TabState.ID) {
        // The watcher usually delivers the new item within one latency tick.
        Task { [weak self] in
            for _ in 0..<20 {
                guard let self else { return }
                // Tab switched away: never mutate another folder's view.
                guard self.activeTabID == tabID, let box = self.tabBoxes[tabID] else { return }
                if let item = box.model.snapshot.flatItems.first(where: { $0.name == name }) {
                    self.details.setSelectedItemIDs([item.id], revealingAnchor: item.id)
                    self.details.beginRename(for: item)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: - Overlays

    private func buildOverlays() {
        emptyState.isHidden = true
        addSubview(emptyState)

        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .regular
        loadingIndicator.isHidden = true
        addSubview(loadingIndicator)

        errorView.isHidden = true
        addSubview(errorView)
    }

    private func updateOverlays(for model: DirectoryModel) {
        if let error = model.loadError {
            errorView.configure(
                title: "Couldn't open this folder",
                detail: error.localizedDescription
            )
            errorView.isHidden = false
            emptyState.isHidden = true
            loadingIndicator.isHidden = true
        } else if model.snapshot.totalCount == 0 {
            if model.isLoading {
                emptyState.isHidden = true
                errorView.isHidden = true
                loadingIndicator.isHidden = false
                loadingIndicator.startAnimation(nil)
            } else {
                emptyState.show(message: "This folder is empty.")
                errorView.isHidden = true
                loadingIndicator.isHidden = true
            }
        } else {
            emptyState.isHidden = true
            errorView.isHidden = true
            loadingIndicator.isHidden = true
        }
        if loadingIndicator.isHidden {
            loadingIndicator.stopAnimation(nil)
        }
    }

    override func layout() {
        super.layout()
        emptyState.frame = bounds
        errorView.frame = bounds
        let indicatorSize = NSSize(width: 28, height: 28)
        loadingIndicator.frame = NSRect(
            x: bounds.midX - indicatorSize.width / 2,
            y: bounds.midY - indicatorSize.height / 2,
            width: indicatorSize.width,
            height: indicatorSize.height
        )
    }
}

// MARK: - Overlay views

/// Empty-folder placeholder, Explorer style.
@MainActor
final class EmptyStateView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        icon.contentTintColor = .tertiaryLabelColor

        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .tertiaryLabelColor
        subtitle.stringValue = "Drop files here, or create something new."

        for subview in [icon, label, subtitle] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -18),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 10),
            subtitle.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(message: String) {
        label.stringValue = message
        isHidden = false
    }
}

/// Readable error state with a Retry action.
@MainActor
final class FolderErrorView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
    var onRetry: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 14)
        titleLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor

        retryButton.action = #selector(retryClicked)
        retryButton.target = self

        for subview in [titleLabel, detailLabel, retryButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -18),
            detailLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            retryButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            retryButton.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func retryClicked() {
        onRetry?()
    }

    func configure(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
    }
}
