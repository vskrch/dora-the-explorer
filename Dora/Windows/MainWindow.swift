import AppKit

enum MainWindow {
    @MainActor
    static func make() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Dora the Explorer"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 900, height: 520)
        window.center()
        // Window-frame memory: deliberately NOT using setFrameAutosaveName —
        // it has restored degenerate frames (full-width, title-bar-height
        // strips) in the field. The app persists tabs/folders itself; if frame
        // memory returns, it must validate against minSize before applying.
        return window
    }
}
