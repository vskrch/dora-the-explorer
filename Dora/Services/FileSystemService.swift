import AppKit
import Foundation
import UniformTypeIdentifiers

enum FileSystemError: LocalizedError {
    case notDirectory(URL)
    case listingFailed(URL, Error)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notDirectory(let url):
            return "Not a folder: \(url.path)"
        case .listingFailed(let url, let error):
            return "Cannot read \(url.path): \(error.localizedDescription)"
        case .operationFailed(let message):
            return message
        }
    }
}

final class FileSystemService {
    private let fm = FileManager.default

    func homeURL() -> URL {
        fm.homeDirectoryForCurrentUser
    }

    func standardDestinations() -> [NavDestination] {
        let home = homeURL()
        var items: [NavDestination] = [
            NavDestination(id: "desktop", title: "Desktop", url: home.appendingPathComponent("Desktop"), systemImage: "desktopcomputer", group: .quickAccess),
            NavDestination(id: "documents", title: "Documents", url: home.appendingPathComponent("Documents"), systemImage: "doc", group: .quickAccess),
            NavDestination(id: "downloads", title: "Downloads", url: home.appendingPathComponent("Downloads"), systemImage: "arrow.down.circle", group: .quickAccess),
            NavDestination(id: "pictures", title: "Pictures", url: home.appendingPathComponent("Pictures"), systemImage: "photo", group: .quickAccess),
            NavDestination(id: "home", title: NSUserName(), url: home, systemImage: "house", group: .thisPC),
            NavDestination(id: "applications", title: "Applications", url: URL(fileURLWithPath: "/Applications"), systemImage: "app", group: .thisPC),
        ]

        if let volumes = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: [.isVolumeKey],
            options: [.skipsHiddenFiles]
        ) {
            for volume in volumes.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let name = volume.lastPathComponent
                items.append(
                    NavDestination(
                        id: "vol-\(name)",
                        title: name,
                        url: volume,
                        systemImage: "externaldrive",
                        group: .thisPC
                    )
                )
            }
        }

        return items.filter { fm.fileExists(atPath: $0.url.path) }
    }

    func listContents(of directory: URL, showHidden: Bool) throws -> [FileItem] {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            throw FileSystemError.notDirectory(directory)
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isHiddenKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .contentTypeKey,
            .nameKey,
        ]

        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [])
        } catch {
            throw FileSystemError.listingFailed(directory, error)
        }

        var items: [FileItem] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isHidden = values?.isHidden ?? url.lastPathComponent.hasPrefix(".")
            if !showHidden && isHidden { continue }

            let isDirectory = values?.isDirectory ?? false
            items.append(
                FileItem(
                    id: url,
                    url: url,
                    name: values?.name ?? url.lastPathComponent,
                    isDirectory: isDirectory,
                    isHidden: isHidden,
                    fileSize: isDirectory ? nil : Int64(values?.fileSize ?? 0),
                    modifiedDate: values?.contentModificationDate,
                    createdDate: values?.creationDate,
                    contentType: values?.contentType
                )
            )
        }
        return items
    }

    func open(_ item: FileItem) {
        if item.isDirectory {
            return
        }
        NSWorkspace.shared.open(item.url)
    }

    func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func createFolder(in directory: URL, preferredName: String = "New folder") throws -> URL {
        var name = preferredName
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            name = "\(preferredName) (\(counter))"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }
        try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
        return candidate
    }

    func rename(_ item: FileItem, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FileSystemError.operationFailed("Name cannot be empty")
        }
        let destination = item.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        guard destination != item.url else { return item.url }
        if fm.fileExists(atPath: destination.path) {
            throw FileSystemError.operationFailed("An item named “\(trimmed)” already exists")
        }
        try fm.moveItem(at: item.url, to: destination)
        return destination
    }

    func moveToTrash(_ items: [FileItem]) throws {
        for item in items {
            var resulting: NSURL?
            try fm.trashItem(at: item.url, resultingItemURL: &resulting)
        }
    }

    func copy(_ items: [FileItem], to directory: URL) throws {
        for item in items {
            let dest = uniqueURL(for: item.name, in: directory)
            try fm.copyItem(at: item.url, to: dest)
        }
    }

    func move(_ items: [FileItem], to directory: URL) throws {
        for item in items {
            let dest = uniqueURL(for: item.name, in: directory)
            if item.url.deletingLastPathComponent() == directory {
                continue
            }
            try fm.moveItem(at: item.url, to: dest)
        }
    }

    func parent(of url: URL) -> URL? {
        let parent = url.deletingLastPathComponent()
        if parent.path == url.path { return nil }
        if url.path == "/" { return nil }
        return parent
    }

    private func uniqueURL(for name: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(name)
        if !fm.fileExists(atPath: candidate.path) { return candidate }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        repeat {
            let newName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            counter += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}
