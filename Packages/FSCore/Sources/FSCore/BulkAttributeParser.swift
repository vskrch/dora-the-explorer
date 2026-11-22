import Darwin
import Foundation

/// Decodes `getattrlistbulk(2)` buffers.
///
/// Verified against the SDK man page's example (getattrlistbulk(2)) and live
/// kernel output. Entry layout — each entry starts 8-byte aligned:
///
/// ```
/// u32  length        — total bytes of this entry INCLUDING this word;
///                      step to the next entry by adding this (entry_start += length)
/// +4   attribute_set_t returned — 20 bytes: commonattr, volattr, dirattr,
///                      fileattr, forkattr (u32 each)
/// +24  attributes in ascending bit order, each aligned per its type
///      (attrreference_t/int64/timespec at 8-byte alignment from entry start):
///        ATTR_CMN_NAME  (attrreference_t)
///        ATTR_CMN_OBJTYPE (u32)
///        ATTR_CMN_CRTIME (timespec)
///        ATTR_CMN_MODTIME (timespec)
///        ATTR_CMN_ACCTIME (timespec)
///        ATTR_CMN_FLAGS (u32)
///        ATTR_CMN_FILEID (u64)
///      then fileattr-set fields in bit order:
///        ATTR_FILE_ALLOCSIZE (i64)
///        ATTR_FILE_DATALENGTH (i64)
/// ```
///
/// Name data offset is relative to the position of the attrreference_t
/// (per the man page example: `name_ptr = attrref_field + attr_dataoffset`).
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

    /// File-class attributes; LINKCOUNT keeps hard links distinguishable.
    static let fileAttr: attrgroup_t =
        attrgroup_t(ATTR_FILE_LINKCOUNT)
        | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        | attrgroup_t(ATTR_FILE_DATALENGTH)

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

        func u16(_ at: Int) -> UInt16 { base.loadUnaligned(fromByteOffset: at, as: UInt16.self) }
        func u32(_ at: Int) -> UInt32 { base.loadUnaligned(fromByteOffset: at, as: UInt32.self) }
        func u64(_ at: Int) -> UInt64 { base.loadUnaligned(fromByteOffset: at, as: UInt64.self) }
        func i64(_ at: Int) -> Int64 { base.loadUnaligned(fromByteOffset: at, as: Int64.self) }

        var cursor = 0
        var entries = 0
        var wellFormed = true

        while cursor + 4 <= buffer.count {
            // Entry length INCLUDES the length word itself (man page: "step
            // to the next by simply adding this length").
            let entryLength = Int(u32(cursor))
            guard entryLength >= 4 + MemoryLayout<attribute_set_t>.size,
                  cursor + entryLength <= buffer.count else {
                wellFormed = entries > 0
                break
            }
            let entryStart = cursor
            let entryEnd = entryStart + entryLength
            entries += 1
            defer { cursor = entryEnd }

            // Returned attribute set directly after the length word.
            let setCommon = u32(entryStart + 4)
            let setFileAttr = u32(entryStart + 4 + 3 * MemoryLayout<attrgroup_t>.size)
            guard setCommon & UInt32(ATTR_CMN_NAME) != 0 else {
                wellFormed = false
                continue
            }

            var field = entryStart + 4 + MemoryLayout<attribute_set_t>.size

            // Fields are packed SEQUENTIALLY after the returned set, in
            // ascending attribute-bit order, at natural 4-byte packing (no
            // extra padding — verified against live kernel buffers: timespec
            // fields land at 4-mod-8 offsets). Sizes are multiples of 4, so
            // the cursor stays 4-aligned without padding logic.

            // ATTR_CMN_NAME — attrreference_t { u32 offset, u32 length }.
            let nameRefAt = field
            guard entryEnd - nameRefAt >= 8 else { wellFormed = false; continue }
            let dataOffset = Int(u32(nameRefAt))
            let dataLengthWords = Int(u32(nameRefAt + 4))
            let nameStart = nameRefAt + dataOffset
            guard dataLengthWords > 0, nameStart >= entryStart + 4, nameStart + dataLengthWords <= entryEnd else {
                wellFormed = false
                continue
            }
            let nameBytes = UnsafeRawBufferPointer(start: base + nameStart, count: dataLengthWords)
            let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
            guard !name.isEmpty, name != "." && name != ".." else { continue }
            field = nameRefAt + 8

            var objType: UInt32 = 0
            if setCommon & UInt32(ATTR_CMN_OBJTYPE) != 0, entryEnd - field >= 4 {
                objType = u32(field)
                field += 4
            }
            var created: Date?
            if setCommon & UInt32(ATTR_CMN_CRTIME) != 0, entryEnd - field >= 16 {
                created = date(seconds: i64(field), nanos: i64(field + 8))
                field += 16
            }
            var modified: Date?
            if setCommon & UInt32(ATTR_CMN_MODTIME) != 0, entryEnd - field >= 16 {
                modified = date(seconds: i64(field), nanos: i64(field + 8))
                field += 16
            }
            var accessed: Date?
            if setCommon & UInt32(ATTR_CMN_ACCTIME) != 0, entryEnd - field >= 16 {
                accessed = date(seconds: i64(field), nanos: i64(field + 8))
                field += 16
            }
            var flags: UInt32 = 0
            if setCommon & UInt32(ATTR_CMN_FLAGS) != 0, entryEnd - field >= 4 {
                flags = u32(field)
                field += 4
            }
            var fileID: UInt64 = 0
            if setCommon & UInt32(ATTR_CMN_FILEID) != 0, entryEnd - field >= 8 {
                fileID = u64(field)
                field += 8
            }
            // File-class fields in ascending fileattr-bit order:
            // LINKCOUNT (0x1), ALLOCSIZE (0x4), DATALENGTH (0x200).
            var linkCount: UInt32 = 1
            if setFileAttr & UInt32(ATTR_FILE_LINKCOUNT) != 0, entryEnd - field >= 4 {
                linkCount = u32(field)
                field += 4
            }
            var allocSize: Int64 = 0
            if setFileAttr & UInt32(ATTR_FILE_ALLOCSIZE) != 0, entryEnd - field >= 8 {
                allocSize = i64(field)
                field += 8
            }
            var dataLengthBytes: Int64 = 0
            if setFileAttr & UInt32(ATTR_FILE_DATALENGTH) != 0, entryEnd - field >= 8 {
                dataLengthBytes = i64(field)
                field += 8
            }

            let isDirectory = objType == UInt32(VDIR.rawValue)
            let isSymlink = objType == UInt32(VLNK.rawValue)
            let isPackage = isDirectory && packageExtensions.contains((name as NSString).pathExtension.lowercased())
            let isHidden = name.hasPrefix(".") || (flags & UInt32(UF_HIDDEN)) != 0
            if !showHidden && isHidden { continue }

            let url = directory.appendingPathComponent(name, isDirectory: isDirectory)
            // Hard links in the same folder share an inode; the name
            // disambiguates them (lstat pass does the same).
            let id: String
            if fileID != 0 {
                id = linkCount > 1
                    ? "\(directory.standardizedFileURL.path)#\(fileID)#\(name)"
                    : "\(directory.standardizedFileURL.path)#\(fileID)"
            } else {
                id = url.standardizedFileURL.path
            }

            items.append(
                FileItem(
                    id: id,
                    url: url,
                    name: name,
                    isDirectory: isDirectory,
                    isPackage: isPackage,
                    isSymlink: isSymlink,
                    isHidden: isHidden,
                    size: isDirectory ? nil : dataLengthBytes,
                    allocatedSize: allocSize,
                    created: created,
                    modified: modified,
                    accessed: accessed,
                    flags: flags
                )
            )
        }

        return ParseResult(items: items, entryCount: entries, bytesUsed: cursor, isWellFormed: wellFormed)
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
