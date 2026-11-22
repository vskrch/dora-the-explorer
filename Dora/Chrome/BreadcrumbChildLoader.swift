import Foundation
import FSCore

/// Supplies chevron dropdowns with a folder's child folders. Enumeration runs
/// fully off the main thread via FSCore; results are name-sorted (Finder order).
@MainActor
enum BreadcrumbChildLoader {
    static func load(
        url: URL,
        completion: @escaping @Sendable ([BreadcrumbBar.FolderChild]) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            let enumerator = DirectoryEnumerator()
            var children: [BreadcrumbBar.FolderChild] = []
            do {
                let stream = enumerator.batches(
                    of: url,
                    configuration: .init(batchSize: 500, showHidden: false)
                )
                for try await batch in stream {
                    children.append(contentsOf: batch.compactMap { item in
                        guard item.isDirectory, !item.isHidden else { return nil }
                        return BreadcrumbBar.FolderChild(url: item.url, name: item.displayName)
                    })
                    if children.count > 1200 { break }
                }
            } catch {
                completion([])
                return
            }
            children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            completion(children)
        }
    }
}
