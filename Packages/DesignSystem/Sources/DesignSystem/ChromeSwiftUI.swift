import Foundation
import SwiftUI

/// Chrome surfaces that need to match Explorer's glass / solid behaviour.
public enum ChromeSurface {
    /// Opaque content area: text must stay legible, no glass here.
    public static let contentBackground = Color(nsColor: .windowBackgroundColor)

    /// Solid fallback used when Reduce Transparency is on.
    public static let solidChrome = Color(nsColor: .windowBackgroundColor)

    public static let divider = Color(nsColor: .separatorColor)
    public static let secondaryText = Color(nsColor: .secondaryLabelColor)

    /// Grouped selection fill, Explorer-like soft blue.
    public static let selectionFill = Color.accentColor.opacity(0.22)
    public static let selectionBorder = Color.accentColor.opacity(0.65)
    public static let hoverFill = Color(nsColor: .quaternaryLabelColor).opacity(0.35)
}

/// Reads the accessibility settings that must degrade the chrome.
@MainActor
public enum AccessibilityEnvironment {
    public static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    public static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    public static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public static var usesSolidChrome: Bool {
        reduceTransparency || increaseContrast
    }
}
