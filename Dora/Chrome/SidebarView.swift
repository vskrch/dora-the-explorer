import AppKit
import AppCore
import FSCore

/// A favorites row: symbol + label, hover fill, active-row highlight.
@MainActor
private final class SidebarRowView: NSView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    var onActivate: (() -> Void)?
    var isActive = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(isActive ? "current folder" : "")
        }
    }
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(symbol: String, title: String) {
        super.init(frame: .zero)
        wantsLayer = true

        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 4, dy: 2)
        if isActive {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        } else if hovered {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 5, yRadius: 5).fill()
        }
    }
}

/// Real navigation pane: Finder-style favorites that steer the current tab,
/// with the active row synced to the visible folder.
@MainActor
final class SidebarView: NSView {
    var onNavigateTo: ((_ url: URL, _ inNewTab: Bool) -> Void)?

    private let stack = NSStackView()
    private var rows: [SidebarRowView] = []
    private var activePath: String?
    /// Fixed once at init — `update` hot path never rebuilds the entry list.
    private let entries: [Entry]

    struct Entry {
        let symbol: String
        let title: String
        let path: String

        static func standardEntries() -> [Entry] {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let desktop = home.appendingPathComponent("Desktop")
            let documents = home.appendingPathComponent("Documents")
            let downloads = home.appendingPathComponent("Downloads")
            let pictures = home.appendingPathComponent("Pictures")
            let movies = home.appendingPathComponent("Movies")
            let music = home.appendingPathComponent("Music")
            return [
                Entry(symbol: "house", title: "Home", path: home.path),
                Entry(symbol: "menubar.dock.rectangle", title: "Desktop", path: desktop.path),
                Entry(symbol: "doc", title: "Documents", path: documents.path),
                Entry(symbol: "arrow.down.circle", title: "Downloads", path: downloads.path),
                Entry(symbol: "photo", title: "Pictures", path: pictures.path),
                Entry(symbol: "film", title: "Movies", path: movies.path),
                Entry(symbol: "music.note", title: "Music", path: music.path),
                Entry(symbol: "app.badge", title: "Applications", path: "/Applications"),
            ]
        }
    }

    override init(frame frameRect: NSRect) {
        self.entries = Entry.standardEntries()
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        let clip = NSClipView()
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.contentView = clip

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 8, bottom: 12, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        clip.documentView = stack

        let favoritesLabel = NSTextField(labelWithString: "Favorites")
        favoritesLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        favoritesLabel.textColor = .tertiaryLabelColor
        favoritesLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(favoritesLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.widthAnchor),
        ])

        for entry in entries {
            let row = SidebarRowView(symbol: entry.symbol, title: entry.title)
            let url = URL(fileURLWithPath: entry.path)
            row.onActivate = { [weak self] in
                self?.onNavigateTo?(url, false)
            }
            rows.append(row)
            stack.addArrangedSubview(row)
            row.isHidden = !FileManager.default.fileExists(atPath: entry.path)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The baked layer color must follow light/dark transitions.
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        needsDisplay = true
    }

    /// Called on every applyTab: current-directory highlight.
    func update(directory: URL) {
        activePath = directory.standardizedFileURL.path
        for (index, row) in rows.enumerated() {
            row.isActive = entries[index].path == activePath
        }
    }
}
