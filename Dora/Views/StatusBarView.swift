import SwiftUI

struct StatusBarView: View {
    @ObservedObject var model: ExplorerViewModel

    var body: some View {
        HStack(spacing: 12) {
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Text(model.itemCountLabel)
                .font(.system(size: 11))
            Spacer()
            Text(model.currentURL.path)
                .font(.system(size: 11))
                .foregroundStyle(ExplorerTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .frame(height: ExplorerTheme.statusBarHeight)
        .background(ExplorerTheme.statusBarBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ExplorerTheme.border)
                .frame(height: 1)
        }
    }
}
