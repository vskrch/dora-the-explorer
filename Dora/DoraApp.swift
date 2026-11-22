import SwiftUI

@main
struct DoraApp: App {
    var body: some Scene {
        WindowGroup("Dora") {
            ExplorerRootView()
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Folder") {
                    NotificationCenter.default.post(name: .doraNewFolder, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandMenu("Go") {
                Button("Back") {
                    NotificationCenter.default.post(name: .doraGoBack, object: nil)
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("Forward") {
                    NotificationCenter.default.post(name: .doraGoForward, object: nil)
                }
                .keyboardShortcut("]", modifiers: .command)

                Button("Up") {
                    NotificationCenter.default.post(name: .doraGoUp, object: nil)
                }
                .keyboardShortcut(.upArrow, modifiers: .command)

                Button("Refresh") {
                    NotificationCenter.default.post(name: .doraRefresh, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            CommandGroup(after: .pasteboard) {
                Button("Rename") {
                    NotificationCenter.default.post(name: .doraRename, object: nil)
                }
                .keyboardShortcut("\r", modifiers: .command)

                Button("Move to Trash") {
                    NotificationCenter.default.post(name: .doraDelete, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let doraNewFolder = Notification.Name("dora.newFolder")
    static let doraGoBack = Notification.Name("dora.goBack")
    static let doraGoForward = Notification.Name("dora.goForward")
    static let doraGoUp = Notification.Name("dora.goUp")
    static let doraRefresh = Notification.Name("dora.refresh")
    static let doraRename = Notification.Name("dora.rename")
    static let doraDelete = Notification.Name("dora.delete")
}
