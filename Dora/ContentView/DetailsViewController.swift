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
    /// The host mirrors collapse state per tab.
    var onGroupToggled: ((_ groupID: String) -> Void)?
    /// Backspace in the table asks the chrome to navigate back.
    var onNavigateBack: (() -> Void)?
    /// Files dropped onto a folder row or the background: urls, destination, move-vs-copy.
    var onDropFiles: ((_ urls: [URL], _ destination: URL, _ asMove: Bool) -> Void)?
    /// Context-menu clipboard intents.
    var onClipboardAction: ((_ intent: ClipboardIntent) -> Void)?
    var onNewFolderRequested: (() -> Void)?
    var onToggleHiddenRequested: (() -> Void)?
    var onRefreshRequested: (() -> Void)?

    enum ClipboardIntent {
        case cut, copy, paste, trash
    }

    private var cutPaths: Set<String> = []
    /// Drag-pasteboard reads cached per session: `validateDrop` fires on every
    /// drag-motion row crossing and each uncached read is a pasteboard-server
    /// round trip. Keyed by the stable pasteboard name of the session.
    private var draggedURLsBySession: [String: [URL]] = [:]

    private(set) var model: DirectoryModel?

    let scrollView = NSScrollView()
    let table = FileTableView()
    private var rowSpace = FileRowSpace(snapshot: DirectorySnapshot.empty, collapsedGroupIDs: [])
    private var collapsedGroupIDs: Set<String> = []
    /// Generation of the snapshot last applied to the table. Rows can be
    /// identical across publishes (metadata-only refresh) while the cell
    /// content still needs repainting — generation is the tell.
    private var lastAppliedGeneration: UInt64?
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
        table.onNavigateBack = { [weak self] in
            self?.onNavigateBack?()
        }
        table.onContextMenu = { [weak self] event in
            guard let self else { return nil }
            return self.menu(for: event, in: self.table)
        }

        renameField.onCommit = { [weak self] newName, moveToNext in
            self?.commitRename(newName: newName, moveToNext: moveToNext)
        }
        renameField.onCancel = { [weak self] in
            self?.endRename()
        }

        // Drop target: files from anywhere (Finder, other Dora windows).
        table.registerForDraggedTypes([.fileURL])

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
        let modelChanged = model !== self.model
        let columnsChanged = columnsState != columns

        guard modelChanged || columnsChanged else {
            // Same model, same columns (the common navigation/tab-switch case):
            // keep columns exactly as they are, including user reordering.
            return
        }

        self.model?.onPublish = nil
        self.model = model
        if columnsChanged {
            columnsState = columns
            rebuildColumns()
        }
        // Fresh model or fresh columns — either way the indicators must
        // track the (possibly different) sort of the attached model.
        syncSortIndicators()
    }

    /// Applies a fresh snapshot with ID-addressed selection and a captured
    /// viewport anchor. The caller (the container) owns selection state —
    /// the table never derives selection from indexes across publishes.
    ///
    /// Incremental updates: watcher events usually change a handful of rows,
    /// so a prefix/suffix splice is applied with insert/remove instead of a
    /// full `reloadData()` — the Finder-grade behavior AppKit recommends.
    func applySnapshot(
        snapshot: DirectorySnapshot,
        selection itemIDs: Set<FileItem.ID>,
        collapsedGroupIDs: Set<String>,
        anchorItemID: FileItem.ID?
    ) {
        let state = signposter.beginInterval("details.rebuild")
        defer { signposter.endInterval("details.rebuild", state) }

        self.collapsedGroupIDs = collapsedGroupIDs
        let oldRows = rowSpace.rows
        let newSpace = FileRowSpace(snapshot: snapshot, collapsedGroupIDs: collapsedGroupIDs)

        // Swap the row space BEFORE touching the table: endUpdates() posts
        // selection change synchronously, and remapping through a stale row
        // space corrupts the tab's selection set (probe-verified order).
        rowSpace = newSpace

        // Selection bookkeeping runs inside this bracket — splice, reload and
        // reapply all adjust selection, and none of those notifications may
        // write back an intermediate state.
        isSyncingSelection = true
        let transition = Self.rowTransition(from: oldRows, to: newSpace.rows)
        applyRowTransition(transition)
        if Self.needsVisibleRowRefresh(
            transition: transition,
            oldGeneration: lastAppliedGeneration,
            newGeneration: snapshot.generation
        ) {
            // Identical rows, new content (a watcher metadata refresh): row
            // identity didn't change, so the splice machinery is a no-op —
            // reconfigure the visible cells only, keeping selection and
            // viewport untouched.
            let visible = table.rows(in: table.visibleRect)
            if visible.location != NSNotFound, visible.length > 0 {
                let rows = IndexSet(
                    integersIn: visible.location..<min(visible.location + visible.length, table.numberOfRows)
                )
                let columns = IndexSet(integersIn: 0..<max(table.tableColumns.count, 1))
                table.reloadData(forRowIndexes: rows, columnIndexes: columns)
            }
        }
        lastAppliedGeneration = snapshot.generation
        let rows = rowSpace.indexes(ofItems: itemIDs)
        if table.selectedRowIndexes != rows {
            table.selectRowIndexes(rows, byExtendingSelection: false)
        }
        isSyncingSelection = false

        // Keep the viewport pinned: restore the anchor only if the update
        // displaced it; never yank to the selection.
        if let anchorItemID, let row = rowSpace.index(ofItem: anchorItemID) {
            let visible = table.rows(in: table.visibleRect)
            if visible.location == NSNotFound || row < visible.location || row >= visible.location + visible.length {
                table.scrollRowToVisible(row)
            }
        }
    }

    /// Small-edit splice: identical rows keep their place; only the middle
    /// span between the common prefix/suffix is replaced. Falls back to a
    /// full reload when the edit is large (sort change, folder switch).
    static func rowTransition(from oldRows: [FileRow], to newRows: [FileRow]) -> RowTransition {
        guard oldRows != newRows else { return .none }
        guard !oldRows.isEmpty || !newRows.isEmpty else { return .none }

        // Common prefix.
        var prefix = 0
        while prefix < oldRows.count && prefix < newRows.count && oldRows[prefix] == newRows[prefix] {
            prefix += 1
        }
        // Common suffix (not overlapping the prefix).
        var suffix = 0
        while suffix < oldRows.count - prefix && suffix < newRows.count - prefix,
              oldRows[oldRows.count - 1 - suffix] == newRows[newRows.count - 1 - suffix] {
            suffix += 1
        }

        let removedCount = oldRows.count - prefix - suffix
        let insertedCount = newRows.count - prefix - suffix

        // Big structural change: one reload is cheaper and avoids visible
        // row thrash (Explorer does the same on sort/group switches).
        if removedCount + insertedCount > (oldRows.count / 3), removedCount + insertedCount > 64 {
            return .reload
        }
        guard removedCount > 0 || insertedCount > 0 else { return .none }
        return .splice(prefix: prefix, removed: removedCount, inserted: insertedCount)
    }

    enum RowTransition: Equatable {
        case none
        case splice(prefix: Int, removed: Int, inserted: Int)
        case reload
    }

    /// Identical rows can still mean changed cells: publishes with a fresh
    /// generation but the same row ids are metadata-only refreshes (a file's
    /// date/size changed without reordering), and the already-configured
    /// cells would keep showing stale text forever without this repainting
    /// pass. Same-generation re-applies (column changes restore) don't need
    /// it, and row-changing transitions rebuild cells through their own path.
    static func needsVisibleRowRefresh(
        transition: RowTransition,
        oldGeneration: UInt64?,
        newGeneration: UInt64
    ) -> Bool {
        guard case .none = transition else { return false }
        return oldGeneration != newGeneration
    }

    private func applyRowTransition(_ transition: RowTransition) {
        switch transition {
        case .none:
            return
        case .reload:
            table.reloadData()
        case .splice(let prefix, let removed, let inserted):
            table.beginUpdates()
            if removed > 0 {
                table.removeRows(at: IndexSet(integersIn: prefix..<(prefix + removed)), withAnimation: [])
            }
            if inserted > 0 {
                table.insertRows(at: IndexSet(integersIn: prefix..<(prefix + inserted)), withAnimation: [])
            }
            table.endUpdates()
        }
    }

    /// Anchor to preserve across the next publish: the first visible item.
    var visibleAnchorItemID: FileItem.ID? {
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return nil }
        for row in visible.location..<visible.location + visible.length {
            if let id = rowSpace.itemID(at: row) {
                return id
            }
        }
        return nil
    }

    // MARK: - Selection

    /// IDs selected per the current table state (for reporting user changes;
    /// restores never read from the table).
    private var tableSelectionIDs: Set<FileItem.ID> {
        var ids: Set<FileItem.ID> = []
        for row in table.selectedRowIndexes {
            if let id = rowSpace.itemID(at: row) { ids.insert(id) }
        }
        return ids
    }

    /// Programmatically selects by ID; only scrolls when asked to reveal an
    /// anchor (tab restore, rename roll).
    func setSelectedItemIDs(_ ids: Set<FileItem.ID>, revealingAnchor anchor: FileItem.ID? = nil) {
        isSyncingSelection = true
        table.selectRowIndexes(rowSpace.indexes(ofItems: ids), byExtendingSelection: false)
        if let anchor, let row = rowSpace.index(ofItem: anchor) {
            table.scrollRowToVisible(row)
        }
        isSyncingSelection = false
    }

    // MARK: - Opening

    @objc private func doubleClicked(_ sender: Any?) {
        // Cmd+double-click opens the folder under the cursor in a new tab,
        // leaving the selection untouched (Explorer behaviour); a plain
        // double-click opens the selection as usual.
        let inNewTab = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if inNewTab, table.clickedRow >= 0,
           let id = rowSpace.itemID(at: table.clickedRow),
           let item = model?.item(withID: id) {
            onOpen?(item, true)
        } else {
            open(rows: table.selectedRowIndexes, inNewTab: false)
        }
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

    private func toggleGroup(_ groupID: String) {
        if collapsedGroupIDs.contains(groupID) {
            collapsedGroupIDs.remove(groupID)
        } else {
            collapsedGroupIDs.insert(groupID)
        }
        onGroupToggled?(groupID)
        guard let snapshot = model?.snapshot else { return }
        applySnapshot(
            snapshot: snapshot,
            selection: tableSelectionIDs,
            collapsedGroupIDs: collapsedGroupIDs,
            anchorItemID: visibleAnchorItemID
        )
    }

    /// Applies persisted per-folder column widths after attach.
    func applyColumnWidths(_ widths: [String: Double]) {
        guard !widths.isEmpty else { return }
        for tableColumn in table.tableColumns {
            if let width = widths[tableColumn.identifier.rawValue] {
                tableColumn.width = CGFloat(width)
            }
        }
    }

    /// Re-applies the current snapshot after a structural column change.
    private func refreshAfterColumnChange() {
        guard let snapshot = model?.snapshot else { return }
        applySnapshot(
            snapshot: snapshot,
            selection: tableSelectionIDs,
            collapsedGroupIDs: collapsedGroupIDs,
            anchorItemID: visibleAnchorItemID
        )
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
        // The Name column is the identity of the view; it can't be removed.
        guard column != .name else { return }
        if let index = columnsState.firstIndex(of: column) {
            columnsState.remove(at: index)
        } else {
            let nameIndex = columnsState.firstIndex(of: .name) ?? -1
            columnsState.insert(column, at: nameIndex + 1)
        }
        rebuildColumns()
        refreshAfterColumnChange()
        reportColumnsChanged()
    }

    /// Measures visible rows and sizes every column to its widest content.
    @objc private func sizeAllColumnsToFit() {
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return }
        let rows = Array(visible.location..<visible.location + visible.length)

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
        guard let itemID = tableSelectionIDs.first,
              let model, let item = model.item(withID: itemID) else { return }
        beginRename(for: item)
    }

    private func commitRename(newName: String, moveToNext: Bool) {
        guard let item = renamingItem, let model else {
            endRename()
            return
        }

        // The committed value is whitespace-trimmed, matching validation.
        let proposed = newName.trimmingCharacters(in: .whitespaces)
        if proposed == item.name {
            endRename()
            return
        }

        if let error = RenameValidator.validate(
            newName: proposed,
            originalName: item.name,
            existingNames: model.snapshot.items.map(\.name)
        ) {
            // Keep editing: re-present the editor (the end-editing event we're
            // inside has already torn down the first responder) and show the
            // message inline.
            DoraLog.ui.error("rename rejected: \(error, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.renameField.begin(
                    in: self.table,
                    rect: self.renameField.field.frame,
                    currentName: proposed
                )
                self.renameField.showError(error)
            }
            return
        }

        onRenameCommitted?(item, proposed)
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
        setSelectedItemIDs([nextID], revealingAnchor: nextID)
        beginRename(for: nextItem)
    }

    /// Explorer-style cut ghosting: cut items render dimmed.
    func setCutPaths(_ paths: Set<String>) {
        cutPaths = paths
        refreshAfterColumnChange()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rowSpace.rows.count
    }

    /// Drag source: every item row can be dragged out (Finder, other apps).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardItem? {
        guard let id = rowSpace.itemID(at: row), let model,
              let item = model.item(withID: id) else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.url.path, forType: .fileURL)
        return pasteboardItem
    }

    // MARK: - Drop destination

    /// Mount-point heuristic (no I/O): items share a volume when their first
    /// path component matches (/ vs /Volumes/<name>). Good enough to choose
    /// move-vs-copy defaults; the engine still handles real cross-volume moves.
    private static func isSameVolume(_ lhs: URL, _ rhs: URL) -> Bool {
        func volumeKey(_ url: URL) -> String {
            let parts = url.pathComponents
            if parts.count >= 3, parts[0] == "/", parts[1] == "Volumes" {
                return "/" + parts[1] + "/" + parts[2]
            }
            return "/"
        }
        return volumeKey(lhs) == volumeKey(rhs)
    }

    private func dropTargetFolder(for row: Int, operation: NSTableView.DropOperation, directory: URL) -> URL? {
        if operation == .on, let id = rowSpace.itemID(at: row), let model,
           let item = model.item(withID: id), item.isDirectory {
            return item.url
        }
        // Background, .above, or a non-folder row: the current directory.
        return directory
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard let urls = cachedDraggedFileURLs(for: info), !urls.isEmpty,
              let currentDirectory = model?.directory,
              let destination = dropTargetFolder(for: row, operation: operation, directory: currentDirectory) else {
            return []
        }

        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        let allSameVolume = urls.allSatisfy { Self.isSameVolume($0, destination) }
        if modifiers.contains(.option) { return .copy }
        if modifiers.contains(.command) { return .move }
        return allSameVolume ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        guard let urls = cachedDraggedFileURLs(for: info), !urls.isEmpty,
              let currentDirectory = model?.directory,
              let destination = dropTargetFolder(for: row, operation: operation, directory: currentDirectory) else {
            return false
        }

        // Dragging a folder onto itself: no-op.
        if urls.contains(destination) { return true }

        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        let allSameVolume = urls.allSatisfy { Self.isSameVolume($0, destination) }
        let asMove: Bool
        if modifiers.contains(.option) {
            asMove = false
        } else if modifiers.contains(.command) {
            asMove = true
        } else {
            asMove = allSameVolume
        }

        onDropFiles?(urls, destination, asMove)
        return true
    }
}

