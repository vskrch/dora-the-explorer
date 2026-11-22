import Foundation

/// Placeholder surface for the file-operation engine (Phase 9).
public enum FileOperationKind: String, Sendable, CaseIterable {
    case copy
    case move
    case trash
    case deletePermanently
    case newFolder
    case rename
    case duplicate
    case compress
    case extract
    case createAlias
    case createSymlink
}
