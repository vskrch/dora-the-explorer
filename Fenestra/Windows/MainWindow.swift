import AppKit
import FSCore

enum MainWindow {
    /// Phase 0 placeholder window: chrome arrives in Phase 2.
    @MainActor
    static func makeEmpty() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Fenestra"
        window.titlebarAppearsTransparent = true
        window.center()
        window.setFrameAutosaveName("Fenestra.MainWindow")
        return window
    }
}
