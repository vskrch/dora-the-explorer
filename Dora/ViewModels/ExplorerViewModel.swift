import AppKit
import Foundation
import SwiftUI

@MainActor
final class ExplorerViewModel: ObservableObject {
    @Published private(set) var currentURL: URL
    @Published private(set) var items: [FileItem] = []
    @Published var selectedIDs: Set<FileItem.ID> = []
    @Published var viewMode: ViewMode = .details
    @Published var sortColumn: SortColumn = .name
    @Published var sortAscending: Bool = true
    @Published var showHidden: Bool = false
    @Published var searchText: String = ""
    @Published var errorMessage: String?
    @Published var statusMessage: String = "Ready"
    @Published var isLoading: Bool = false
    @Published var renamingItemID: FileItem.ID?
    @Published var renameDraft: String = ""
    @Published var navDestinations: [NavDestination] = []
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false
    @Published private(set) var canGoUp: Bool = false

    private let fileSystem: FileSystemService
    private let clipboard: ClipboardService
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    init(
        fileSystem: FileSystemService = FileSystemService(),
        clipboard: ClipboardService = ClipboardService(),
        initialURL: URL? = nil
    ) {
        self.fileSystem = fileSystem
        self.clipboard = clipboard
        self.currentURL = initialURL ?? fileSystem.homeURL()
        self.navDestinations = fileSystem.standardDestinations()
        refresh(recordHistory: false)
    }

    var selectedItems: [FileItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    var visibleItems: [FileItem] {
        let filtered: [FileItem]
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = items
        } else {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            filtered = items.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        return sort(filtered)
    }

    var breadcrumbParts: [(title: String, url: URL)] {
        var parts: [(String, URL)] = []
        var url = currentURL.standardizedFileURL
        let root = URL(fileURLWithPath: "/")
        while true {
            let title = url.path == "/" ? "Macintosh HD" : url.lastPathComponent
            parts.append((title, url))
            if url.path == root.path { break }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return parts.reversed()
    }

    var itemCountLabel: String {
        let count = visibleItems.count
        let selected = selectedIDs.count
        if selected > 0 {
            return "\(selected) item\(selected == 1 ? "" : "s") selected"
        }
        return "\(count) item\(count == 1 ? "" : "s")"
    }

    func refresh(recordHistory: Bool = false) {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            items = try fileSystem.listContents(of: currentURL, showHidden: showHidden)
            selectedIDs = selectedIDs.filter { id in items.contains(where: { $0.id == id }) }
            canGoUp = fileSystem.parent(of: currentURL) != nil
            canGoBack = !backStack.isEmpty
            canGoForward = !forwardStack.isEmpty
            statusMessage = "\(itemCountLabel)  |  \(currentURL.path)"
            #if DEBUG
            fputs("[Dora] listed \(items.count) items in \(currentURL.path)\n", stderr)
            #endif
        } catch {
            items = []
            errorMessage = error.localizedDescription
            statusMessage = "Error"
            fputs("[Dora] list failed: \(error.localizedDescription)\n", stderr)
        }
    }

    func navigate(to url: URL, recordHistory: Bool = true) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            errorMessage = "Path not found: \(url.path)"
            return
        }
        if !isDir.boolValue {
            NSWorkspace.shared.open(url)
            return
        }

