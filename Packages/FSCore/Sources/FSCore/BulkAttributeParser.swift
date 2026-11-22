import Darwin
import Foundation

/// Decodes `getattrlistbulk(2)` buffers.
///
/// Verified entry layout (macOS 26, APFS, see `BulkRequestDebugTests`):
///
/// ```
/// u32  entryLength                     (bytes after this word)
/// u16  bitmapcount = 5
/// u16  reserved    = 0
/// u32  attribute mask (vol | dir << 16 …), group order as in attrlist
/// u32  attribute mask bits 32+
/// u32  ATTR_CMN_RETURNED_ATTRS[0]
/// …    (attribute_set_t spans 20 bytes, starting 8 bytes after the entry payload)
/// 8    ATTR_CMN_NAME (attrreference_t)
/// 28   ATTR_CMN_OBJTYPE (u32)
/// 32   ATTR_CMN_FILEID (u64)
/// 40   ATTR_CMN_CRTIME (timespec)
/// 56   ATTR_CMN_MODTIME (timespec)
/// 72   ATTR_CMN_ACCTIME (timespec)
/// 88   ATTR_CMN_FLAGS (u32)
/// 92   ATTR_FILE_DATALENGTH (i64)
/// 100  ATTR_FILE_ALLOCSIZE (i64)
/// 108  attribute data (name bytes)
/// ```
///
/// Offsets are relative to the entry payload (the byte after the length word).
internal enum BulkAttributeParser {
    static let commonAttr: attrgroup_t =
        attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        | attrgroup_t(ATTR_CMN_NAME)
        | attrgroup_t(ATTR_CMN_OBJTYPE)
        | attrgroup_t(ATTR_CMN_FILEID)
        | attrgroup_t(ATTR_CMN_CRTIME)
        | attrgroup_t(ATTR_CMN_MODTIME)
        | attrgroup_t(ATTR_CMN_ACCTIME)
        | attrgroup_t(ATTR_CMN_FLAGS)

    static let fileAttr: attrgroup_t =
        attrgroup_t(ATTR_FILE_DATALENGTH) | attrgroup_t(ATTR_FILE_ALLOCSIZE)

    static func makeAttrList() -> attrlist {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = commonAttr
        list.fileattr = fileAttr
        return list
    }

    struct ParseResult {
        var items: [FileItem]
        var entryCount: Int
        var bytesUsed: Int
        var isWellFormed: Bool
    }

