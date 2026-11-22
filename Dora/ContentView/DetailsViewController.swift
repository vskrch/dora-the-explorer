import AppKit
import AppCore
import FSCore
import os

/// The Details view: view-based `NSTableView` over the tab's `DirectoryModel`.
///
/// Performance approach: the flat row space is an array + dictionary (O(1)
/// lookups), cells are pooled per column by identifier, and the per-row path
/// allocates nothing beyond what AppKit's reuse pool hands back.
@MainActor
final class DetailsViewController: NSViewController {
    var onOpen: ((_ item: FileItem, _ inNewTab: Bool) -> Void)?
    var onSelectionChanged: ((_ itemIDs: Set<FileItem.ID>) -> Void)?
    var onSortChanged: ((_ criteria: [SortCriterion]) -> Void)?
    var onColumnsChanged: ((_ columns: [FileColumn], _ widths: [String: Double]) -> Void)?
    var onRenameCommitted: ((_ item: FileItem, _ newName: String) -> Void)?

    private(set) var model: DirectoryModel?

    let scrollView = NSScrollView()
    let table = FileTableView()
    private var rowSpace = FileRowSpace(snapshot: DirectorySnapshot(generation: 0, groups: [], totalCount: 0), collapsedGroupIDs: [])
    private var collapsedGroupIDs: Set<String> = []
    private let renameField = InlineRenameField()
    private var renamingItem: FileItem?
    private var isSyncingSelection = false
    private var isSyncingSortDescriptors = false
    private var columnsState: [FileColumn]
    private let signposter = OSSignposter(subsystem: DoraLog.subsystem, category: "perf")

