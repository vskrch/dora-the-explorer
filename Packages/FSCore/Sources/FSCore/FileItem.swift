import Foundation
import UniformTypeIdentifiers

/// Small, `Sendable` description of one file or folder.
///
/// Deliberately cheap: anything expensive (EXIF, ID3, dimensions, git status) is
/// fetched by a separate async service keyed by `itemID` and cached.
public struct FileItem: Identifiable, Hashable, Sendable {
    /// `volumeID:fileID` string, stable across renames on the same volume.
    public let id: String
    public let url: URL
    public let name: String
    public let displayName: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymlink: Bool
    public let isAlias: Bool
    public let isHidden: Bool
    public let size: Int64?
    public let allocatedSize: Int64?
    public let created: Date?
    public let modified: Date?
    public let accessed: Date?
    public let added: Date?
    public let contentType: UTType?
    public let posixPermissions: UInt16?
    public let flags: UInt32?
    public let tags: [String]

    public init(
        id: String,
        url: URL,
        name: String,
        displayName: String? = nil,
        isDirectory: Bool,
        isPackage: Bool = false,
        isSymlink: Bool = false,
        isAlias: Bool = false,
        isHidden: Bool = false,
        size: Int64? = nil,
        allocatedSize: Int64? = nil,
        created: Date? = nil,
        modified: Date? = nil,
        accessed: Date? = nil,
        added: Date? = nil,
        contentType: UTType? = nil,
        posixPermissions: UInt16? = nil,
        flags: UInt32? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.displayName = displayName ?? name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymlink = isSymlink
        self.isAlias = isAlias
        self.isHidden = isHidden
        self.size = size
        self.allocatedSize = allocatedSize
        self.created = created
        self.modified = modified
        self.accessed = accessed
        self.added = added
        self.contentType = contentType
        self.posixPermissions = posixPermissions
        self.flags = flags
        self.tags = tags
    }

    /// Name without its trailing extension, for inline rename.
    public var nameWithoutExtension: String {
        (name as NSString).deletingPathExtension
    }

    public var fileExtension: String {
        (name as NSString).pathExtension
    }

    public var typeDescription: String {
        if isDirectory { return isPackage ? "Bundle" : "File folder" }
        return contentType?.localizedDescription ?? (fileExtension.isEmpty ? "File" : "\(fileExtension.uppercased()) File")
    }

    public init?(url: URL, keys: [URLResourceKey] = FileItem.defaultKeys) throws {
        let values = try url.resourceValues(forKeys: Set(keys))
        let isDirectory = values.isDirectory ?? false
        let isPackage = values.isPackage ?? false
        let isSymlink = values.isSymbolicLink ?? false
        let isHidden = values.isHidden ?? url.lastPathComponent.hasPrefix(".")
        self.init(
            id: FileItem.makeID(url: url, values: values),
            url: url,
            name: url.lastPathComponent,
            displayName: values.localizedName,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymlink: isSymlink,
            isAlias: false,
            isHidden: isHidden,
            size: isDirectory ? nil : (values.fileSize.map(Int64.init)),
            allocatedSize: values.totalFileAllocatedSize.map(Int64.init),
            created: values.creationDate,
            modified: values.contentModificationDate,
            accessed: values.contentAccessDate,
            added: values.addedToDirectoryDate,
            contentType: values.contentType,
            posixPermissions: nil,
            flags: nil,
            tags: []
        )
    }

    public static let defaultKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .isHiddenKey,
        .isAliasFileKey,
        .fileSizeKey,
        .totalFileAllocatedSizeKey,
        .creationDateKey,
        .contentModificationDateKey,
        .contentAccessDateKey,
        .addedToDirectoryDateKey,
        .contentTypeKey,
        .localizedNameKey,
        .fileResourceIdentifierKey,
    ]

    /// Stable identity used by every enumeration and refresh path:
    /// `<parentDirectoryPath>#<st_ino>`. The base is ALWAYS the parent
    /// directory (never the file's own path — the bulk pass keys ids on the
    /// enumerated directory), and the serial number is the POSIX inode
    /// (`getattrlistbulk` vends exactly `st_ino` for ATTR_CMN_FILEID;
    /// single-file `getattrlist` returns a different catalog id for the
    /// same bit and must not be used). Hard links (nlink > 1) share an id,
    /// so the name disambiguates them.
    public static func resolveID(for url: URL) -> String {
        let standardized = url.standardizedFileURL
        // Standardize the parent independently: deleting a component first
        // would let a symlinked parent leave the standardized file's base
        // and the enumerated directory disagree.
        let parent = standardized.deletingLastPathComponent()
        let base = parent.standardizedFileURL.path
        var info = stat()
        let ok = url.withUnsafeFileSystemRepresentation { rep -> Bool in
            guard let rep else { return false }
            return lstat(rep, &info) == 0
        }
        guard ok else { return url.standardizedFileURL.path }
        if info.st_nlink > 1 {
            return "\(base)#\(info.st_ino)#\(url.lastPathComponent)"
        }
        return "\(base)#\(info.st_ino)"
    }

    /// Fallback identity when `getattrlistbulk` did not provide one.
    public static func makeID(url: URL, values: URLResourceValues?) -> String {
        resolveID(for: url)
    }
}
