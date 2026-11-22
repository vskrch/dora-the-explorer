import AppKit
import SwiftUI

/// AppKit-backed chrome background.
///
/// Uses `NSVisualEffectView` materials (the only real AppKit glass surface) and
/// switches to an opaque fill when Reduce Transparency / Increase Contrast is on.
public final class ChromeBackgroundView: NSVisualEffectView {
    public enum Material {
        case toolbar
        case sidebar
        case hud
    }

    private let preferred: Material

    public init(material: Material) {
        self.preferred = material
        super.init(frame: .zero)
        apply(material: material)
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        observeAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func apply(material: Material) {
        switch material {
        case .toolbar: self.material = .titlebar
        case .sidebar: self.material = .sidebar
        case .hud: self.material = .hudWindow
        }
    }

    private func observeAccessibility() {
        let names: [Notification.Name] = [
            NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
        ]
        for name in names {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(accessibilityChanged),
                name: name,
                object: nil
            )
        }
    }

    @objc private func accessibilityChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshAppearance()
        }
    }

    public func refreshAppearance() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            material = .windowBackground
            blendingMode = .behindWindow
        } else {
            apply(material: preferred)
        }
        needsDisplay = true
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }
}

/// SwiftUI wrapper for `ChromeBackgroundView`.
public struct ChromeBackground: NSViewRepresentable {
    public let material: ChromeBackgroundView.Material

    public init(material: ChromeBackgroundView.Material) {
        self.material = material
    }

    public func makeNSView(context: Context) -> ChromeBackgroundView {
        ChromeBackgroundView(material: material)
    }

    public func updateNSView(_ nsView: ChromeBackgroundView, context: Context) {
        nsView.refreshAppearance()
    }
}
