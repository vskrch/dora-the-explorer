import SwiftUI

struct NavigationPaneView: View {
    @ObservedObject var model: ExplorerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(NavGroup.allCases, id: \.rawValue) { group in
                sectionHeader(group.rawValue)
                ForEach(model.navDestinations.filter { $0.group == group }) { destination in
                    navRow(destination)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ExplorerTheme.paneBackground)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ExplorerTheme.secondaryText)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func navRow(_ destination: NavDestination) -> some View {
        let selected = model.currentURL.standardizedFileURL == destination.url.standardizedFileURL
        return Button {
            model.navigate(to: destination.url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: destination.systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(ExplorerTheme.accentBlue)
                    .frame(width: 16)
                Text(destination.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(selected ? ExplorerTheme.selection : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(selected ? ExplorerTheme.selectionBorder : Color.clear, lineWidth: 1)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
