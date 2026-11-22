import Foundation
import FSCore

/// A row in the flat coordinate space the table renders.
/// Identity is by item/group id, never by index, so sorting, live updates and
/// regrouping keep selection and scroll anchors valid.
public enum FileRow: Hashable, Sendable {
    case groupHeader(id: String)
    case item(id: FileItem.ID)
}

/// Flattens a `DirectorySnapshot` into the exact row sequence a content view
/// shows, honouring collapsed groups. Row space is rebuilt on every publish;
/// lookups are O(1) dictionaries, safe for 100k-item folders.
@MainActor
public struct FileRowSpace {
    public let rows: [FileRow]
    public let rowIndexByItemID: [FileItem.ID: Int]

    public init(snapshot: DirectorySnapshot, collapsedGroupIDs: Set<String>) {
        var rows: [FileRow] = []
        var indexByID: [FileItem.ID: Int] = [:]
        indexByID.reserveCapacity(snapshot.totalCount)

        for group in snapshot.groups {
            let isCollapsed = collapsedGroupIDs.contains(group.id)
            if snapshot.groups.count > 1 || !group.title.isEmpty {
                rows.append(.groupHeader(id: group.id))
            }
            guard !isCollapsed else { continue }
            for item in group.items {
                indexByID[item.id] = rows.count
                rows.append(.item(id: item.id))
            }
        }

        self.rows = rows
        self.rowIndexByItemID = indexByID
    }

    public var itemCount: Int { rowIndexByItemID.count }

    public func row(at index: Int) -> FileRow? {
        rows.indices.contains(index) ? rows[index] : nil
    }

    public func itemID(at index: Int) -> FileItem.ID? {
        guard rows.indices.contains(index), case .item(let id) = rows[index] else { return nil }
        return id
    }

    public func index(ofItem id: FileItem.ID) -> Int? {
        rowIndexByItemID[id]
    }

    /// Rows that should be selected for the given item ids.
    public func indexes(ofItems ids: Set<FileItem.ID>) -> IndexSet {
        var result = IndexSet()
        for id in ids {
            if let index = rowIndexByItemID[id] {
                result.insert(index)
            }
        }
        return result
    }
}
