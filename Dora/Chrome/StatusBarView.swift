import AppKit

/// Bottom bar: item/selection counts, total size, quick view toggles.
@MainActor
final class StatusBarView: NSView {
    var onToggleDetails: (() -> Void)?
    var onTogglePreview: (() -> Void)?

    private let countLabel = NSTextField(labelWithString: "0 items")
    private let detailsButton = NSButton()
    private let previewButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.6).cgColor

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        configure(detailsButton, symbol: "sidebar.right", tooltip: "Details pane", action: #selector(detailsClicked))
        configure(previewButton, symbol: "eye", tooltip: "Preview pane", action: #selector(previewClicked))

        addSubview(countLabel)
        addSubview(detailsButton)
        addSubview(previewButton)

        NSLayoutConstraint.activate([
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            previewButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            previewButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailsButton.trailingAnchor.constraint(equalTo: previewButton.leadingAnchor, constant: -4),
            detailsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func configure(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.isBordered = false
        button.bezelStyle = .inline
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    func update(itemCount: Int, selectedCount: Int, selectedBytes: Int64?, detailsVisible: Bool, previewVisible: Bool) {
        var parts: [String] = ["\(itemCount) item\(itemCount == 1 ? "" : "s")"]
        if selectedCount > 0 {
            parts.append("\(selectedCount) selected")
        }
        if let selectedBytes, selectedBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file))
        }
        countLabel.stringValue = parts.joined(separator: "  |  ")
        detailsButton.state = detailsVisible ? .on : .off
        previewButton.state = previewVisible ? .on : .off
    }

    @objc private func detailsClicked() { onToggleDetails?() }
    @objc private func previewClicked() { onTogglePreview?() }
}