@MainActor
extension NSDraggingInfo {
    /// File URLs on the drag pasteboard, or nil when there are none.
    func readDraggedFileURLs() -> [URL]? {
        let urls = draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.isEmpty ? nil : urls
    }
}

extension DetailsViewController {
    /// Session-stable URL cache for the active drag. Drag sessions are
    /// sequential and few; bound the cache so it can never accumulate.
    private func cachedDraggedFileURLs(for info: any NSDraggingInfo) -> [URL]? {
        let key = info.draggingPasteboard.name.rawValue
        if let cached = draggedURLsBySession[key] {
            return cached
        }
        guard let urls = info.readDraggedFileURLs() else { return nil }
        if draggedURLsBySession.count > 3 { draggedURLsBySession.removeAll() }
        draggedURLsBySession[key] = urls
        return urls
    }
}

extension DetailsViewController {
    // MARK: - Context menus

    /// Right-click on rows: Explorer's action set over the current selection.
    func menu(for event: NSEvent, in tableView: NSTableView) -> NSMenu? {
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point)
        if row >= 0, let id = rowSpace.itemID(at: row) {
            // Right-clicking an unselected row select it first (Windows).
            if !tableView.selectedRowIndexes.contains(row) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            return itemContextMenu(for: id)
        }
        return backgroundContextMenu()
    }

    private func itemContextMenu(for itemID: FileItem.ID) -> NSMenu {
        let menu = NSMenu()

        let items = tableSelectionIDs.compactMap { model?.item(withID: $0) }
        guard let primary = model?.item(withID: itemID) ?? items.first else { return menu }
        let selection = items.isEmpty ? [primary] : items

        menu.addItem(makeItem("Open", action: #selector(contextOpen(_:)), represented: primary.url.path, enabled: true))
        if primary.isDirectory {
            menu.addItem(makeItem("Open in New Tab", action: #selector(contextOpenInNewTab(_:)), represented: primary.url.path, enabled: true))
        }
        menu.addItem(.separator())

        menu.addItem(makeItem("Cut", action: #selector(contextCut(_:)), represented: nil, enabled: !selection.isEmpty))
        menu.addItem(makeItem("Copy", action: #selector(contextCopy(_:)), represented: nil, enabled: !selection.isEmpty))
        menu.addItem(makeItem("Paste", action: #selector(contextPaste(_:)), represented: nil, enabled: clipboardHasFiles()))
        menu.addItem(.separator())

        if selection.count == 1 {
            menu.addItem(makeItem("Rename…", action: #selector(contextRename(_:)), represented: primary.id, enabled: true))
        }
        menu.addItem(makeItem("Move to Trash", action: #selector(contextTrash(_:)), represented: nil, enabled: !selection.isEmpty))
        menu.addItem(.separator())

        menu.addItem(makeItem("Copy as Pathname", action: #selector(contextCopyPath(_:)), represented: selection.map(\.url.path), enabled: true))
        menu.addItem(makeItem("Show in Finder", action: #selector(contextRevealInFinder(_:)), represented: selection.map(\.url.path), enabled: true))

        return menu
    }

    private func backgroundContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeItem("New Folder", action: #selector(contextNewFolder(_:)), represented: nil, enabled: true))
        menu.addItem(makeItem("Paste", action: #selector(contextPaste(_:)), represented: nil, enabled: clipboardHasFiles()))
        menu.addItem(.separator())
        let hiddenTitle = model?.settings.showHidden == true ? "Hide Hidden Items" : "Show Hidden Items"
        menu.addItem(makeItem(hiddenTitle, action: #selector(contextToggleHidden(_:)), represented: nil, enabled: true))
        menu.addItem(makeItem("Refresh", action: #selector(contextRefresh(_:)), represented: nil, enabled: true))
        return menu
    }

    private func makeItem(_ title: String, action: Selector, represented: Any?, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        item.representedObject = represented
        return item
    }

    private func clipboardHasFiles() -> Bool {
        NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.isEmpty == false
    }

    // MARK: - Context actions

    @objc private func contextOpen(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let item = model?.snapshot.items.first(where: { $0.url.path == path }) else { return }
        onOpen?(item, false)
    }

    @objc private func contextOpenInNewTab(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let item = model?.snapshot.items.first(where: { $0.url.path == path }) else { return }
        onOpen?(item, true)
    }

    @objc private func contextCut(_ sender: NSMenuItem) { onClipboardAction?(.cut) }
    @objc private func contextCopy(_ sender: NSMenuItem) { onClipboardAction?(.copy) }
    @objc private func contextPaste(_ sender: NSMenuItem) { onClipboardAction?(.paste) }
    @objc private func contextTrash(_ sender: NSMenuItem) { onClipboardAction?(.trash) }
    @objc private func contextNewFolder(_ sender: NSMenuItem) { onNewFolderRequested?() }
    @objc private func contextToggleHidden(_ sender: NSMenuItem) { onToggleHiddenRequested?() }
    @objc private func contextRefresh(_ sender: NSMenuItem) { onRefreshRequested?() }

    @objc private func contextRename(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = model?.item(withID: id) else { return }
        beginRename(for: item)
    }

    @objc private func contextCopyPath(_ sender: NSMenuItem) {
        guard let paths = sender.representedObject as? [String], !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.first ?? "", forType: .string)
    }

    @objc private func contextRevealInFinder(_ sender: NSMenuItem) {
        guard let paths = sender.representedObject as? [String], !paths.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
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
                count: group.ids.count,
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
                view.nameLabel.stringValue = item.displayName
                view.setAccessibilityLabel(item.displayName)
                view.setAccessibilityValue(item.typeDescription)
                view.setCutAppearance(cutPaths.contains(item.url.path))
                ThumbnailCoordinator.shared.decorate(cell: view, item: item)
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
            // Lets the header use the standard group-row background rendering
            // (which also paints while floating over scrolled content).
            view.isGroupRowStyle = true
            return view
        case .item:
            let view = (tableView.makeView(withIdentifier: itemRowIdentifier, owner: self) as? FileTableRowView)
                ?? FileTableRowView()
            view.identifier = itemRowIdentifier
            view.isGroupHeader = false
            view.isGroupRowStyle = false
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
        onSelectionChanged?(tableSelectionIDs)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        // Explorer type-selects by name regardless of which column is
        // active or sorted.
        guard let id = rowSpace.itemID(at: row), let model,
              let item = model.item(withID: id) else { return nil }
        return item.displayName
    }

    /// Floating group headers (the Explorer signature scroll polish): the
    /// delegate answering YES enables them; `floatsGroupRows` defaults on.
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .groupHeader = rowSpace.row(at: row) { return true }
        return false
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
