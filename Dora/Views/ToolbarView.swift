import SwiftUI

struct ToolbarView: View {
    @ObservedObject var model: ExplorerViewModel

    var body: some View {
        HStack(spacing: 8) {
            navigationCluster
            Divider().frame(height: 22)
            actionCluster
            Spacer(minLength: 8)
            searchField
            viewModePicker
        }
        .padding(.horizontal, 10)
        .frame(height: ExplorerTheme.toolbarHeight)
        .background(ExplorerTheme.toolbarBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(ExplorerTheme.border)
                .frame(height: 1)
        }
    }

    private var navigationCluster: some View {
        HStack(spacing: 4) {
            toolbarButton("chevron.left", enabled: model.canGoBack, help: "Back") {
                model.goBack()
            }
            toolbarButton("chevron.right", enabled: model.canGoForward, help: "Forward") {
                model.goForward()
            }
            toolbarButton("chevron.up", enabled: model.canGoUp, help: "Up") {
                model.goUp()
            }
            toolbarButton("arrow.clockwise", enabled: true, help: "Refresh") {
                model.refresh()
            }
        }
    }

    private var actionCluster: some View {
        HStack(spacing: 4) {
            toolbarButton("folder.badge.plus", enabled: true, help: "New folder") {
                model.createNewFolder()
            }
            toolbarButton("scissors", enabled: !model.selectedIDs.isEmpty, help: "Cut") {
                model.cutSelected()
            }
            toolbarButton("doc.on.doc", enabled: !model.selectedIDs.isEmpty, help: "Copy") {
                model.copySelected()
            }
            toolbarButton("doc.on.clipboard", enabled: true, help: "Paste") {
                model.paste()
            }
            toolbarButton("trash", enabled: !model.selectedIDs.isEmpty, help: "Delete") {
                model.deleteSelected()
            }
            toolbarButton("pencil", enabled: model.selectedIDs.count == 1, help: "Rename") {
                model.beginRename()
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ExplorerTheme.secondaryText)
            TextField("Search \(model.currentURL.lastPathComponent)", text: $model.searchText)
                .textFieldStyle(.plain)
                .frame(minWidth: 140, maxWidth: 220)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(ExplorerTheme.addressBarBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(ExplorerTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var viewModePicker: some View {
        Picker("View", selection: $model.viewMode) {
            ForEach(ViewMode.allCases) { mode in
                Image(systemName: mode.systemImage)
                    .tag(mode)
                    .help(mode.title)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 80)
        .labelsHidden()
    }

    private func toolbarButton(
        _ systemName: String,
        enabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
    }
}
