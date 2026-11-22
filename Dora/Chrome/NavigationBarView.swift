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
    let breadcrumbBar = BreadcrumbBar()
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

        breadcrumbBar.translatesAutoresizingMaskIntoConstraints = false

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
        addressBackground.addSubview(breadcrumbBar)
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

            breadcrumbBar.leadingAnchor.constraint(equalTo: addressBackground.leadingAnchor, constant: 4),
            breadcrumbBar.trailingAnchor.constraint(equalTo: addressBackground.trailingAnchor, constant: -6),
            breadcrumbBar.centerYAnchor.constraint(equalTo: addressBackground.centerYAnchor),
            breadcrumbBar.heightAnchor.constraint(equalTo: addressBackground.heightAnchor),

            pathField.leadingAnchor.constraint(equalTo: addressBackground.leadingAnchor, constant: 8),
            pathField.trailingAnchor.constraint(equalTo: addressBackground.trailingAnchor, constant: -8),
            pathField.centerYAnchor.constraint(equalTo: addressBackground.centerYAnchor),

            searchField.leadingAnchor.constraint(equalTo: addressBackground.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 220),
        ])
    }

    func update(path: String, canGoBack: Bool, canGoForward: Bool, canGoUp: Bool) {
        breadcrumbBar.update(path: path)
        if !isEditingPath {
            pathField.stringValue = URL(fileURLWithPath: path).path
        }
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

    /// The bar hands its current path back on edit-mode entry.
    var currentDisplayedPath: String {
        pathField.stringValue
    }

    private func beginPathEditing() {
        guard !isEditingPath else { return }
        isEditingPath = true
        breadcrumbBar.isHidden = true
        pathField.isHidden = false
        pathField.stringValue = currentDisplayedPath
        window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }

    private func endPathEditing() {
        isEditingPath = false
        pathField.isHidden = true
        breadcrumbBar.isHidden = false
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
