import Foundation

/// Windows File Explorer–style file grouping for the Details view.
public enum GroupingKey: String, Codable, Sendable, CaseIterable {
    case none
    case type
    case dateModified
    case size
}

/// A bucket of items rendered under one collapsible header.
public struct ItemGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public var items: [FileItem]

    public init(id: String, title: String, items: [FileItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}