        let standardized = url.standardizedFileURL
        if recordHistory, standardized != currentURL {
            backStack.append(currentURL)
            forwardStack.removeAll()
        }
        currentURL = standardized
        selectedIDs.removeAll()
        searchText = ""
        renamingItemID = nil
        refresh(recordHistory: false)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentURL)
        currentURL = previous
        selectedIDs.removeAll()
        refresh(recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentURL)
        currentURL = next
        selectedIDs.removeAll()
        refresh(recordHistory: false)
    }

    func goUp() {
        guard let parent = fileSystem.parent(of: currentURL) else { return }
        navigate(to: parent)
    }

    func open(_ item: FileItem) {
        if item.isDirectory {
            navigate(to: item.url)
        } else {
            fileSystem.open(item)
        }
    }

    func toggleSort(_ column: SortColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = true
        }
    }

    func selectAll() {
        selectedIDs = Set(visibleItems.map(\.id))
    }

    func beginRename() {
        guard let item = selectedItems.first else { return }
        renamingItemID = item.id
        renameDraft = item.name
    }

    func commitRename() {
        guard let id = renamingItemID,
              let item = items.first(where: { $0.id == id }) else {
            cancelRename()
            return
        }
        do {
            let newURL = try fileSystem.rename(item, to: renameDraft)
            renamingItemID = nil
            renameDraft = ""
            refresh()
            selectedIDs = [newURL]
            statusMessage = "Renamed to \(newURL.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelRename() {
        renamingItemID = nil
        renameDraft = ""
    }

    func createNewFolder() {
        do {
            let url = try fileSystem.createFolder(in: currentURL)
            refresh()
            selectedIDs = [url]
            beginRename()
            statusMessage = "Created \(url.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelected() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = targets.count == 1
            ? "Move “\(targets[0].name)” to the Trash?"
            : "Move \(targets.count) items to the Trash?"
        alert.informativeText = "You can restore them from the Trash later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try fileSystem.moveToTrash(targets)
            selectedIDs.removeAll()
            refresh()
            statusMessage = "Moved to Trash"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copySelected() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        clipboard.write(targets, mode: .copy)
        statusMessage = "Copied \(targets.count) item\(targets.count == 1 ? "" : "s")"
    }

    func cutSelected() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        clipboard.write(targets, mode: .cut)
        statusMessage = "Cut \(targets.count) item\(targets.count == 1 ? "" : "s")"
    }

    func paste() {
        guard let payload = clipboard.read() else {
            statusMessage = "Clipboard is empty"
            return
        }
        let items = payload.urls.map { url -> FileItem in
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return FileItem(
                id: url,
                url: url,
                name: url.lastPathComponent,
                isDirectory: isDir.boolValue,
                isHidden: url.lastPathComponent.hasPrefix("."),
                fileSize: nil,
                modifiedDate: nil,
                createdDate: nil,
                contentType: nil
            )
        }
        do {
            switch payload.mode {
            case .copy:
                try fileSystem.copy(items, to: currentURL)
                statusMessage = "Pasted \(items.count) item\(items.count == 1 ? "" : "s")"
            case .cut:
                try fileSystem.move(items, to: currentURL)
                clipboard.clearCutMarker()
                statusMessage = "Moved \(items.count) item\(items.count == 1 ? "" : "s")"
            }
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealSelectedInFinder() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else {
            fileSystem.revealInFinder([currentURL])
            return
        }
        fileSystem.revealInFinder(urls)
    }

    func handleDrop(urls: [URL]) {
        let items = urls.map { url -> FileItem in
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return FileItem(
                id: url,
                url: url,
                name: url.lastPathComponent,
                isDirectory: isDir.boolValue,
                isHidden: false,
                fileSize: nil,
                modifiedDate: nil,
                createdDate: nil,
                contentType: nil
            )
        }
        do {
            try fileSystem.copy(items, to: currentURL)
            refresh()
            statusMessage = "Imported \(items.count) item\(items.count == 1 ? "" : "s")"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sort(_ items: [FileItem]) -> [FileItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            let ascending: Bool
            switch sortColumn {
            case .name:
                ascending = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .modified:
                ascending = (lhs.modifiedDate ?? .distantPast) < (rhs.modifiedDate ?? .distantPast)
            case .type:
                ascending = lhs.typeDescription.localizedStandardCompare(rhs.typeDescription) == .orderedAscending
            case .size:
                ascending = (lhs.fileSize ?? -1) < (rhs.fileSize ?? -1)
            }
            return sortAscending ? ascending : !ascending
        }
    }
}
