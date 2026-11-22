import Foundation

/// A sort key, ordered primary/secondary like Explorer's header clicks.
public struct SortCriterion: Sendable, Hashable, Codable {
    public enum Key: String, Sendable, Codable, CaseIterable {
        case name
        case dateModified
        case dateCreated
        case dateAdded
        case type
        case size
        case kind
    }

    public var key: Key
    public var ascending: Bool

    public init(key: Key, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }

    public static let nameAscending = SortCriterion(key: .name)
}

/// Sorting and grouping that never block the caller: call off-main, receive a
/// `Sendable` result, then publish on the main actor.
public enum DirectorySorter {
    /// Threshold above which sorting should be dispatched off-main.
    public static let offMainThreshold = 5_000

    public static func sorted(_ items: [FileItem], by criteria: [SortCriterion]) -> [FileItem] {
        let effective = criteria.isEmpty ? [SortCriterion.nameAscending] : criteria
        return items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            for criterion in effective {
                switch compare(lhs, rhs, key: criterion.key) {
                case .orderedSame:
                    continue
                case .orderedAscending:
                    return criterion.ascending
                case .orderedDescending:
                    return !criterion.ascending
                }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public static func compare(_ lhs: FileItem, _ rhs: FileItem, key: SortCriterion.Key) -> ComparisonResult {
        switch key {
        case .name, .kind:
            return compareStrings(lhs.name, rhs.name)
        case .dateModified:
            return compareDates(lhs.modified, rhs.modified)
        case .dateCreated:
            return compareDates(lhs.created, rhs.created)
        case .dateAdded:
            return compareDates(lhs.added, rhs.added)
        case .type:
            return compareStrings(lhs.typeDescription, rhs.typeDescription)
        case .size:
            return compareNumbers(lhs.size ?? (lhs.isDirectory ? -1 : 0), rhs.size ?? (rhs.isDirectory ? -1 : 0))
        }
    }

    /// NFC-normalized, case/diacritic-insensitive comparison with numeric runs
    /// compared by value ("file 2" before "file 10").
    private static func compareStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = lhs.precomposedStringWithCanonicalMapping
        let r = rhs.precomposedStringWithCanonicalMapping

        var li = l.startIndex
        var ri = r.startIndex

        while li < l.endIndex, ri < r.endIndex {
            let lc = l[li]
            let rc = r[ri]

            if lc.isNumber, rc.isNumber {
                let lDigits = l[li...].prefix { $0.isNumber }
                let rDigits = r[ri...].prefix { $0.isNumber }
                let lValue = Int(lDigits) ?? 0
                let rValue = Int(rDigits) ?? 0
                if lValue != rValue {
                    return lValue < rValue ? .orderedAscending : .orderedDescending
                }
                if lDigits.count != rDigits.count {
                    return lDigits.count < rDigits.count ? .orderedAscending : .orderedDescending
                }
                li = l.index(li, offsetBy: lDigits.count)
                ri = r.index(ri, offsetBy: rDigits.count)
                continue
            }

            let result = String(lc).compare(
                String(rc),
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            )
            if result != .orderedSame { return result }
            li = l.index(after: li)
            ri = r.index(after: ri)
        }

        if li < l.endIndex { return .orderedDescending }
        if ri < r.endIndex { return .orderedAscending }
        return .orderedSame
    }

    private static func compareNumbers(_ lhs: Int64, _ rhs: Int64) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }

    private static func compareDates(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        guard let lhs, let rhs else { return lhs == nil ? .orderedDescending : .orderedAscending }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }
}

/// Windows-style grouping buckets.
public enum FileGrouper {
    public struct Settings: Sendable, Hashable, Codable {
        public var key: GroupingKey
        public var sortCriteria: [SortCriterion]

        public init(key: GroupingKey = .none, sortCriteria: [SortCriterion] = [.nameAscending]) {
            self.key = key
            self.sortCriteria = sortCriteria
        }
    }

    public static func groups(for items: [FileItem], settings: Settings, now: Date = Date()) -> [ItemGroup] {
        let sorted = DirectorySorter.sorted(items, by: settings.sortCriteria)
        guard settings.key != .none else {
            return [ItemGroup(id: "all", title: "", items: sorted)]
        }

        var buckets: [String: [FileItem]] = [:]
        var order: [String] = []

        for item in sorted {
            let title = bucketTitle(for: item, key: settings.key, now: now)
            if buckets[title] == nil {
                buckets[title] = []
                order.append(title)
            }
            buckets[title]?.append(item)
        }

        return order.map { title in
            ItemGroup(id: title, title: title, items: buckets[title] ?? [])
        }
    }

    public static func bucketTitle(for item: FileItem, key: GroupingKey, now: Date = Date()) -> String {
        switch key {
        case .none:
            return ""
        case .type:
            return typeBucket(item)
        case .dateModified:
            return dateBucket(item.modified, now: now)
        case .size:
            return sizeBucket(item.isDirectory ? 0 : (item.size ?? 0), isDirectory: item.isDirectory)
        }
    }

    public static func dateBucket(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "A long time ago" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfThisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let startOfLastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: startOfThisWeek),
              let startOfThisMonth = calendar.dateInterval(of: .month, for: now)?.start,
              let startOfLastMonth = calendar.date(byAdding: .month, value: -1, to: startOfThisMonth),
              let startOfThisYear = calendar.dateInterval(of: .year, for: now)?.start
        else { return "A long time ago" }

        if date >= startOfToday { return "Today" }
        if date >= startOfThisWeek { return "Earlier this week" }
        if date >= startOfLastWeek { return "Last week" }
        if date >= startOfThisMonth { return "Earlier this month" }
        if date >= startOfLastMonth { return "Last month" }
        if date >= startOfThisYear { return "Earlier this year" }
        return "A long time ago"
    }

    public static func sizeBucket(_ bytes: Int64, isDirectory: Bool) -> String {
        if isDirectory { return "Folders" }
        let kb: Int64 = 1024
        let mb = kb * 1024
        switch bytes {
        case 0: return "Empty"
        case ..<(16 * kb): return "Tiny"          // 1 byte–16 KB
        case ..<(1 * mb): return "Small"          // 16 KB–1 MB
        case ..<(16 * mb): return "Medium"        // 1–16 MB
        case ..<(128 * mb): return "Large"        // 16–128 MB
        case ..<(1024 * mb): return "Huge"        // 128 MB–1 GB
        default: return "Gigantic"                // 1 GB+
        }
    }

    private static func typeBucket(_ item: FileItem) -> String {
        if item.isDirectory { return item.isPackage ? "Bundles" : "Folders" }
        guard let type = item.contentType else { return "Other" }
        if type.conforms(to: .image) { return "Images" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "Videos" }
        if type.conforms(to: .audio) { return "Music" }
        if type.conforms(to: .pdf) { return "PDF documents" }
        if type.conforms(to: .spreadsheet) { return "Spreadsheets" }
        if type.conforms(to: .presentation) { return "Presentations" }
        if type.conforms(to: .sourceCode) { return "Source code" }
        if type.conforms(to: .text) { return "Text documents" }
        if type.conforms(to: .archive) || type.conforms(to: .zip) { return "Archives" }
        if type.conforms(to: .application) { return "Applications" }
        return "Other"
    }
}
