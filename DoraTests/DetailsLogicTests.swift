import Foundation
import Testing
import FSCore
@testable import Dora

@Suite("File row space")
@MainActor
struct FileRowSpaceTests {
    private func snapshot(items: [(String, String)]) -> DirectorySnapshot {
        let group = ItemGroup(id: "all", title: "", items: items.map { FileItem(
            id: $0.0,
            url: URL(fileURLWithPath: "/tmp"),
            name: $0.1,
            isDirectory: false
        ) })
        return DirectorySnapshot(generation: 1, groups: [group], totalCount: items.count)
    }

    private func groupedSnapshot() -> DirectorySnapshot {
        let a = ItemGroup(id: "folders", title: "Folders", items: [
            FileItem(id: "1", url: URL(fileURLWithPath: "/tmp"), name: "A", isDirectory: true),
        ])
        let b = ItemGroup(id: "files", title: "Files", items: [
            FileItem(id: "2", url: URL(fileURLWithPath: "/tmp"), name: "B", isDirectory: false),
            FileItem(id: "3", url: URL(fileURLWithPath: "/tmp"), name: "C", isDirectory: false),
        ])
        return DirectorySnapshot(generation: 2, groups: [a, b], totalCount: 3)
    }

    @Test func ungroupedSnapshotHasNoHeaderRows() {
        let space = FileRowSpace(snapshot: snapshot(items: [("1", "a"), ("2", "b")]), collapsedGroupIDs: [])
        #expect(space.rows.count == 2)
        #expect(space.rowIndexByItemID["1"] == 0)
        #expect(space.rowIndexByItemID["2"] == 1)
    }

    @Test func groupedSnapshotInterleavesHeaders() {
        let space = FileRowSpace(snapshot: groupedSnapshot(), collapsedGroupIDs: [])
        #expect(space.rows == [
            .groupHeader(id: "folders"),
            .item(id: "1"),
            .groupHeader(id: "files"),
            .item(id: "2"),
            .item(id: "3"),
        ])
    }

    @Test func collapsedGroupHidesItemsButKeepsHeader() {
        let space = FileRowSpace(snapshot: groupedSnapshot(), collapsedGroupIDs: ["files"])
        #expect(space.rows == [
            .groupHeader(id: "folders"),
            .item(id: "1"),
            .groupHeader(id: "files"),
        ])
        #expect(space.rowIndexByItemID["2"] == nil)
    }

    @Test func indexLookupAndItemIDRoundTrip() {
        let space = FileRowSpace(snapshot: groupedSnapshot(), collapsedGroupIDs: [])
        #expect(space.itemID(at: 0) == nil)
        #expect(space.itemID(at: 1) == "1")
        #expect(space.index(ofItem: "3") == 4)
        let indexes = space.indexes(ofItems: ["1", "3"])
        #expect(indexes == IndexSet([1, 4]))
    }

    @Test func outOfRangeQueriesAreSafe() {
        let space = FileRowSpace(snapshot: snapshot(items: [("1", "a")]), collapsedGroupIDs: [])
        #expect(space.row(at: -1) == nil)
        #expect(space.row(at: 99) == nil)
        #expect(space.itemID(at: 99) == nil)
    }
}

@Suite("Rename validation")
struct RenameValidatorTests {
    @Test func rejectsEmptyNames() {
        #expect(RenameValidator.validate(newName: "  ", originalName: "a.txt", existingNames: []) != nil)
    }

    @Test func rejectsSeparators() {
        #expect(RenameValidator.validate(newName: "a/b.txt", originalName: "a.txt", existingNames: []) != nil)
        let illegal = RenameValidator.illegalCharacters(in: "x/y\u{0}")
        #expect(illegal == ["/", "\u{0}"])
    }

    @Test func rejectsCaseInsensitiveDuplicates() {
        let error = RenameValidator.validate(
            newName: "READ ME.md",
            originalName: "intro.md",
            existingNames: ["read me.md"]
        )
        #expect(error != nil)
    }

    @Test func allowsCaseOnlyChange() {
        let error = RenameValidator.validate(
            newName: "READ ME.md",
            originalName: "read me.md",
            existingNames: ["read me.md"]
        )
        #expect(error == nil)
    }

    @Test func allowsNovelName() {
        let error = RenameValidator.validate(
            newName: "Fresh Name.txt",
            originalName: "old.txt",
            existingNames: ["other.txt", "old.txt"]
        )
        #expect(error == nil)
    }
}

@Suite("Columns")
@MainActor
struct FileColumnTests {
    @Test func orderedFallsBackToDefaults() {
        #expect(FileColumn.ordered(["type", "name"]) == [.type, .name])
        #expect(FileColumn.ordered(["bogus"]) == FileColumn.defaultOrder)
        #expect(FileColumn.ordered([]) == FileColumn.defaultOrder)
    }

    @Test func sortableKeysCoverStandardSortCriteria() {
        let known: Set<SortCriterion.Key> = [.name, .dateModified, .dateCreated, .dateAdded, .type, .size]
        for column in FileColumn.allCases where column.isSortable {
            #expect(known.contains(column.sortKey!))
        }
    }

    @Test func folderSizeShowsDash() {
        let folder = FileItem(id: "1", url: URL(fileURLWithPath: "/tmp"), name: "F", isDirectory: true)
        #expect(FileColumnFormatter.text(for: folder, column: .size) == "—")
        #expect(FileColumnFormatter.text(for: folder, column: .type) == "File folder")
    }
}

@Suite("Folder view store")
@MainActor
struct FolderViewStoreTests {
    @Test func roundTripsEntriesPerFolder() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dora-tests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FolderViewStore(url: url)
        let folder = URL(fileURLWithPath: "/Users/test/Pictures")
        let entry = FolderViewStore.Entry(
            sortCriteria: [SortCriterion(key: .size, ascending: false)],
            grouping: .type,
            columns: ["name", "size"],
            columnWidths: ["name": 240],
            showHidden: true
        )
        store.save(entry, for: folder)
        store.flushNow()

        let reopened = FolderViewStore(url: url)
        let loaded = reopened.entry(for: folder)
        #expect(loaded != nil)
        #expect(loaded?.grouping == .type)
        #expect(loaded?.columns == ["name", "size"])
        #expect(loaded?.showHidden == true)
        #expect(loaded?.columnWidths?["name"] == 240)
        #expect(loaded?.sortCriteria == [SortCriterion(key: .size, ascending: false)])
    }
}
