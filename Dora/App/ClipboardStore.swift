import AppKit
import Foundation

/// App-wide clipboard intent. Copy/cut write standard file-URL pasteboard
/// data (so every other app understands it); cut additionally marks intent
/// with a private pasteboard type. Pasting in another app therefore copies —
/// exactly the Windows cross-app semantics the spec asks for.
@MainActor
final class ClipboardStore {
    static let shared = ClipboardStore()

    /// Private marker type for "these URLs were cut in Dora".
    static let cutMarkerType = NSPasteboard.PasteboardType("com.dorasoft.dora.cut")

    /// Paths of items currently cut (empty when the clipboard is a plain copy).
    private(set) var cutPaths: Set<String> = []

    private init() {}

    func copyItems(at urls: [URL]) {
        cutPaths.removeAll()
        writeFilesToPasteboard(urls)
    }

    func cutItems(at urls: [URL]) {
        cutPaths = Set(urls.map(\.path))
        writeFilesToPasteboard(urls)
        NSPasteboard.general.setData(Data("cut".utf8), forType: Self.cutMarkerType)
    }

    /// Clears cut intent when the operation completes or is aborted. (The
    /// pasteboard marker can't be surgically removed, so it's simply ignored
    /// once no session state backs it.)
    func clearCutIntent() {
        cutPaths.removeAll()
    }

    /// URLs on the pasteboard; nil when there are none.
    func readPasteboardFileURLs() -> [URL]? {
        let pasteboard = NSPasteboard.general
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL] ?? []
        return urls.isEmpty ? nil : urls
    }

    /// True when the pasted URLs form (part of) the current cut intent —
    /// either cut in this window (session paths match) or cut in another
    /// Dora window (marker present, no session paths to contradict it).
    func shouldPerformMove(for urls: [URL]) -> Bool {
        guard NSPasteboard.general.data(forType: Self.cutMarkerType) != nil else { return false }
        if cutPaths.isEmpty { return true }
        let paths = Set(urls.map(\.path))
        return paths.isSubset(of: cutPaths)
    }

    private func writeFilesToPasteboard(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }
}
