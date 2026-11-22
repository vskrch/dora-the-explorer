import AppKit
import SwiftUI

struct ExplorerRootView: View {
    @StateObject private var model = ExplorerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(model: model)
            AddressBarView(model: model)
            HStack(spacing: 0) {
                NavigationPaneView(model: model)
                    .frame(width: ExplorerTheme.navPaneWidth)
                Rectangle()
                    .fill(ExplorerTheme.border)
                    .frame(width: 1)
                FileListView(model: model)
            }
            StatusBarView(model: model)
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(ExplorerTheme.listBackground)
        .alert("Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .background(KeyCommandBridge(model: model))
        .onReceive(NotificationCenter.default.publisher(for: .doraNewFolder)) { _ in
            model.createNewFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .doraGoBack)) { _ in
            model.goBack()
        }
        .onReceive(NotificationCenter.default.publisher(for: .doraGoForward)) { _ in
            model.goForward()
        }
        .onReceive(NotificationCenter.default.publisher(for: .doraGoUp)) { _ in
            model.goUp()
        }
        .onReceive(NotificationCenter.default.publisher(for: .doraRefresh)) { _ in
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .doraRename)) { _ in
            model.beginRename()
        }
        .onReceive(NotificationCenter.default.publisher(for: .doraDelete)) { _ in
            model.deleteSelected()
        }
    }
}

/// Bridges AppKit key equivalents that SwiftUI Commands also cover when the window is key.
private struct KeyCommandBridge: NSViewRepresentable {
    let model: ExplorerViewModel

    func makeNSView(context: Context) -> NSView {
        let view = KeyCatcherView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? KeyCatcherView)?.model = model
    }
}

private final class KeyCatcherView: NSView {
    weak var model: ExplorerViewModel?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Don't steal focus from text fields (rename / search / address bar).
        if let responder = window?.firstResponder,
           responder is NSTextView || responder is NSTextField {
            return
        }
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard let model else {
            super.keyDown(with: event)
            return
        }

        if let responder = window?.firstResponder,
           responder is NSTextView || responder is NSTextField {
            super.keyDown(with: event)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        if flags.contains(.command) {
            switch chars {
            case "a":
                model.selectAll()
                return
            case "c":
                model.copySelected()
                return
            case "x":
                model.cutSelected()
                return
            case "v":
                model.paste()
                return
            case "r":
                model.refresh()
                return
            case "n":
                if flags.contains(.shift) {
                    model.createNewFolder()
                    return
                }
            default:
                break
            }
        }

        if event.keyCode == 36 { // Return
            if model.renamingItemID != nil {
                model.commitRename()
                return
            }
            if let item = model.selectedItems.first {
                model.open(item)
                return
            }
        }

        if event.keyCode == 51 || event.keyCode == 117 { // Delete / Forward Delete
            model.deleteSelected()
            return
        }

        if event.keyCode == 53 { // Escape
            if model.renamingItemID != nil {
                model.cancelRename()
            } else {
                model.selectedIDs.removeAll()
            }
            return
        }

        // F2 rename (Windows habit)
        if event.keyCode == 120 {
            model.beginRename()
            return
        }

        super.keyDown(with: event)
    }
}