    private var textCellIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("text-cell")
    }
    private var nameCellIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("name-cell")
    }
    private var groupCellIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("group-header")
    }
    private var groupRowIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("group-row")
    }
    private var itemRowIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("item-row")
    }

    init(columns: [FileColumn]) {
        self.columnsState = columns
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))

        let header = ColumnChoosingHeaderView()
        header.onRightClick = { [weak self] point in
            self?.presentColumnChooser(at: point)
        }

        table.style = .fullWidth
        table.headerView = header
        table.allowsMultipleSelection = true
        table.allowsTypeSelect = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .windowBackgroundColor
        table.rowHeight = 32
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.dataSource = self
        table.delegate = self
        table.onOpenRows = { [weak self] rows, inNewTab in
            self?.open(rows: rows, inNewTab: inNewTab)
        }
        table.onMiddleClickRow = { [weak self] row in
            guard let self, let id = self.rowSpace.itemID(at: row),
                  let item = self.model?.item(withID: id) else { return }
            self.onOpen?(item, true)
        }

        renameField.onCommit = { [weak self] newName, moveToNext in
            self?.commitRename(newName: newName, moveToNext: moveToNext)
        }
        renameField.onCancel = { [weak self] in
            self?.endRename()
        }

        rebuildColumns()

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(table)
    }

    // MARK: - Model attachment

    func attach(model: DirectoryModel, columns: [FileColumn]) {
        self.model?.onPublish = nil
        self.model = model
        columnsState = columns
        rebuildColumns()
        model.onPublish = { [weak self] in
            self?.handlePublish()
        }
        handlePublish()
        syncSortIndicators()
    }

    private func handlePublish() {
        let state = signposter.beginInterval("details.rebuild")
        defer { signposter.endInterval("details.rebuild", state) }

        // Keep the viewport anchored: the first visible item stays put when
        // live updates re-sort or regroup the snapshot.
        let anchorItemID = firstVisibleItemID()
        rowSpace = FileRowSpace(
            snapshot: model?.snapshot ?? DirectorySnapshot(generation: 0, groups: [], totalCount: 0),
            collapsedGroupIDs: collapsedGroupIDs
        )

        isSyncingSelection = true
        table.reloadData()
        setSelectedItemIDs(selectedItemIDs, scrollToAnchor: anchorItemID)
        isSyncingSelection = false
    }

    /// Row indices currently visible in the table's viewport.
    private var visibleRows: [Int] {
        let range = table.rows(in: table.visibleRect)
        guard range.length > 0, range.location != NSNotFound else { return [] }
        return Array(range.location..<range.location + range.length)
    }

    private func firstVisibleItemID() -> FileItem.ID? {
        for row in visibleRows {
            if let id = rowSpace.itemID(at: row) {
                return id
            }
        }
        return nil
    }

    // MARK: - Selection

    private var selectedItemIDs: Set<FileItem.ID> {
        var ids: Set<FileItem.ID> = []
        for row in table.selectedRowIndexes {
            if let id = rowSpace.itemID(at: row) { ids.insert(id) }
        }
        return ids
    }

    func setSelectedItemIDs(_ ids: Set<FileItem.ID>, scrollToAnchor: FileItem.ID? = nil) {
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        let rows = rowSpace.indexes(ofItems: ids)
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if let anchor = scrollToAnchor, ids.contains(anchor),
           let row = rowSpace.index(ofItem: anchor) {
            table.scrollRowToVisible(row)
        } else if let first = rows.first {
            table.scrollRowToVisible(first)
        }
    }

    // MARK: - Opening

    @objc private func doubleClicked(_ sender: Any?) {
        let inNewTab = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        open(rows: table.selectedRowIndexes, inNewTab: inNewTab)
    }

    private func open(rows: IndexSet, inNewTab: Bool) {
        guard let model else { return }
        let items = rows.compactMap { row -> FileItem? in
            guard let id = rowSpace.itemID(at: row) else { return nil }
            return model.item(withID: id)
        }
        guard let first = items.first else { return }
        onOpen?(first, inNewTab)
        for item in items.dropFirst() {
            onOpen?(item, false)
        }
    }

    // MARK: - Groups

    func toggleGroup(_ groupID: String) {
        if collapsedGroupIDs.contains(groupID) {
            collapsedGroupIDs.remove(groupID)
        } else {
            collapsedGroupIDs.insert(groupID)
        }
        handlePublish()
    }

    // MARK: - Columns

    private func rebuildColumns() {
        let previousWidths = Dictionary(uniqueKeysWithValues: table.tableColumns.map { ($0.identifier.rawValue, $0.width) })

        table.beginUpdates()
        table.tableColumns.forEach { table.removeTableColumn($0) }
        for column in columnsState {
            let tableColumn = makeColumn(column, width: previousWidths[column.rawValue] ?? column.defaultWidth)
            table.addTableColumn(tableColumn)
        }
        table.endUpdates()
    }

    private func makeColumn(_ column: FileColumn, width: CGFloat) -> NSTableColumn {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
        tableColumn.title = column.title
        tableColumn.width = width
        tableColumn.minWidth = 56
        tableColumn.resizingMask = [.userResizingMask, .autoresizingMask]
        if column.isSortable {
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
        }
        let headerCell = tableColumn.headerCell
        headerCell.font = .systemFont(ofSize: 11, weight: .semibold)
        headerCell.alignment = column == .size ? .right : .left
        return tableColumn
    }

    private func presentColumnChooser(at point: NSPoint) {
        let menu = NSMenu()
        for column in FileColumn.allCases {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumnVisibility(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = columnsState.contains(column) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let fitItem = NSMenuItem(title: "Size All Columns to Fit", action: #selector(sizeAllColumnsToFit), keyEquivalent: "")
        fitItem.target = self
        menu.addItem(fitItem)

        if let headerView = table.headerView {
            menu.popUp(positioning: nil, at: point, in: headerView)
        }
    }

    @objc private func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let column = FileColumn(rawValue: rawValue) else { return }
        if let index = columnsState.firstIndex(of: column) {
            if columnsState.count > 1 {
                columnsState.remove(at: index)
            }
        } else {
            let nameIndex = columnsState.firstIndex(of: .name) ?? -1
            columnsState.insert(column, at: nameIndex + 1)
        }
        rebuildColumns()
        handlePublish()
        reportColumnsChanged()
    }

    /// Measures visible rows and sizes every column to its widest content.
    @objc private func sizeAllColumnsToFit() {
        let rows = visibleRows
        guard !rows.isEmpty else { return }

        let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 13)

        for tableColumn in table.tableColumns {
            let column = FileColumn(rawValue: tableColumn.identifier.rawValue) ?? .name
            var width = tableColumn.title.size(withAttributes: [.font: headerFont]).width + 36
            for row in rows {
                guard let itemID = rowSpace.itemID(at: row),
                      let model, let item = model.item(withID: itemID) else { continue }
                let text = FileColumnFormatter.text(for: item, column: column)
                width = max(
                    width,
                    text.size(withAttributes: [.font: bodyFont]).width + 36
                )
            }
            tableColumn.width = min(width, 480)
        }
        reportColumnsChanged()
    }

    private func reportColumnsChanged() {
        let widths = Dictionary(
            uniqueKeysWithValues: table.tableColumns.map { ($0.identifier.rawValue, Double($0.width)) }
        )
        onColumnsChanged?(columnsState, widths)
    }

    // MARK: - Sorting

    private func syncSortIndicators() {
        guard let model else { return }
        let descriptors: [NSSortDescriptor] = model.settings.sortCriteria.compactMap { criterion in
            let column = FileColumn.allCases.first { $0.sortKey == criterion.key }
            return column.map { NSSortDescriptor(key: $0.rawValue, ascending: criterion.ascending) }
        }
        isSyncingSortDescriptors = true
        table.sortDescriptors = descriptors
        isSyncingSortDescriptors = false
    }

    // MARK: - Rename

    private func beginRenameAtRow(_ row: Int) {
        endRename()
        let cellFrame = table.frameOfCell(atColumn: 0, row: row)
        guard let itemID = rowSpace.itemID(at: row), let item = model?.item(withID: itemID) else { return }
        renamingItem = item
        let iconInset: CGFloat = 34 // 6 leading + 18 icon + 8 gap
        let fieldRect = NSRect(
            x: cellFrame.minX + iconInset,
            y: cellFrame.minY + 3,
            width: max(cellFrame.width - iconInset - 8, 150),
            height: cellFrame.height - 6
        )
        renameField.begin(in: table, rect: fieldRect, currentName: item.name)
    }

    func beginRename(for item: FileItem) {
        guard let row = rowSpace.index(ofItem: item.id) else { return }
        beginRenameAtRow(row)
    }

    func beginRenameOfFirstSelection() {
        guard let itemID = selectedItemIDs.first,
              let model, let item = model.item(withID: itemID) else { return }
        beginRename(for: item)
    }

    private func commitRename(newName: String, moveToNext: Bool) {
        guard let item = renamingItem, let model else {
            endRename()
            return
        }

        if newName == item.name {
            endRename()
            return
        }

        if let error = RenameValidator.validate(
            newName: newName,
            originalName: item.name,
            existingNames: model.snapshot.flatItems.map(\.name)
        ) {
            // Keep editing: re-present the editor (the end-editing event we're
            // inside has already torn down the first responder) and show the
            // message inline.
            DoraLog.ui.error("rename rejected: \(error, privacy: .public)")
            let invalid = newName
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.renameField.begin(
                    in: self.table,
                    rect: self.renameField.field.frame,
                    currentName: invalid
                )
                self.renameField.showError(error)
            }
            return
        }

        onRenameCommitted?(item, newName)
        renamingItem = nil
        endRename()

        if moveToNext {
            beginRenameOfNextItem(after: item)
        }
    }

    private func renameRect(for item: FileItem) -> NSRect {
        guard let row = rowSpace.index(ofItem: item.id) else { return .zero }
        let cellFrame = table.frameOfCell(atColumn: 0, row: row)
        return NSRect(
            x: cellFrame.minX + 34,
            y: cellFrame.minY + 3,
            width: max(cellFrame.width - 42, 150),
            height: cellFrame.height - 6
        )
    }

    private func showRenameError(_ message: String) {
        DoraLog.ui.error("rename rejected: \(message, privacy: .public)")
    }

    private func endRename() {
        renameField.cancel()
        renamingItem = nil
        view.window?.makeFirstResponder(table)
    }

    /// Tab during rename: commit, then roll rename to the next item row.
    private func beginRenameOfNextItem(after previous: FileItem) {
        let itemRows = rowSpace.rows.enumerated().filter {
            if case .item = $0.element { return true }
            return false
        }
        guard let current = itemRows.firstIndex(where: { row in
            if case .item(let id) = row.element { return id == previous.id }
            return false
        }), current + 1 < itemRows.count else { return }

        let nextRow = itemRows[current + 1].offset
        guard let nextID = rowSpace.itemID(at: nextRow),
              let model, let nextItem = model.item(withID: nextID) else { return }
        setSelectedItemIDs([nextID])
        beginRename(for: nextItem)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rowSpace.rows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }

        switch rowSpace.row(at: row) {
        case .groupHeader(let groupID):
            guard let group = model?.snapshot.groups.first(where: { $0.id == groupID }) else { return nil }
            let view = (tableView.makeView(withIdentifier: groupCellIdentifier, owner: self) as? GroupHeaderCellView)
                ?? GroupHeaderCellView()
            view.identifier = groupCellIdentifier
            view.configure(
                title: group.title,
                count: group.items.count,
                isCollapsed: collapsedGroupIDs.contains(groupID)
            )
            view.onToggle = { [weak self] in
                self?.toggleGroup(groupID)
            }
            return view

        case .item(let itemID):
            guard let model, let item = model.item(withID: itemID) else { return nil }
            let column = FileColumn(rawValue: tableColumn.identifier.rawValue) ?? .name

            if column == .name {
                let view = (tableView.makeView(withIdentifier: nameCellIdentifier, owner: self) as? FileNameCellView)
                    ?? FileNameCellView()
                view.identifier = nameCellIdentifier
                view.configure(item: item, name: item.displayName)
                return view
            }

            let identifier = NSUserInterfaceItemIdentifier("text-cell-\(column.rawValue)")
            let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? FileTextCellView)
                ?? FileTextCellView()
            view.identifier = identifier
            view.configure(
                text: FileColumnFormatter.text(for: item, column: column),
                alignment: column == .size ? .right : .left
            )
            return view

        case nil:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        switch rowSpace.row(at: row) {
        case .groupHeader:
            let view = (tableView.makeView(withIdentifier: groupRowIdentifier, owner: self) as? FileTableRowView)
                ?? FileTableRowView()
            view.identifier = groupRowIdentifier
            view.isGroupHeader = true
            return view
        case .item:
            let view = (tableView.makeView(withIdentifier: itemRowIdentifier, owner: self) as? FileTableRowView)
                ?? FileTableRowView()
            view.identifier = itemRowIdentifier
            view.isGroupHeader = false
            return view
        case nil:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .groupHeader = rowSpace.row(at: row) { return false }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        onSelectionChanged?(selectedItemIDs)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard let tableColumn, tableColumn.identifier.rawValue == FileColumn.name.rawValue,
              let id = rowSpace.itemID(at: row), let model,
              let item = model.item(withID: id) else { return nil }
        return item.displayName
    }
}

