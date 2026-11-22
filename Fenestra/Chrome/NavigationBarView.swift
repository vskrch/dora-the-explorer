import AppKit

/// Row 2: back / forward / up / refresh, breadcrumb, search field.
@MainActor
final class NavigationBarView: NSView {
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onUp: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onPathSubmitted: ((String) -> Void)?
    var onSearchChanged: ((String) -> Void)?

    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let refreshButton = NSButton()
    private let breadcrumbLabel = NSTextField(labelWithString: "")
    private let pathField = NSTextField()
    private let searchField = NSSearchField()
    private var isEditingPath = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setup() {
        let buttons: [(NSButton, String, String, Selector)] = [
            (backButton, "chevron.left", "Back", #selector(backClicked)),
            (forwardButton, "chevron.right", "Forward", #selector(forwardClicked)),
            (upButton, "chevron.up", "Up", #selector(upClicked)),
            (refreshButton, "arrow.clockwise", "Refresh", #selector(refreshClicked)),
        ]
        for (button, symbol, tooltip, action) in buttons {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            button.isBordered = false
            button.bezelStyle = .inline
            button.toolTip = tooltip
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        }

        breadcrumbLabel.font = .systemFont(ofSize: 12)
        breadcrumbLabel.lineBreakMode = .byTruncatingMiddle
        breadcrumbLabel.isSelectable = false
        breadcrumbLabel.translatesAutoresizingMaskIntoConstraints = false

        pathField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        pathField.isBordered = false
        pathField.drawsBackground = false
        pathField.target = self
        pathField.action = #selector(pathSubmitted)
        pathField.isHidden = true
        pathField.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search"
        searchField.font = .systemFont(ofSize: 12)
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let addressBackground = AddressFieldBackground()
        addressBackground.translatesAutoresizingMaskIntoConstraints = false
        addressBackground.addSubview(breadcrumbLabel)
        addressBackground.addSubview(pathField)

        let leadingStack = NSStackView(views: [backButton, forwardButton, upButton, refreshButton])
        leadingStack.orientation = .horizontal
        leadingStack.spacing = 2
        leadingStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(leadingStack)
        addSubview(addressBackground)
        addSubview(searchField)

        NSLayoutConstraint.activate([
            leadingStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            leadingStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            addressBackground.leadingAnchor.constraint(equalTo: leadingStack.trailingAnchor, constant: 8),
            addressBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            addressBackground.heightAnchor.constraint(equalToConstant: 26),

            breadcrumbLabel.leadingAnchor.constraint(equalTo: addressBackground.leadingAnchor, constant: 8),
            breadcrumbLabel.trailingAnchor.constraint(equalTo: addressBackground.trailingAnchor, constant: -8),
            breadcrumbLabel.centerYAnchor.constraint(equalTo: addressBackground.centerYAnchor),

            pathField.leadingAnchor.constraint(equalTo: addressBackground.leadingAnchor, constant: 8),
            pathField.trailingAnchor.constraint(equalTo: addressBackground.trailingAnchor, constant: -8),
            pathField.centerYAnchor.constraint(equalTo: addressBackground.centerYAnchor),

            searchField.leadingAnchor.constraint(equalTo: addressBackground.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 220),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(beginPathEditing))
        click.numberOfClicksRequired = 1
        addressBackground.addGestureRecognizer(click)
    }

    func update(path: String, canGoBack: Bool, canGoForward: Bool, canGoUp: Bool) {
        breadcrumbLabel.stringValue = Self.displayPath(path)
        pathField.stringValue = path
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
        upButton.isEnabled = canGoUp
    }

    var searchText: String {
        get { searchField.stringValue }
        set { searchField.stringValue = newValue }
    }

    func focusPathField() {
        beginPathEditing()
        window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }

    private static func displayPath(_ path: String) -> String {
        if path == "/" { return "Macintosh HD" }
        return path
    }

    @objc private func beginPathEditing() {
        guard !isEditingPath else { return }
        isEditingPath = true
        breadcrumbLabel.isHidden = true
        pathField.isHidden = false
        pathField.stringValue = breadcrumbLabel.stringValue
        window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }

    private func endPathEditing() {
        isEditingPath = false
        pathField.isHidden = true
        breadcrumbLabel.isHidden = false
    }

    @objc private func pathSubmitted() {
        let value = pathField.stringValue
        endPathEditing()
        onPathSubmitted?(value)
        window?.makeFirstResponder(nil)
    }

    @objc private func searchChanged() {
        onSearchChanged?(searchField.stringValue)
    }

    @objc private func backClicked() { onBack?() }
    @objc private func forwardClicked() { onForward?() }
    @objc private func upClicked() { onUp?() }
    @objc private func refreshClicked() { onRefresh?() }

    override func cancelOperation(_ sender: Any?) {
        endPathEditing()
    }
}

/// Rounded field background used by the address bar and command bar groups.
final class AddressFieldBackground: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
    }
}