    static func parse(
        buffer: UnsafeRawBufferPointer,
        directory: URL,
        showHidden: Bool
    ) -> ParseResult {
        var items: [FileItem] = []
        guard let base = buffer.baseAddress else {
            return ParseResult(items: [], entryCount: 0, bytesUsed: 0, isWellFormed: true)
        }

        var offset = 0
        var entries = 0
        var wellFormed = true

        func u16(_ at: Int) -> UInt16 { base.loadUnaligned(fromByteOffset: at, as: UInt16.self) }
        func u32(_ at: Int) -> UInt32 { base.loadUnaligned(fromByteOffset: at, as: UInt32.self) }
        func u64(_ at: Int) -> UInt64 { base.loadUnaligned(fromByteOffset: at, as: UInt64.self) }
        func i64(_ at: Int) -> Int64 { base.loadUnaligned(fromByteOffset: at, as: Int64.self) }

        while offset + 4 <= buffer.count {
            let entryLength = Int(u32(offset))
            if entryLength <= 0 || offset + 4 + entryLength > buffer.count { break }
            entries += 1
            let payload = offset + 4
            let end = payload + entryLength
            defer { offset = end }

            // Two layouts exist in the wild depending on kernel/boot:
            //  - compact: u16 bitmapcount, u16 reserved, then the returned set at +4
            //  - extended: u16 bitmapcount, u16 reserved, u32 mask, then the set at +8
            // Detect by checking whether the word at +4 looks like an attribute set.
            var fields = payload + 4
            if entryLength >= 12 {
                let candidate = u32(payload + 4)
                let hasReturned = candidate & UInt32(ATTR_CMN_RETURNED_ATTRS) != 0
                if hasReturned { fields += 4 }
            }
            guard Int(u16(payload)) == ATTR_BIT_MAP_COUNT else {
                wellFormed = false
                continue
            }

            // ATTR_CMN_NAME reference sits right after the returned set.
            let nameRefOffset = fields + MemoryLayout<attribute_set_t>.size
            guard end - nameRefOffset >= MemoryLayout<attrreference_t>.size else {
                wellFormed = false
                continue
            }
            let refOffset = base.loadUnaligned(fromByteOffset: nameRefOffset, as: Int32.self)
            let refLength = base.loadUnaligned(fromByteOffset: nameRefOffset + 4, as: UInt32.self)
            let nameStart = nameRefOffset + Int(refOffset)
            let nameLength = Int(refLength)
            guard nameLength > 0, nameStart >= payload, nameStart + nameLength <= end else {
                wellFormed = false
                continue
            }
            let nameBytes = UnsafeRawBufferPointer(start: base + nameStart, count: nameLength)
            let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
            if name.isEmpty {
                wellFormed = false
                continue
            }

            // Remaining fixed fields follow the name reference in attribute_set_t order.
            var cursor = nameRefOffset + MemoryLayout<attrreference_t>.size
            func take(_ size: Int) -> Int? {
                guard cursor + size <= end else { return nil }
                defer { cursor += size }
                return cursor
            }

            var objType: UInt32 = 0
            if let at = take(4), at + 4 <= end {
                objType = u32(at)
            }
            var fileID: UInt64 = 0
            if let at = take(8), at + 8 <= end {
                fileID = u64(at)
            }
            var created: Date?
            if let at = take(16), at + 16 <= end {
                created = date(seconds: i64(at), nanos: i64(at + 8))
            }
            var modified: Date?
            if let at = take(16), at + 16 <= end {
                modified = date(seconds: i64(at), nanos: i64(at + 8))
            }
            var accessed: Date?
            if let at = take(16), at + 16 <= end {
                accessed = date(seconds: i64(at), nanos: i64(at + 8))
            }
            var flags: UInt32 = 0
            if let at = take(4), at + 4 <= end {
                flags = u32(at)
            }
            var dataLength: Int64 = 0
            if let at = take(8), at + 8 <= end {
                dataLength = i64(at)
            }
            var allocSize: Int64 = 0
            if let at = take(8), at + 8 <= end {
                allocSize = i64(at)
            }

            let isDirectory = objType == UInt32(VDIR.rawValue)
            let isSymlink = objType == UInt32(VLNK.rawValue)
            let isPackage = isDirectory && packageExtensions.contains((name as NSString).pathExtension.lowercased())
            let isHidden = name.hasPrefix(".") || (flags & UInt32(UF_HIDDEN)) != 0
            if !showHidden && isHidden { continue }

            let url = directory.appendingPathComponent(name, isDirectory: isDirectory)
            let id = fileID != 0
                ? "\(directory.standardizedFileURL.path)#\(fileID)"
                : url.standardizedFileURL.path

            items.append(
                FileItem(
                    id: id,
                    url: url,
                    name: name,
                    isDirectory: isDirectory,
                    isPackage: isPackage,
                    isSymlink: isSymlink,
                    isHidden: isHidden,
                    size: isDirectory ? nil : dataLength,
                    allocatedSize: allocSize,
                    created: created,
                    modified: modified,
                    accessed: accessed,
                    flags: flags
                )
            )
        }

        return ParseResult(items: items, entryCount: entries, bytesUsed: offset, isWellFormed: wellFormed)
    }

    private static func date(seconds: Int64, nanos: Int64) -> Date {
        guard seconds != 0 else { return Date(timeIntervalSince1970: 0) }
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
    }

    static func isPackageExtension(_ ext: String) -> Bool {
        packageExtensions.contains(ext.lowercased())
    }

    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "pkg", "xcodeproj", "xcworkspace",
        "playground", "prefpane", "qlgenerator", "mdimporter", "saver", "appex", "docset",
    ]
}