extension DetailsViewController: NSTableViewDataSource, NSTableViewDelegate {}

// MARK: - Sorting bridge

/// Header clicks arrive as NSSortDescriptors; Explorer's rule is: re-click
/// toggles direction, a new key becomes primary, name is always the tiebreaker.
extension DetailsViewController {
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isSyncingSortDescriptors else { return }
        var criteria: [SortCriterion] = []
        for descriptor in tableView.sortDescriptors {
            guard let key = descriptor.key,
                  let column = FileColumn(rawValue: key),
                  let sortKey = column.sortKey else { continue }
            criteria.append(SortCriterion(key: sortKey, ascending: descriptor.ascending))
        }
        guard !criteria.isEmpty else { return }

        if !criteria.contains(where: { $0.key == .name }) {
            criteria.append(SortCriterion(key: .name, ascending: true))
        }
        onSortChanged?(criteria)
        syncSortIndicators()
    }
}

// MARK: - Group header row access

extension FileRow {
    var isGroupHeaderRow: Bool {
        if case .groupHeader = self { return true }
        return false
    }
}

/// Header view that surfaces the column chooser on right-click.
@MainActor
final class ColumnChoosingHeaderView: NSTableHeaderView {
    var onRightClick: ((NSPoint) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onRightClick?(point)
    }
}
