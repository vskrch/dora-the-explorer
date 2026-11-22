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
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 900, height: 520)
        window.center()
        window.setFrameAutosaveName("Dora.MainWindow")
        return window
    }
}
