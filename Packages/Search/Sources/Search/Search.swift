import Foundation

/// Placeholder surface for the search engine (Phase 13).
public struct SearchScope: Sendable {
    public let root: URL
    public let descendants: Bool

    public init(root: URL, descendants: Bool) {
        self.root = root
        self.descendants = descendants
    }
}
