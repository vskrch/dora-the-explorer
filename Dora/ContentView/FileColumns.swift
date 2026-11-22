import AppKit
import Foundation
import FSCore
import UniformTypeIdentifiers

/// The set of columns the Details view can show. Heavy metadata columns
/// (dimensions, duration, git status…) join this list when their lazy
/// metadata services land; `text(for:)` falls back to "—" meanwhile.
enum FileColumn: String, CaseIterable, Sendable {
    case name
    case dateModified
    case dateCreated
    case dateAdded
    case type
    case size
    case tags

    var title: String {
        switch self {
        case .name: return "Name"
        case .dateModified: return "Date Modified"
        case .dateCreated: return "Date Created"
        case .dateAdded: return "Date Added"
        case .type: return "Type"
        case .size: return "Size"
        case .tags: return "Tags"
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .name: return 300
        case .dateModified, .dateCreated, .dateAdded: return 150
        case .type: return 140
        case .size: return 90
        case .tags: return 110
        }
    }

    var sortKey: SortCriterion.Key? {
        switch self {
        case .name: return .name
        case .dateModified: return .dateModified
        case .dateCreated: return .dateCreated
        case .dateAdded: return .dateAdded
        case .type: return .type
        case .size: return .size
        case .tags: return nil
        }
    }

    var isSortable: Bool { sortKey != nil }

    static let defaultOrder: [FileColumn] = [.name, .dateModified, .type, .size]

    static func ordered(_ ids: [String]) -> [FileColumn] {
        let columns = ids.compactMap { FileColumn(rawValue: $0) }
        return columns.isEmpty ? defaultOrder : columns
    }
}

/// Cell value formatting. Monospaced digits keep columns aligned while data
/// streams in from live updates.
@MainActor
enum FileColumnFormatter {
    static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static let byte: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = true
        return formatter
    }()

    static func text(for item: FileItem, column: FileColumn, showExtensions: Bool = true) -> String {
        switch column {
        case .name:
            return showExtensions ? item.displayName : item.nameWithoutExtension
        case .dateModified:
            return item.modified.map { date.string(from: $0) } ?? "—"
        case .dateCreated:
            return item.created.map { date.string(from: $0) } ?? "—"
        case .dateAdded:
            return item.added.map { date.string(from: $0) } ?? "—"
        case .type:
            return item.typeDescription
        case .size:
            if item.isDirectory { return "—" }
            guard let size = item.size else { return "—" }
            return byte.string(fromByteCount: size)
        case .tags:
            return item.tags.isEmpty ? "" : item.tags.joined(separator: ", ")
        }
    }
}

/// Caches `NSWorkspace` icons keyed by the bits that decide the icon, so a
/// 100k-row scroll draws from an in-memory dictionary instead of LS. Common
/// content types are warmed off-main at launch so even the first sighting of
/// each type stays off the scroll path.
@MainActor
final class FileIconCache {
    static let shared = FileIconCache()

    private struct CacheKey: Hashable {
        let isDirectory: Bool
        let isPackage: Bool
        let typeIdentifier: String
    }

    private var icons: [CacheKey: NSImage] = [:]
    private var folderIcon: NSImage?

    private init() {}

    /// Prefetches icons for common types off the main thread so cell
    /// configuration never pays the LaunchServices lookup.
    func warmCommonTypes() {
        Task.detached(priority: .utility) { [weak self] in
            let identifiers = [
                UTType.png, UTType.jpeg, UTType.gif, UTType.heic, UTType.tiff,
                UTType.pdf, UTType.plainText, UTType.rtf, UTType.html,
                UTType.zip, UTType.gzip,
                UTType.mpeg4Movie, UTType.quickTimeMovie, UTType.mp3, UTType.wav,
                UTType.aiff, UTType.sourceCode, UTType.json, UTType.xml,
                UTType.yaml, UTType.svg, .diskImage, .application,
            ]
            var warmed: [(CacheKey, NSImage)] = []
            for type in identifiers {
                let image = NSWorkspace.shared.icon(for: type)
                image.size = CGSize(width: 18, height: 18)
                warmed.append((
                    CacheKey(isDirectory: false, isPackage: false, typeIdentifier: type.identifier),
                    image
                ))
            }
            let folder = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
                ?? NSWorkspace.shared.icon(for: UTType.folder)
            folder.size = CGSize(width: 18, height: 18)

            await MainActor.run { [weak self] in
                guard let self else { return }
                for (key, image) in warmed where self.icons[key] == nil {
                    self.icons[key] = image
                }
                if self.folderIcon == nil { self.folderIcon = folder }
            }
        }
    }

    func icon(for item: FileItem, preferredSize: CGSize) -> NSImage {
        if item.isDirectory, let folderIcon { return folderIcon }

        let key = CacheKey(
            isDirectory: false,
            isPackage: item.isPackage,
            typeIdentifier: item.contentType?.identifier ?? ""
        )
        if let cached = icons[key] { return cached }

        if item.isDirectory {
            // Folder with no warmed icon yet (first folders draw before warm
            // completes): take the hit once, cache it forever.
            let image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
                ?? NSWorkspace.shared.icon(for: UTType.folder)
            image.size = preferredSize
            folderIcon = image
            return image
        }

        let image: NSImage
        if let type = item.contentType {
            image = NSWorkspace.shared.icon(for: type)
        } else {
            image = NSWorkspace.shared.icon(for: UTType(filenameExtension: item.fileExtension) ?? .data)
        }
        image.size = preferredSize
        icons[key] = image
        return image
    }
}
