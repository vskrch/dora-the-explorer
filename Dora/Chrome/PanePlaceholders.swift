import AppKit
import FSCore

/// Left pane placeholder: the navigation pane lands in Phase 7.
@MainActor
final class SidebarPlaceholderView: NSView {
    private let label = NSTextField(labelWithString: "Navigation")
    private let pathLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(pathLabel)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            pathLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            pathLabel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(directory: URL) {
        pathLabel.stringValue = directory.lastPathComponent
    }
}

/// Right pane placeholder: Details/Preview lands in Phase 11.
@MainActor
final class DetailsPlaceholderView: NSView {
    private let label = NSTextField(labelWithString: "Details")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
