import AppKit
import FSCore

/// Inline rename validation, Explorer style: reject separators and NULs,
/// detect duplicate names case-insensitively (Windows behaviour).
enum RenameValidator {
    static func illegalCharacters(in name: String) -> Set<Character> {
        var illegal = Set<Character>()
        for character in name {
            if character == "/" || character == "\u{0}" {
                illegal.insert(character)
            }
        }
        return illegal
    }

    /// Returns an error message when the new name is invalid, nil when valid.
    /// Duplicate check is NFC-normalized and case/diacritic-insensitive, but
    /// always excludes the item's own current name (pure case changes pass).
    static func validate(
        newName: String,
        originalName: String,
        existingNames: [String]
    ) -> String? {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return "Names can't be empty."
        }
        if trimmed == "." || trimmed == ".." {
            return "“\(trimmed)” is reserved and can't be used."
        }
        if trimmed.utf8.count > 255 {
            return "Names can't be longer than 255 bytes."
        }
        if !illegalCharacters(in: trimmed).isEmpty {
            return "Names can't contain the “/” character."
        }
        let normalized = trimmed.precomposedStringWithCanonicalMapping
        for existing in existingNames where existing != originalName {
            let other = existing.precomposedStringWithCanonicalMapping
            if other.compare(normalized, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                return "An item named “\(trimmed)” already exists."
            }
        }
        return nil
    }
}

/// Overlay text field used for inline rename. F2/Rename selects the name
/// without its extension, Enter commits, Tab commits and moves rename to the
/// next selected item, Esc cancels. Invalid names flash the field red with an
/// inline message — never a modal.
@MainActor
final class InlineRenameField: NSObject, NSTextFieldDelegate {
    let field = NSTextField()
    let errorLabel = NSTextField(labelWithString: "")

    var onCommit: ((_ newName: String, _ moveToNext: Bool) -> Void)?
    var onCancel: (() -> Void)?

    private weak var hostView: NSView?
    private var errorTimer: Task<Void, Never>?

    func begin(in view: NSView, rect: NSRect, currentName: String) {
        cancelVisuals()
        hostView = view

        field.delegate = self
        field.stringValue = currentName
        field.font = .systemFont(ofSize: 13)
        field.backgroundColor = .textBackgroundColor
        field.drawsBackground = true
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.frame = rect
        field.setFrameSize(NSSize(width: max(rect.width, 150), height: rect.height))

        view.addSubview(field)
        view.window?.makeFirstResponder(field)

        // Select the base name (extension untouched), like Windows/F2.
        let basename = (currentName as NSString).deletingPathExtension
        if basename.isEmpty {
            field.currentEditor()?.selectAll(nil)
        } else if currentName.hasPrefix(basename) {
            // Anchored prefix, not the first occurrence ("notes.notes.txt"
            // must select "notes.notes", not "notes").
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: basename.utf16.count)
        } else {
            field.currentEditor()?.selectAll(nil)
        }
    }

    func cancel() {
        errorTimer?.cancel()
        errorTimer = nil
        field.delegate = nil
        field.removeFromSuperview()
        errorLabel.removeFromSuperview()
        hostView = nil
    }

    func showError(_ message: String) {
        NSSound.beep()
        field.backgroundColor = .systemRed.withAlphaComponent(0.18)
        field.toolTip = message

        if let host = field.superview ?? hostView {
            errorLabel.stringValue = message
            errorLabel.font = .systemFont(ofSize: 11)
            errorLabel.textColor = .white
            errorLabel.wantsLayer = true
            errorLabel.layer?.cornerRadius = 4
            errorLabel.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.9).cgColor
            errorLabel.setFrameSize(errorLabel.intrinsicContentSize)
            errorLabel.frame.origin = NSPoint(
                x: field.frame.minX,
                y: field.frame.minY - errorLabel.frame.height - 4
            )
            host.addSubview(errorLabel)
        }

        errorTimer?.cancel()
        errorTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.cancelVisuals()
        }
    }

    func cancelVisuals() {
        field.backgroundColor = .textBackgroundColor
        field.toolTip = nil
        errorLabel.removeFromSuperview()
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let movementNumber = obj.userInfo?["NSTextMovement"] as? Int else { return }
        switch movementNumber {
        case NSTextMovement.return.rawValue:
            onCommit?(field.stringValue, false)
        case NSTextMovement.tab.rawValue:
            onCommit?(field.stringValue, true)
        case NSTextMovement.backtab.rawValue:
            onCommit?(field.stringValue, false)
        case NSTextMovement.cancel.rawValue:
            onCancel?()
        default:
            onCancel?()
        }
    }
}
