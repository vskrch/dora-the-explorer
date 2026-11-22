import Foundation

/// Sendable wrapper around `NotificationCenter` observer tokens.
final class ObserverBag: @unchecked Sendable {
    let tokens: [any NSObjectProtocol]

    init(_ tokens: [any NSObjectProtocol]) {
        self.tokens = tokens
    }
}
