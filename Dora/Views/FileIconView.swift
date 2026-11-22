import AppKit
import SwiftUI

struct FileIconView: View {
    let item: FileItem
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: item.systemIcon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
