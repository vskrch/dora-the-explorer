import AppKit

/// Custom tab strip drawn in the window's title bar.
///
/// Full AppKit so tab switching never waits on SwiftUI diffing: `reload`
/// rebuilds only what changed and selection is a layer-colour swap.
@MainActor
public final class TabStripView: NSView {
    public struct Tab {
        public let id: UUID
        public var title: String
        public var icon: NSImage?
        public var isClosable: Bool
    }

    public var tabs: [Tab] = [] {
        didSet { rebuild() }
    }
    public var selectedID: UUID? {
        didSet { if selectedID != oldValue { updateSelection(animated: false) } }
    }

    public var onSelect: ((UUID) -> Void)?
    public var onClose: ((UUID) -> Void)?
    public var onMiddleClickClose: ((UUID) -> Void)?
    public var onNewTab: (() -> Void)?
    public var onReorder: ((Int, Int) -> Void)?
    public var onMoveToNewWindow: ((UUID) -> Void)?
    public var onDragOut: ((UUID, NSPoint) -> Void)?
    public var onDropIn: ((UUID) -> Void)?
    public var contextMenuProvider: ((UUID) -> NSMenu?)?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let addButton = NSButton()
    private var tabViews: [TabItemView] = []
    private var trackingIndex: Int?

    private static let tabHeight: CGFloat = 30
    private static let tabMinWidth: CGFloat = 120

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setup() {
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.target = self
        addButton.action = #selector(newTabClicked)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.toolTip = "New tab (⌘T)"

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        addSubview(addButton)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -4),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            stack.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    private func rebuild() {
        // Remove from the stack's arranged list FIRST, then drop the views —
        // removeFromSuperview alone leaves stale arranged entries.
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0) }
        tabViews.forEach { $0.removeFromSuperview() }
        tabViews.removeAll()
        trackingIndex = nil

        for (index, tab) in tabs.enumerated() {
            let view = TabItemView(tab: tab)
            view.index = index
            view.isSelected = tab.id == selectedID
            view.onSelect = { [weak self] id in self?.onSelect?(id) }
            view.onClose = { [weak self] id in self?.onClose?(id) }
            view.onMiddleClick = { [weak self] id in self?.onMiddleClickClose?(id) }
            view.onRightClick = { [weak self, weak view] id, point in
                guard let self, let anchor = view,
                      let menu = self.contextMenuProvider?(id) else { return }
                menu.popUp(positioning: nil, at: point, in: anchor)
            }
            view.onDragOut = { [weak self] id, point in self?.onDragOut?(id, point) }
            stack.addArrangedSubview(view)
            tabViews.append(view)
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.tabMinWidth).isActive = true
        }
        updateSelection(animated: false)
        needsLayout = true
        // Frames are zero until the next layout pass; re-scroll once the
        // strip has actually laid out so the selected tab is always visible.
        DispatchQueue.main.async { [weak self] in
            self?.scrollSelectedIntoView()
        }
    }

    private func updateSelection(animated: Bool) {
        for view in tabViews {
            view.setSelected(view.tabID == selectedID, animated: animated)
        }
        scrollSelectedIntoView()
    }

    private func scrollSelectedIntoView() {
        guard let selectedID, let view = tabViews.first(where: { $0.tabID == selectedID }) else { return }
        scrollView.contentView.scrollToVisible(view.frame.insetBy(dx: -8, dy: 0))
    }

    @objc private func newTabClicked() {
        onNewTab?()
    }

    // MARK: - Middle click

    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let index = indexOfTab(at: point) {
            onMiddleClickClose?(tabs[index].id)
        }
    }

    private func indexOfTab(at point: NSPoint) -> Int? {
        tabViews.firstIndex { view in
            view.convert(view.bounds, to: self).contains(point)
        }
    }
}

/// A single tab: icon, title, close button on hover.
@MainActor
final class TabItemView: NSView {
    let tabID: UUID
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var selected = false
    private var closeVisible = false
    private var tearOffArmed = false

    var index = 0
    var isSelected: Bool {
        get { selected }
        set { setSelected(newValue, animated: false) }
    }

    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onMiddleClick: ((UUID) -> Void)?
    var onRightClick: ((UUID, NSPoint) -> Void)?
    var onDragOut: ((UUID, NSPoint) -> Void)?

    init(tab: TabStripView.Tab) {
        self.tabID = tab.id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        iconView.image = tab.icon
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = tab.title
        titleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.alphaValue = 0
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setSelected(_ value: Bool, animated: Bool) {
        guard selected != value else { return }
        selected = value
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                animator().updateAppearance()
            }
        } else {
            updateAppearance()
        }
    }

    private func updateAppearance() {
        if selected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.20).cgColor
            titleLabel.textColor = .labelColor
            titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        } else {
            layer?.backgroundColor = closeVisible
                ? NSColor.labelColor.withAlphaComponent(0.06).cgColor
                : NSColor.clear.cgColor
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        closeVisible = true
        closeButton.alphaValue = 1
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        closeVisible = false
        closeButton.alphaValue = selected ? 1 : 0
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        tearOffArmed = false
        onSelect?(tabID)
    }

    override func mouseUp(with event: NSEvent) {
        tearOffArmed = false
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(tabID, convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        // Tear-off: dragging vertically past the strip becomes a new window.
        // Fired once per drag — repeated drag ticks don't re-trigger.
        guard !tearOffArmed else { return }
        let windowPoint = event.locationInWindow
        let stripFrame = convert(bounds, to: nil)
        if windowPoint.y < stripFrame.minY - 24 || windowPoint.y > stripFrame.maxY + 24 {
            tearOffArmed = true
            onDragOut?(tabID, windowPoint)
        }
    }

    @objc private func closeClicked() {
        onClose?(tabID)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }

    override func accessibilityLabel() -> String? { titleLabel.stringValue }
}
