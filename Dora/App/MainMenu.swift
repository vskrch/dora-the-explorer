import AppKit
import AppCore
import FSCore

/// Menu bar wiring. Every item routes to the key window's `WindowController`.
extension WindowController {
    @objc func menuNewTab() { newTab(directory: state.selectedTab?.directory) }
    @objc func menuDuplicateTab() { duplicateCurrentTab() }
    @objc func menuCloseTab() { closeCurrentTab() }
    @objc func menuCloseOtherTabs() {
        if let id = state.selectedTab?.id { state.closeOtherTabs(keeping: id) }
        syncChrome()
    }
    @objc func menuCloseTabsToRight() {
        if let id = state.selectedTab?.id { state.closeTabsToRight(of: id) }
        syncChrome()
    }
    @objc func menuMoveToNewWindow() {
        guard let id = state.selectedTab?.id else { return }
        tearOffTab(id, at: window?.frame.origin ?? .zero)
    }
    @objc func menuReopenClosedTab() { reopenClosedTab() }
    @objc func menuBack() { navigateTab { $0.goBack() } }
    @objc func menuForward() { navigateTab { $0.goForward() } }
    @objc func menuUp() { navigateTab { $0.goUp() } }
    @objc func menuRefresh() {
        if let chrome = window?.contentView as? ExplorerChromeView { chrome.reloadDirectory() }
    }
    @objc func menuEditPath() {
        (window?.contentView as? ExplorerChromeView)?.focusPathFieldIfPossible()
    }
    @objc func menuCycleTabNext() { cycleTab(forward: true) }
    @objc func menuCycleTabPrevious() { cycleTab(forward: false) }
    @objc func menuSelectTab(_ sender: NSMenuItem) { selectTab(at: sender.tag) }

    private func navigateTab(_ action: (TabState) -> Void) {
        guard let tab = state.selectedTab else { return }
        action(tab)
        ChromeCaches.persist(state)
        syncChrome()
    }
}

@MainActor
enum MainMenu {
    static func install() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Dora the Explorer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: nil, keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Dora the Explorer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Dora the Explorer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        let newTab = fileMenu.addItem(withTitle: "New Tab", action: #selector(WindowController.menuNewTab), keyEquivalent: "t")
        newTab.target = nil
        let newFolder = fileMenu.addItem(withTitle: "New Folder", action: #selector(AppDelegate.menuNewFolder(_:)), keyEquivalent: "N")
        newFolder.keyEquivalentModifierMask = [.command, .shift]
        let renameItem = fileMenu.addItem(withTitle: "Rename", action: #selector(WindowController.menuRename), keyEquivalent: String(UnicodeScalar(NSF2FunctionKey)!))
        renameItem.keyEquivalentModifierMask = []
        renameItem.target = nil
        fileMenu.addItem(.separator())
        let closeTab = fileMenu.addItem(withTitle: "Close Tab", action: #selector(WindowController.menuCloseTab), keyEquivalent: "w")
        closeTab.target = nil
        let reopen = fileMenu.addItem(withTitle: "Reopen Closed Tab", action: #selector(WindowController.menuReopenClosedTab), keyEquivalent: "T")
        reopen.target = nil
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Edit
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Go
        let goItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")
        let back = goMenu.addItem(withTitle: "Back", action: #selector(WindowController.menuBack), keyEquivalent: "[")
        back.target = nil
        let forward = goMenu.addItem(withTitle: "Forward", action: #selector(WindowController.menuForward), keyEquivalent: "]")
        forward.target = nil
        let up = goMenu.addItem(withTitle: "Enclosing Folder", action: #selector(WindowController.menuUp), keyEquivalent: "^")
        up.keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(.separator())
        let editPath = goMenu.addItem(withTitle: "Go to Folder…", action: #selector(WindowController.menuEditPath), keyEquivalent: "l")
        editPath.target = nil
        goMenu.addItem(.separator())
        for (index, symbol) in ["1", "2", "3", "4", "5", "6", "7", "8", "9"].enumerated() {
            let item = goMenu.addItem(withTitle: "Tab \(symbol)", action: #selector(WindowController.menuSelectTab(_:)), keyEquivalent: symbol)
            item.tag = index
            item.target = nil
        }
        goItem.submenu = goMenu
        mainMenu.addItem(goItem)

        // View
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let refresh = viewMenu.addItem(withTitle: "Refresh", action: #selector(WindowController.menuRefresh), keyEquivalent: "r")
        refresh.target = nil
        viewMenu.addItem(.separator())
        let details = viewMenu.addItem(withTitle: "Details Pane", action: #selector(AppDelegate.toggleDetailsPane(_:)), keyEquivalent: "i")
        details.keyEquivalentModifierMask = [.command, .option]
        let preview = viewMenu.addItem(withTitle: "Preview Pane", action: #selector(AppDelegate.togglePreviewPane(_:)), keyEquivalent: "p")
        preview.keyEquivalentModifierMask = [.command, .option]
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // Window
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let nextTab = windowMenu.addItem(withTitle: "Show Next Tab", action: #selector(WindowController.menuCycleTabNext), keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = [.control]
        nextTab.target = nil
        let previousTab = windowMenu.addItem(withTitle: "Show Previous Tab", action: #selector(WindowController.menuCycleTabPrevious), keyEquivalent: "\t")
        previousTab.keyEquivalentModifierMask = [.control, .shift]
        previousTab.target = nil
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
