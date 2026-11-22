import Foundation

/// Placeholder surface for archive browsing (Phase 15, libarchive-backed).
public enum ArchiveFormat: String, Sendable, CaseIterable {
    case zip, sevenZip, tar, tarGzip, tarXz, tarBzip2, zstd, rar
}
