import AppKit
import Foundation
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    let id: URL
    let url: URL
    let name: String
    let isDirectory: Bool
    let isHidden: Bool
    let fileSize: Int64?
    let modifiedDate: Date?
    let createdDate: Date?
    let contentType: UTType?

    var typeDescription: String {
        if isDirectory { return "File folder" }
        if let contentType {
            return contentType.localizedDescription ?? contentType.identifier
        }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "File" : "\(ext) File"
    }

    var formattedSize: String {
        guard !isDirectory, let fileSize else { return "" }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var formattedModified: String {
        guard let modifiedDate else { return "" }
        return Self.dateFormatter.string(from: modifiedDate)
    }

    var systemIcon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

enum SortColumn: String, CaseIterable, Identifiable {
    case name
    case modified
    case type
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Date modified"
        case .type: return "Type"
        case .size: return "Size"
        }
    }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case details
    case icons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .details: return "Details"
        case .icons: return "Large icons"
        }
    }

    var systemImage: String {
        switch self {
        case .details: return "list.bullet"
        case .icons: return "square.grid.2x2"
        }
    }
}

struct NavDestination: Identifiable, Hashable {
    let id: String
    let title: String
    let url: URL
    let systemImage: String
    let group: NavGroup
}

enum NavGroup: String, CaseIterable {
    case quickAccess = "Quick access"
    case thisPC = "This PC"
}
