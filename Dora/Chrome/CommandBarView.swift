import AppKit

/// Row 3: command bar (wired to the command registry in Phase 8).
@MainActor
final class CommandBarView: NSView {
    var onNew: (() -> Void)?
    var onSort: (() -> Void)?
    var onView: (() -> Void)?
    var onFilter: (() -> Void)?

    /// Buttons by role, so menus anchor under the one that was clicked.
    private(set) var buttonsByRole: [String: NSButton] = [:]
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setup() {
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])

        stack.addArrangedSubview(makeButton("new", title: "New", symbol: "plus", tooltip: "New ▾", action: #selector(newClicked)))
        stack.addArrangedSubview(makeButton("sort", title: "Sort", symbol: "arrow.up.arrow.down", tooltip: "Sort ▾", action: #selector(sortClicked)))
        stack.addArrangedSubview(makeButton("view", title: "View", symbol: "square.grid.2x2", tooltip: "View ▾", action: #selector(viewClicked)))
        stack.addArrangedSubview(makeButton("filter", title: "Filter", symbol: "line.3.horizontal.decrease.circle", tooltip: "Filter", action: #selector(filterClicked)))
    }

    private func makeButton(_ role: String, title: String, symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageLeading
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.toolTip = tooltip
        buttonsByRole[role] = button
        return button
    }

    @objc private func newClicked() { onNew?() }
    @objc private func sortClicked() { onSort?() }
    @objc private func viewClicked() { onView?() }
    @objc private func filterClicked() { onFilter?() }
}
