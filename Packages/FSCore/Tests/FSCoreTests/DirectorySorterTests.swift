import Foundation
import Testing
import UniformTypeIdentifiers
@testable import FSCore

@Suite("Sorting and grouping")
struct DirectorySorterTests {
    private func item(
        _ name: String,
        directory: Bool = false,
        size: Int64? = 0,
        modified: Date? = nil,
        type: String? = nil
    ) -> FileItem {
        FileItem(
            id: name,
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            isDirectory: directory,
            size: directory ? nil : size,
            modified: modified,
            contentType: type.flatMap { UTType($0) }
        )
    }

    @Test func foldersFirstThenStableNameOrder() {
        let items = [
            item("beta.txt"),
            item("Photos", directory: true),
            item("alpha.txt"),
            item("Zeta", directory: true),
        ]
        let sorted = DirectorySorter.sorted(items, by: [SortCriterion(key: .name)])
        #expect(sorted.map(\.name) == ["Photos", "Zeta", "alpha.txt", "beta.txt"])
    }

    @Test func sortIsStableForEqualKeys() {
        let sameDate = Date(timeIntervalSince1970: 1_000)
        let items = [
            item("b.txt", size: 5, modified: sameDate),
            item("a.txt", size: 5, modified: sameDate),
            item("c.txt", size: 5, modified: sameDate),
        ]
        let byDate = DirectorySorter.sorted(items, by: [SortCriterion(key: .dateModified)])
        #expect(byDate.map(\.name) == ["a.txt", "b.txt", "c.txt"])

        let bySize = DirectorySorter.sorted(items, by: [SortCriterion(key: .size, ascending: true)])
        #expect(bySize.map(\.name) == ["a.txt", "b.txt", "c.txt"])
    }

    @Test func descendingOrderReversesWithinKind() {
        let items = [item("a.txt", size: 1), item("b.txt", size: 9), item("c.txt", size: 5)]
        let sorted = DirectorySorter.sorted(items, by: [SortCriterion(key: .size, ascending: false)])
        #expect(sorted.map(\.name) == ["b.txt", "c.txt", "a.txt"])
    }

    @Test func secondaryKeyBreaksTies() {
        let day = Date(timeIntervalSince1970: 2_000)
        let items = [
            item("z.txt", modified: day),
            item("a.txt", modified: day),
            item("m.txt", modified: day.addingTimeInterval(10)),
        ]
        let sorted = DirectorySorter.sorted(
            items,
            by: [SortCriterion(key: .dateModified), SortCriterion(key: .name)]
        )
        #expect(sorted.map(\.name) == ["a.txt", "z.txt", "m.txt"])
    }

    @Test func numericNamesSortNaturally() {
        let items = (1...12).map { item("file \($0).txt") }
        let sorted = DirectorySorter.sorted(items, by: [SortCriterion(key: .name)])
        #expect(sorted.map(\.name) == (1...12).map { "file \($0).txt" })
    }

    @Test func sizeBucketsMatchWindows() {
        #expect(FileGrouper.sizeBucket(0, isDirectory: false) == "Empty")
        #expect(FileGrouper.sizeBucket(10, isDirectory: false) == "Tiny")
        #expect(FileGrouper.sizeBucket(32 * 1024, isDirectory: false) == "Small")
        #expect(FileGrouper.sizeBucket(5 * 1024 * 1024, isDirectory: false) == "Medium")
        #expect(FileGrouper.sizeBucket(64 * 1024 * 1024, isDirectory: false) == "Large")
        #expect(FileGrouper.sizeBucket(500 * 1024 * 1024, isDirectory: false) == "Huge")
        #expect(FileGrouper.sizeBucket(2 * 1024 * 1024 * 1024, isDirectory: false) == "Gigantic")
    }

    @Test func dateBuckets() {
        let now = Date()
        let calendar = Calendar.current
        #expect(FileGrouper.dateBucket(now, now: now) == "Today")
        #expect(FileGrouper.dateBucket(calendar.date(byAdding: .day, value: -1, to: now), now: now) == "Yesterday")
        #expect(FileGrouper.dateBucket(calendar.date(byAdding: .year, value: -3, to: now), now: now) == "A long time ago")
        #expect(FileGrouper.dateBucket(nil, now: now) == "A long time ago")
    }

    @Test func groupingByDateKeepsGroupsContiguous() {
        let now = Date()
        let items = [
            item("today.txt", modified: now),
            item("old.txt", modified: now.addingTimeInterval(-60 * 60 * 24 * 400)),
            item("yesterday.txt", modified: now.addingTimeInterval(-60 * 60 * 24)),
        ]
        let groups = FileGrouper.groups(
            for: items,
            settings: .init(key: .dateModified, sortCriteria: [SortCriterion(key: .dateModified)])
        )
        #expect(groups.map(\.title) == ["A long time ago", "Yesterday", "Today"])
        #expect(groups.allSatisfy { !$0.ids.isEmpty })
    }

    @Test func groupingByTypeUsesUTTypeBuckets() {
        let items = [
            item("photo.jpg", type: "public.jpeg"),
            item("movie.mp4", type: "public.mpeg-4"),
            item("notes.txt", type: "public.plain-text"),
            item("bundle.zip", type: "public.zip-archive"),
        ]
        let groups = FileGrouper.groups(for: items, settings: .init(key: .type))
        let titles = Set(groups.map(\.title))
        #expect(titles == ["Images", "Videos", "Text documents", "Archives"])
    }

    @Test func unicodeVariantsDoNotCrashOrDropItems() {
        let composed = item("café.txt")
        let decomposed = item("cafe\u{0301}.txt")
        let sorted = DirectorySorter.sorted([composed, decomposed], by: [SortCriterion(key: .name)])
        #expect(sorted.count == 2)
    }
}
