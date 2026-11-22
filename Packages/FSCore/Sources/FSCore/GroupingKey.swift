import Foundation

/// Windows File Explorer–style file grouping for the Details view.
public enum GroupingKey: String, Codable, Sendable, CaseIterable {
    case none
    case type
    case dateModified
    case size
}

/// A bucket of items rendered under one collapsible header.
///
/// Groups hold item IDs, not item values — the snapshot owns exactly one copy
/// of every `FileItem`; groups, row spaces and lookups all reference it.
public struct ItemGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public var ids: [FileItem.ID]

    public init(id: String, title: String, ids: [FileItem.ID]) {
        self.id = id
        self.title = title
        self.ids = ids
    }
}
