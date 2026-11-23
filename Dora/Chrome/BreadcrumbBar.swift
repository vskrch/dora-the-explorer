import AppKit
import FSCore

/// A single breadcrumb segment (one ancestor folder). Consumes its own mouse
/// events so the bar's background gesture never fights the segments.
@MainActor
final class BreadcrumbSegmentView: NSView {
    let folderURL: URL
    private let titleLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    var onActivate: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?

    init(url: URL, title: String, emphasizesText: Bool) {
        self.folderURL = url
        super.init(frame: .zero)
        wantsLayer = true

        titleLabel.font = emphasizesText
            ? .systemFont(ofSize: 12, weight: .semibold)
            : .systemFont(ofSize: 12)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.cell?.wraps = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        self.title = title
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var title: String {
        get { titleLabel.stringValue }
        set {
            titleLabel.stringValue = newValue
            toolTip = folderURL.path
            setAccessibilityLabel(newValue)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }

    override var acceptsFirstResponder: Bool { false }
}

/// Chevron between segments; opening loads that level's subfolders.
@MainActor
final class BreadcrumbChevronView: NSView {
    private let icon = NSImageView()
    var onOpenMenu: (() -> Void)?

    init() {
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Subfolders")
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            icon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel("Show subfolders")

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onOpenMenu?()
    }

    override var acceptsFirstResponder: Bool { false }
}

/// The breadcrumb trail: ancestor segments with chevron subfolder menus,
/// leading-segment overflow, segment context menus, and click-to-edit on the
/// empty area. All child-folder lookups run off the main thread.
@MainActor
final class BreadcrumbBar: NSView {
    struct FolderChild: Sendable {
        let url: URL
        let name: String
    }

    var onNavigate: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var onOpenInNewWindow: ((URL) -> Void)?
    var onEditAddress: (() -> Void)?
    /// Serves chevron dropdowns: child folders of a path, warmed off-main.
    var childFolderProvider: ((_ url: URL, _ completion: @escaping @Sendable ([FolderChild]) -> Void) -> Void)?

    private let stack = NSStackView()
    private let overflowButton = NSButton()
    private var segments: [BreadcrumbSegmentView] = []
    private var pairs: [(URL, String)] = []
    private var hiddenOverflow: [(URL, String)] = []
    /// Outstanding chevron-menu load. Enumeration completes asynchronously —
    /// a stale completion (user clicked away, navigated, or waited out the
    /// click) must never pop a menu uninvited.
    private var childMenuRequestID = 0

    private(set) var path: String = "/"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.required, for: .horizontal)
        addSubview(stack)

        overflowButton.title = "«"
        overflowButton.font = .systemFont(ofSize: 12)
        overflowButton.isBordered = false
        overflowButton.bezelStyle = .inline
        overflowButton.toolTip = "Hidden folders"
        overflowButton.translatesAutoresizingMaskIntoConstraints = false
        overflowButton.isHidden = true
        overflowButton.target = self
        overflowButton.action = #selector(overflowClicked)
        addSubview(overflowButton)

        NSLayoutConstraint.activate([
            overflowButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            overflowButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Rebuild the trail from a path, caching the att. volume name once.
    func update(path: String) {
        self.path = path
        childMenuRequestID += 1 // navigation invalidates outstanding chevron loads
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        segments.removeAll()
        hiddenOverflow.removeAll()

        let url = URL(fileURLWithPath: path)
        var currentURL = URL(fileURLWithPath: "/")
        var rebuilt: [(URL, String)] = [(currentURL, BreadcrumbVolumeName.cached ?? "Macintosh HD")]
        for component in url.pathComponents where component != "/" {
            currentURL = currentURL.appendingPathComponent(component)
            rebuilt.append((currentURL, component))
        }
        pairs = rebuilt

        for (index, pair) in pairs.enumerated() {
            let isLast = index == pairs.count - 1
            let segment = BreadcrumbSegmentView(url: pair.0, title: pair.1, emphasizesText: isLast)
            segment.onActivate = { [weak self, weak segment] in
                guard let self, let segment else { return }
                self.onNavigate?(segment.folderURL)
            }
            segment.onRightClick = { [weak self, weak segment] event in
                guard let self, let segment else { return }
                self.presentContextMenu(for: segment, event: event)
            }
            stack.addArrangedSubview(segment)
            segments.append(segment)

            if !isLast {
                let chevron = BreadcrumbChevronView()
                let targetURL = pair.0
                chevron.onOpenMenu = { [weak self, weak chevron] in
                    guard let self, let chevron else { return }
                    self.presentChildMenu(for: targetURL, from: chevron)
                }
                stack.addArrangedSubview(chevron)
            }
        }

        layoutOverflow()
        needsLayout = true
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        layoutOverflow()
    }

    /// Windows-style leading collapse: hide earliest segments behind "«".
    /// Deterministic from scratch on every pass, so resizing wider restores.
    private func layoutOverflow() {
        let arranged = stack.arrangedSubviews
        for view in arranged { view.isHidden = false }

        let available = max(bounds.width - 24, 48)
        var hiddenCount = 0
        // Arranged order is [segment, chevron, segment, chevron, …, segment].
        while stack.fittingSize.width > available, pairs.count - hiddenCount > 2 {
            let segmentSlot = hiddenCount * 2
            if arranged.indices.contains(segmentSlot) {
                arranged[segmentSlot].isHidden = true
            }
            if arranged.indices.contains(segmentSlot + 1) {
                arranged[segmentSlot + 1].isHidden = true
            }
            hiddenCount += 1
        }

        hiddenOverflow = Array(pairs.prefix(hiddenCount))
        overflowButton.isHidden = hiddenOverflow.isEmpty
    }

    // MARK: - Menus

    private func presentChildMenu(for folder: URL, from view: NSView) {
        guard let childFolderProvider else { return }
        childMenuRequestID += 1
        let requestID = childMenuRequestID
        let requestedAt = Date()
        // Enumeration is usually <50 ms; the menu opens once warm so items
        // never flash "Loading…". A completion that arrives after the user
        // moved on is dropped on the floor instead of popping uninvited.
        childFolderProvider(folder) { [weak self, weak view] children in
            Task { @MainActor [weak self, weak view] in
                guard let self, let anchor = view,
                      self.childMenuRequestID == requestID, // still the live request
                      anchor.window != nil, // chevron still on screen
                      Date().timeIntervalSince(requestedAt) < 1.0 // click was recent
                else { return }
                let menu = NSMenu()
                if children.isEmpty {
                    let empty = NSMenuItem(title: "No subfolders", action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    menu.addItem(empty)
                } else {
                    for child in children.prefix(400) {
                        let item = NSMenuItem(
                            title: child.name,
                            action: #selector(menuNavigateToChild(_:)),
                            keyEquivalent: ""
                        )
                        item.target = self
                        item.representedObject = child.url.path
                        menu.addItem(item)
                    }
                    if children.count > 400 {
                        let more = NSMenuItem(title: "\(children.count - 400) more…", action: nil, keyEquivalent: "")
                        more.isEnabled = false
                        menu.addItem(more)
                    }
                }
                menu.popUp(positioning: nil, at: NSPoint(x: 2, y: anchor.bounds.maxY), in: anchor)
            }
        }
    }

    @objc private func menuNavigateToChild(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onNavigate?(URL(fileURLWithPath: path))
    }

    @objc private func overflowClicked() {
        guard !hiddenOverflow.isEmpty else { return }
        let menu = NSMenu()
        for (url, title) in hiddenOverflow.reversed() {
            let item = NSMenuItem(title: title, action: #selector(menuNavigateToChild(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url.path
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: overflowButton)
    }

    private func presentContextMenu(for segment: BreadcrumbSegmentView, event: NSEvent) {
        let url = segment.folderURL
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: "Copy Address", action: #selector(menuCopyPath(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.representedObject = url.path
        menu.addItem(copyItem)

        let copyNameItem = NSMenuItem(title: "Copy as Text", action: #selector(menuCopyName(_:)), keyEquivalent: "")
        copyNameItem.target = self
        copyNameItem.representedObject = url.lastPathComponent
        menu.addItem(copyNameItem)

        menu.addItem(.separator())
        let newTabItem = NSMenuItem(title: "Open in New Tab", action: #selector(menuOpenInNewTab(_:)), keyEquivalent: "")
        newTabItem.target = self
        newTabItem.representedObject = url.path
        menu.addItem(newTabItem)

        let newWindowItem = NSMenuItem(title: "Open in New Window", action: #selector(menuOpenInNewWindow(_:)), keyEquivalent: "")
        newWindowItem.target = self
        newWindowItem.representedObject = url.path
        menu.addItem(newWindowItem)

        menu.addItem(.separator())
        let editItem = NSMenuItem(title: "Edit Address", action: #selector(menuEditAddress), keyEquivalent: "")
        editItem.target = self
        menu.addItem(editItem)

        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: segment)
    }

    @objc private func menuCopyPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc private func menuCopyName(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
    }

    @objc private func menuOpenInNewTab(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onOpenInNewTab?(URL(fileURLWithPath: path))
    }

    @objc private func menuOpenInNewWindow(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onOpenInNewWindow?(URL(fileURLWithPath: path))
    }

    @objc private func menuEditAddress() {
        onEditAddress?()
    }

    // MARK: - Background interactions

    override func mouseDown(with event: NSEvent) {
        // Only clicks that fell through to the bar background reach here —
        // segments and chevrons consume their own events.
        onEditAddress?()
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let editItem = NSMenuItem(title: "Edit Address", action: #selector(menuEditAddress), keyEquivalent: "")
        editItem.target = self
        menu.addItem(editItem)
        let copyItem = NSMenuItem(title: "Copy Address as Text", action: #selector(menuCopyPath(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.representedObject = path
        menu.addItem(copyItem)
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }
}

/// Root volume name, warmed once off-main (no disk I/O in update paths).
@MainActor
enum BreadcrumbVolumeName {
    static var cached: String?

    static func warmCache() {
        guard cached == nil else { return }
        Task.detached(priority: .utility) {
            let name = (try? URL(fileURLWithPath: "/")
                .resourceValues(forKeys: [.volumeNameKey])
                .volumeName) ?? "Macintosh HD"
            let value = name
            await MainActor.run {
                cached = value
            }
        }
    }
}
