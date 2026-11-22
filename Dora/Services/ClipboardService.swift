import AppKit
import Foundation
import UniformTypeIdentifiers

enum ClipboardMode {
    case copy
    case cut
}

struct ClipboardPayload {
    let urls: [URL]
    let mode: ClipboardMode
}

final class ClipboardService {
    private let pasteboard = NSPasteboard.general
    private let cutMarkerType = NSPasteboard.PasteboardType("com.dora.explorer.cut")

    func write(_ items: [FileItem], mode: ClipboardMode) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(items.map(\.url) as [NSURL])
        switch mode {
        case .copy:
            pasteboard.setString("copy", forType: cutMarkerType)
        case .cut:
            pasteboard.setString("cut", forType: cutMarkerType)
        }
    }

    func read() -> ClipboardPayload? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty else {
            return nil
        }
        let mode: ClipboardMode = (pasteboard.string(forType: cutMarkerType) == "cut") ? .cut : .copy
        return ClipboardPayload(urls: urls, mode: mode)
    }

    func clearCutMarker() {
        pasteboard.setString("copy", forType: cutMarkerType)
    }
}
