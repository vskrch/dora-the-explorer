import AppKit
import SwiftUI

struct AddressBarView: View {
    @ObservedObject var model: ExplorerViewModel
    @State private var isEditing = false
    @State private var pathDraft = ""

    var body: some View {
        HStack(spacing: 0) {
            if isEditing {
                TextField("Path", text: $pathDraft, onCommit: commitPath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .onExitCommand { isEditing = false }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(model.breadcrumbParts.enumerated()), id: \.offset) { index, part in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(ExplorerTheme.secondaryText)
                                    .padding(.horizontal, 2)
                            }
                            Button {
                                model.navigate(to: part.url)
                            } label: {
                                Text(part.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Color.clear)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(part.url.path)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .onTapGesture(count: 2) {
                    beginEditing()
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: ExplorerTheme.addressBarHeight - 8, maxHeight: ExplorerTheme.addressBarHeight - 8)
        .background(ExplorerTheme.addressBarBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(ExplorerTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(ExplorerTheme.toolbarBackground)
        .contextMenu {
            Button("Edit path") { beginEditing() }
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.currentURL.path, forType: .string)
            }
            Button("Reveal in Finder") { model.revealSelectedInFinder() }
        }
    }

    private func beginEditing() {
        pathDraft = model.currentURL.path
        isEditing = true
    }

    private func commitPath() {
        let trimmed = pathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        guard !trimmed.isEmpty else { return }
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        model.navigate(to: url)
    }
}
