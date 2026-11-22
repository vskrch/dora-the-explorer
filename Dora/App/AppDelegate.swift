import AppKit
import Foundation
import AppCore
import FSCore

/// AppKit lifecycle delegate. The app boots via the explicit `main.swift`
/// bootstrap (which wires the delegate directly) instead of the `@main`
/// codegen — the generated entry point was observed leaving `NSApp.delegate`
/// nil on macOS 26.3/Xcode 26.6 debug builds, leaving the app running with
/// zero windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainMenu.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DoraLog.ui.info("Dora the Explorer launched")
        NSApp.setActivationPolicy(.regular)
        BreadcrumbVolumeName.warmCache()
        FileIconCache.shared.warmCommonTypes()

        if !WindowRegistry.shared.restoreWorkspaceIfEnabled() {
            WindowRegistry.shared.openWindow()
        }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        WindowRegistry.shared.saveWorkspace(synchronously: true)
        FolderViewStore.shared.flushNow()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu actions

    @objc func newWindow(_ sender: Any?) {
        WindowRegistry.shared.openWindow()
    }

    @objc func menuNewFolder(_ sender: Any?) {
        keyController?.menuNewFolder()
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
