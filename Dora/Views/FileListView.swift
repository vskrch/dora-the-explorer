import SwiftUI
import UniformTypeIdentifiers

struct FileListView: View {
    @ObservedObject var model: ExplorerViewModel

    var body: some View {
        Group {
            if let error = model.errorMessage {
                emptyState(
                    title: "Can't open this folder",
                    subtitle: error,
                    systemImage: "exclamationmark.triangle"
                )
            } else if model.visibleItems.isEmpty {
                emptyState(
                    title: model.searchText.isEmpty ? "This folder is empty" : "No items match your search",
                    subtitle: model.searchText.isEmpty
                        ? "Drop files here or create a new folder"
                        : "Try a different search term",
                    systemImage: model.searchText.isEmpty ? "folder" : "magnifyingglass"
                )
            } else {
                switch model.viewMode {
                case .details:
                    detailsTable
                case .icons:
                    iconsGrid
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ExplorerTheme.listBackground)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .contextMenu {
            listContextMenu
        }
    }

    private var detailsTable: some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.visibleItems) { item in
                        DetailsRowView(item: item, model: model)
                    }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            sortHeader(.name, width: nil, flex: true)
            sortHeader(.modified, width: 160, flex: false)
            sortHeader(.type, width: 120, flex: false)
            sortHeader(.size, width: 90, flex: false)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(ExplorerTheme.toolbarBackground)
    }

    private func sortHeader(_ column: SortColumn, width: CGFloat?, flex: Bool) -> some View {
        Button {
            model.toggleSort(column)
        } label: {
            HStack(spacing: 4) {
                Text(column.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ExplorerTheme.secondaryText)
                if model.sortColumn == column {
                    Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(ExplorerTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: flex ? .infinity : width, alignment: .leading)
            .frame(width: flex ? nil : width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var iconsGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 12)],
                spacing: 16
            ) {
                ForEach(model.visibleItems) { item in
                    IconItemView(item: item, model: model)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var listContextMenu: some View {
        Button("New folder") { model.createNewFolder() }
        Button("Paste") { model.paste() }
        Divider()
        Button("Refresh") { model.refresh() }
        Button("Reveal in Finder") { model.revealSelectedInFinder() }
        Divider()
        Toggle("Show hidden files", isOn: Binding(
            get: { model.showHidden },
            set: { model.showHidden = $0; model.refresh() }
        ))
    }

    private func emptyState(title: String, subtitle: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(ExplorerTheme.secondaryText.opacity(0.7))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(ExplorerTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data,
                   let path = String(data: data, encoding: .utf8),
                   let url = URL(string: path) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
                }
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty {
                model.handleDrop(urls: urls)
            }
        }
        return true
    }
}

struct DetailsRowView: View {
    let item: FileItem
    @ObservedObject var model: ExplorerViewModel
    @State private var isHovered = false

    private var isSelected: Bool { model.selectedIDs.contains(item.id) }
    private var isRenaming: Bool { model.renamingItemID == item.id }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                FileIconView(item: item, size: 16)
                if isRenaming {
                    TextField("Name", text: $model.renameDraft, onCommit: model.commitRename)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onExitCommand { model.cancelRename() }
                } else {
                    Text(item.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.formattedModified)
                .font(.system(size: 12))
                .foregroundStyle(ExplorerTheme.secondaryText)
                .frame(width: 160, alignment: .leading)

            Text(item.typeDescription)
                .font(.system(size: 12))
                .foregroundStyle(ExplorerTheme.secondaryText)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            Text(item.formattedSize)
                .font(.system(size: 12))
                .foregroundStyle(ExplorerTheme.secondaryText)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(rowBackground)
        .overlay(
            Rectangle()
                .stroke(isSelected ? ExplorerTheme.selectionBorder : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { model.open(item) }
        .onTapGesture(count: 1) { select(item) }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .contextMenu { itemContextMenu }
    }

    private var rowBackground: Color {
        if isSelected { return ExplorerTheme.selection }
        if isHovered { return ExplorerTheme.hover }
        return .clear
    }

    private func select(_ item: FileItem) {
        if NSEvent.modifierFlags.contains(.command) {
            if model.selectedIDs.contains(item.id) {
                model.selectedIDs.remove(item.id)
            } else {
                model.selectedIDs.insert(item.id)
            }
        } else if NSEvent.modifierFlags.contains(.shift), let first = model.selectedIDs.first,
                  let from = model.visibleItems.firstIndex(where: { $0.id == first }),
                  let to = model.visibleItems.firstIndex(where: { $0.id == item.id }) {
            let range = from < to ? from...to : to...from
            model.selectedIDs = Set(model.visibleItems[range].map(\.id))
        } else {
            model.selectedIDs = [item.id]
        }
    }

    @ViewBuilder
    private var itemContextMenu: some View {
        Button(item.isDirectory ? "Open" : "Open") { model.open(item) }
        Button("Reveal in Finder") {
            model.selectedIDs = [item.id]
            model.revealSelectedInFinder()
        }
        Divider()
        Button("Cut") {
            model.selectedIDs = [item.id]
            model.cutSelected()
        }
        Button("Copy") {
            model.selectedIDs = [item.id]
            model.copySelected()
        }
        Button("Rename") {
            model.selectedIDs = [item.id]
            model.beginRename()
        }
        Button("Move to Trash", role: .destructive) {
            model.selectedIDs = [item.id]
            model.deleteSelected()
        }
    }
}

struct IconItemView: View {
    let item: FileItem
    @ObservedObject var model: ExplorerViewModel
    @State private var isHovered = false

    private var isSelected: Bool { model.selectedIDs.contains(item.id) }
    private var isRenaming: Bool { model.renamingItemID == item.id }

    var body: some View {
        VStack(spacing: 6) {
            FileIconView(item: item, size: 48)
            if isRenaming {
                TextField("Name", text: $model.renameDraft, onCommit: model.commitRename)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .onExitCommand { model.cancelRename() }
            } else {
                Text(item.name)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 88)
            }
        }
        .padding(8)
        .frame(width: 100, height: 100)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? ExplorerTheme.selection : (isHovered ? ExplorerTheme.hover : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? ExplorerTheme.selectionBorder : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { model.open(item) }
        .onTapGesture(count: 1) {
            if NSEvent.modifierFlags.contains(.command) {
                if model.selectedIDs.contains(item.id) {
                    model.selectedIDs.remove(item.id)
                } else {
                    model.selectedIDs.insert(item.id)
                }
            } else {
                model.selectedIDs = [item.id]
            }
        }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .contextMenu {
            Button("Open") { model.open(item) }
            Button("Cut") { model.selectedIDs = [item.id]; model.cutSelected() }
            Button("Copy") { model.selectedIDs = [item.id]; model.copySelected() }
            Button("Rename") { model.selectedIDs = [item.id]; model.beginRename() }
            Button("Move to Trash", role: .destructive) {
                model.selectedIDs = [item.id]
                model.deleteSelected()
            }
        }
    }
}
