import Foundation
import Testing
@testable import FSCore

/// Deterministic temp directory with generated entries.
struct Fixture {
    let root: URL

    init(name: String = "fenestra-tests") throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.root = base
    }

    func write(_ name: String, bytes: Int = 16) throws -> URL {
        let url = root.appendingPathComponent(name)
        let data = Data(repeating: 0x41, count: bytes)
        try data.write(to: url)
        return url
    }

    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func generateFiles(count: Int, in subdirectory: String? = nil) throws -> [URL] {
        let dir = subdirectory.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        if let subdirectory {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var urls: [URL] = []
        urls.reserveCapacity(count)
        for index in 0..<count {
            let url = dir.appendingPathComponent(String(format: "file-%06d.txt", index))
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
            urls.append(url)
        }
        return urls
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
