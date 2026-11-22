import AppKit
import AppCore
import FSCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenu.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FenestraLog.ui.info("Fenestra launched")
        NSApp.setActivationPolicy(.regular)

        if !WindowRegistry.shared.restoreWorkspaceIfEnabled() {
            WindowRegistry.shared.openWindow()
        }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        WindowRegistry.shared.saveWorkspace()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu actions

    @objc func newWindow(_ sender: Any?) {
        WindowRegistry.shared.openWindow()
    }

    @objc func menuNewFolder(_ sender: Any?) {
        FenestraLog.ui.info("New folder command received (wired in Phase 3)")
    }

    @objc func toggleDetailsPane(_ sender: Any?) {
        keyController?.toggleDetailsPane()
    }

    @objc func togglePreviewPane(_ sender: Any?) {
        keyController?.togglePreviewPane()
    }

    private var keyController: WindowController? {
        WindowRegistry.shared.controllers.first { $0.window?.isKeyWindow == true }
            ?? (NSApp.keyWindow?.windowController as? WindowController)
    }
}

extension WindowController {
    func toggleDetailsPane() {
        state.selectedTab?.showsDetailsPane.toggle()
        ChromeCaches.persist(state)
        syncChrome()
    }

    func togglePreviewPane() {
        state.selectedTab?.showsPreviewPane.toggle()
        ChromeCaches.persist(state)
        syncChrome()
    }
}
