import AppKit
import AppCore
import FSCore

/// NSTableView subclass with the Explorer behaviours AppKit doesn't expose:
/// Enter-to-open, middle-click-to-new-tab, and the clipboard/undo actions
/// (they arrive through the responder chain, exactly like text editing).
@MainActor
final class FileTableView: NSTableView {
    var onOpenRows: ((IndexSet, Bool) -> Void)?
    var onMiddleClickRow: ((Int) -> Void)?
    var onNavigateBack: (() -> Void)?
    var onContextMenu: ((NSEvent) -> NSMenu?)?

    private var controller: WindowController? {
        window?.windowController as? WindowController
    }

    override func keyDown(with event: NSEvent) {
        if event.specialKey == .carriageReturn {
            onOpenRows?(selectedRowIndexes, event.modifierFlags.contains(.command))
            return
        }
        if event.specialKey == .delete {
            // Windows: the Delete key trashes the selection.
            controller?.trashSelectedItems()
            return
        }
        if event.specialKey == .backspace && event.modifierFlags.contains(.command) {
            // macOS habit: Cmd+Backspace trashes too.
            controller?.trashSelectedItems()
            return
        }
        if event.specialKey == .backspace {
            // Windows: Backspace navigates up/back.
            onNavigateBack?()
            return
        }
        super.keyDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            let point = convert(event.locationInWindow, from: nil)
            let row = row(at: point)
            if row >= 0 {
                onMiddleClickRow?(row)
            }
        }
        super.otherMouseUp(with: event)
    }

    /// Right-click context menu, built by the details controller.
    override func menu(for event: NSEvent) -> NSMenu? {
        onContextMenu?(event)
    }

    // MARK: - Responder-chain actions
    //
    // NSTableView doesn't declare these, but the responder chain finds them
    // by selector when the table is first responder — Edit menu items with
    // nil targets dispatch here exactly like they do for text views.

    @objc func copy(_ sender: Any?) { controller?.copySelectedItems() }
    @objc func cut(_ sender: Any?) { controller?.cutSelectedItems() }
    @objc func paste(_ sender: Any?) { controller?.pasteIntoCurrentTab() }
    @objc func undo(_ sender: Any?) { controller?.performUndo() }
    @objc func redo(_ sender: Any?) { controller?.performRedo() }

    /// Trash the selection (File menu / Delete key semantics).
    @objc func performDelete(_ sender: Any?) { controller?.trashSelectedItems() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let controller else { return false }
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)):
            return controller.hasSelection
        case #selector(performDelete(_:)):
            return controller.hasSelection
        case #selector(paste(_:)):
            return controller.clipboardHasFiles
        case #selector(undo(_:)):
            return controller.canUndo
        case #selector(redo(_:)):
            return controller.canRedo
        default:
            return true
        }
    }
}

/// A row view with Explorer's soft rounded selection + hover fill. Selection
/// uses a translucent accent so cell text keeps its label color in both
/// appearances (no white-on-white, no dark-on-dark).
@MainActor
final class FileTableRowView: NSTableRowView {
    /// Set by the view controller; group header rows never hover-highlight
    /// or show item selection.
    var isGroupHeader = false

    private var hovered = false
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard !isGroupHeader, selectionHighlightStyle != .none, isSelected else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5)
        NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
        path.fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if hovered, !isGroupHeader, !isSelected {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5)
            NSColor.labelColor.withAlphaComponent(0.045).setFill()
            path.fill()
        }
    }
}

/// Base class for the text columns: a label with monospaced digits.
@MainActor
final class FileTextCellView: NSTableCellView {
    let valueLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        valueLabel.font = .systemFont(ofSize: 12)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)
        textField = valueLabel
        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(text: String, alignment: NSTextAlignment) {
        valueLabel.stringValue = text
        valueLabel.alignment = alignment
    }
}

/// Name column: file icon + display name.
@MainActor
final class FileNameCellView: NSTableCellView {
    let iconView = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(nameLabel)
        textField = nameLabel

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(item: FileItem, name: String) {
        iconView.image = FileIconCache.shared.icon(for: item, preferredSize: CGSize(width: 18, height: 18))
        nameLabel.stringValue = name
        setAccessibilityLabel(name)
        setAccessibilityValue(item.typeDescription)
    }

    /// Windows cut-ghosting: dimmed until the paste completes or is aborted.
    func setCutAppearance(_ isCut: Bool) {
        alphaValue = isCut ? 0.45 : 1.0
    }
}

/// Collapsible group header row.
@MainActor
final class GroupHeaderCellView: NSTableCellView {
    let chevron = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let countLabel = NSTextField(labelWithString: "")

    var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.target = self
        button.action = #selector(toggle)
        button.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(button)
        button.addSubview(chevron)
        addSubview(titleLabel)
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 26),
            chevron.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            chevron.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 0),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        button.toolTip = "Collapse or expand group"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(title: String, count: Int, isCollapsed: Bool) {
        titleLabel.stringValue = title
        countLabel.stringValue = count == 1 ? "1 item" : "\(count) items"
        chevron.image = NSImage(systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
    }

    @objc private func toggle() {
        onToggle?()
    }
}
