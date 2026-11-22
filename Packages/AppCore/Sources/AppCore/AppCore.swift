import Foundation

/// Placeholder surface for window/tab state (Phase 2) and the command registry (Phase 8).
public enum ViewKind: String, Sendable, Codable, CaseIterable {
    case details, iconsExtraLarge, iconsLarge, iconsMedium, iconsSmall, list, tiles, content
}

public enum SortKey: String, Sendable, Codable, CaseIterable {
    case name, dateModified, type, size
}

public struct SortDescriptorValue: Sendable, Codable, Equatable {
    public var key: SortKey
    public var ascending: Bool

    public init(key: SortKey, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }
}
