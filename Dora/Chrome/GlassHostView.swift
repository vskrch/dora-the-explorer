import AppKit
import DesignSystem
import SwiftUI

/// Hosts SwiftUI content that uses Liquid Glass (`.glassEffect`) chrome.
///
/// SwiftUI owns the glass; AppKit owns layout. Reduce Transparency is honoured
/// by the `ChromeBackground` solid fallback.
@MainActor
enum ChromeViewFactory {
    static func glassBackground(material: ChromeBackgroundView.Material) -> NSView {
        let view = ChromeBackgroundView(material: material)
        view.blendingMode = .behindWindow
        return view
    }

    static func hosting<Content: View>(_ content: Content) -> NSView {
        let host = NSHostingView(rootView: content)
        host.layer?.backgroundColor = .clear
        return host
    }
}
