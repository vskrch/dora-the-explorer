import AppKit
import AppCore
import FSCore
import os

/// Owns one `DirectoryModel` per open tab, hosts the active content view,
/// and drives the status bar counts. The split view's content pane.
@MainActor
final class ContentViewContainer: NSView {
    /// `url, openInNewTab`
    var onOpenURL: ((_ url: URL, _ inNewTab: Bool) -> Void)?
    var onCountsChanged: (() -> Void)?

    private struct TabStateBox {
        let model: DirectoryModel
    }

    private var tabBoxes: [TabState.ID: TabStateBox] = [:]
    private var activeTabID: TabState.ID?
    private let details = DetailsViewController(columns: FileColumn.defaultOrder)
    private let folderViews = FolderViewStore()
    private let signposter = OSSignposter(subsystem: DoraLog.subsystem, category: "perf")

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
        details.onRenameCommitted = { [weak self] item, newName in
            self?.performRename(item: item, to: newName)
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

    // MARK: - Tab activation

    func activate(tab: TabState) {
        let state = signposter.beginInterval("content.activate")
        defer { signposter.endInterval("content.activate", state) }

        if let oldID = activeTabID, oldID != tab.id, let oldBox = tabBoxes[oldID] {
            oldBox.model.onPublish = nil
        }

        self.tab = tab
        activeTabID = tab.id

        let box: TabStateBox
        if let existing = tabBoxes[tab.id] {
            box = existing
            applyTabSettings(tab: tab, to: box.model)
        } else {
            let model = DirectoryModel(directory: tab.directory, settings: settings(for: tab))
            applyTabSettings(tab: tab, to: model)
            box = TabStateBox(model: model)
            tabBoxes[tab.id] = box
        }

        if box.model.directory != tab.directory {
            box.model.directory = tab.directory // triggers reload
        } else if box.model.snapshot.totalCount == 0 && !box.model.isLoading {
            box.model.reload()
        }

        details.attach(model: box.model, columns: FileColumn.ordered(box.model.settings.columns))
        details.setSelectedItemIDs(Set(tab.selectedItemIDs))
        updateOverlays()
        onCountsChanged?()
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
        let entry = FolderViewStore.Entry(
            sortCriteria: model.settings.sortCriteria,
            grouping: model.settings.grouping,
            columns: model.settings.columns,
            columnWidths: widths,
            showHidden: model.settings.showHidden
        )
        folderViews.save(entry, for: tab.directory)
    }

    // MARK: - Model updates

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
        box.model.settings.showHidden = show
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

    // MARK: - Actions

    func beginRenameOfFirstSelection() {
        details.beginRenameOfFirstSelection()
    }

    /// Creates "New Folder" with the next free suffix, then selects it and
    /// starts an inline rename — exactly like Windows Explorer. Uniqueness
    /// probing and creation run off the main thread; the FSEvents watcher
    /// brings the new folder into the snapshot.
    /// Creates "New Folder" with the next free suffix, then selects it and
    /// starts an inline rename — exactly like Windows Explorer. Probing and
    /// creation run off the main thread; the FSEvents watcher brings the new
    /// folder into the snapshot.
    func newFolder() {
        guard let tab else { return }
        let directory = tab.directory
        let tabID = tab.id

        Task { [weak self] in
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
                _ = NSApp.presentError(error)
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
                guard let self, let box = self.tabBoxes[tabID] else { return }
                if let item = box.model.snapshot.flatItems.first(where: { $0.name == name }) {
                    self.details.setSelectedItemIDs([item.id])
                    self.details.beginRename(for: item)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func performRename(item: FileItem, to newName: String) {
        let existingNames: [String]
        if let tab, let box = tabBoxes[tab.id] {
            existingNames = box.model.snapshot.flatItems.map(\.name)
        } else {
            existingNames = []
        }
        guard RenameValidator.validate(
            newName: newName,
            originalName: item.name,
            existingNames: existingNames
        ) == nil else {
            DoraLog.ui.error("rename rejected for \(item.name, privacy: .public)")
            return
        }

        let destination = item.url.deletingLastPathComponent()
            .appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: item.url, to: destination)
            DoraLog.fileOps.info("renamed \(item.name, privacy: .public) to \(newName, privacy: .public)")
        } catch {
            DoraLog.fileOps.error("rename failed for \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            NSApp.presentError(error)
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

    private func updateOverlays() {
        guard let tab, let box = tabBoxes[tab.id] else {
            emptyState.isHidden = true
            loadingIndicator.isHidden = true
            errorView.isHidden = true
            return
        }

        let model = box.model
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
                loadingIndicator.isHidden = false
                loadingIndicator.startAnimation(nil)
            } else {
                emptyState.show(message: "This folder is empty.")
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
