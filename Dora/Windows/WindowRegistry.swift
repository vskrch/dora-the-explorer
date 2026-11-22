import AppKit
import Foundation
import AppCore
import FSCore

/// Owns every open window and the workspace that is restored on launch.
@MainActor
final class WindowRegistry: NSObject {
    static let shared = WindowRegistry()

    private(set) var controllers: [WindowController] = []
    private let store = WorkspaceStore()
    private var isRestoring = false

    private override init() { super.init() }

    @discardableResult
    func openWindow(state: WindowState? = nil, restoring: Bool = false) -> WindowController {
        let resolved = state ?? WindowState(tabs: [TabState(directory: FileManager.default.homeDirectoryForCurrentUser)])
        ChromeCaches.restore(into: resolved)
        let controller = WindowController(state: resolved)
        controllers.append(controller)

        controller.window?.delegate = self
        controller.window?.makeKeyAndOrderFront(nil)

        if !restoring { scheduleSave() }
        return controller
    }

    func closeWindow(_ controller: WindowController) {
        // Persist BEFORE removing the controller: closing the LAST window
        // otherwise snapshots an empty workspace and the next launch restores
        // nothing (quit-by-closing must behave like quit-by-menu).
        let windows = controllers.map { $0.state.persisted }
        store.save(.init(windows: windows, isEnabled: true))

        controller.tearDown()
        controllers.removeAll { $0 === controller }
    }

    // MARK: - Workspace restore

    func restoreWorkspaceIfEnabled() -> Bool {
        guard UserDefaults.standard.object(forKey: Self.restoreKey) == nil
                || UserDefaults.standard.bool(forKey: Self.restoreKey),
              let workspace = store.load(),
              !workspace.windows.isEmpty
        else { return false }

        isRestoring = true
        for index in workspace.windows.indices {
            let persisted = workspace.windows[index]
            let state = WindowState.restore(from: persisted)
            let controller = openWindow(state: state)
            controller.syncChrome()
        }
        isRestoring = false
        return true
    }

    func saveWorkspace(synchronously: Bool = false) {
        guard UserDefaults.standard.object(forKey: Self.restoreKey) == nil
                || UserDefaults.standard.bool(forKey: Self.restoreKey)
        else { return }
        let windows = controllers.map { $0.state.persisted }
        store.save(.init(windows: windows, isEnabled: true), synchronous: synchronously)
    }

    private var saveWorkItem: DispatchWorkItem?

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveWorkspace() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    static let restoreKey = "settings.restoreWindowsOnLaunch"
}

extension WindowRegistry: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let controller = controllers.first(where: { $0.window === window }) else { return }
        closeWindow(controller)
    }

    func windowDidResize(_ notification: Notification) {
        scheduleSave()
    }
}
