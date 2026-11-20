import AppKit

@MainActor
final class FileTabStrip: NSView {
    struct Tab: Equatable {
        let id: ObjectIdentifier
        let name: String
        let path: String?
        let isEdited: Bool
        let kind: ProjectFileKind
    }

    static let height: CGFloat = 36

    var onSelect: ((ObjectIdentifier) -> Void)?
    var onClose: ((ObjectIdentifier) -> Void)?

    private let scroll = FileTabScrollView()
    private let stack = NSStackView()
    private let overflow = NSButton()
    private lazy var overflowWidth = overflow.widthAnchor.constraint(equalToConstant: 0)
    private var tabs: [Tab] = []
    private var rows: [FileTabView] = []
    private var selected: ObjectIdentifier?
    private var viewportWidth: CGFloat = 0

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Open Files")

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        overflow.title = ""
        overflow.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Open Files")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        overflow.imagePosition = .imageOnly
        overflow.bezelStyle = .accessoryBarAction
        overflow.showsBorderOnlyWhileMouseInside = true
        overflow.contentTintColor = AppPalette.secondaryText
        overflow.target = self
        overflow.action = #selector(showOverflow(_:))
        overflow.toolTip = "Show Open Files"
        overflow.setAccessibilityLabel("Show Open Files")
        overflow.isHidden = true
        overflow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overflow)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: overflow.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            overflow.trailingAnchor.constraint(equalTo: trailingAnchor),
            overflow.centerYAnchor.constraint(equalTo: centerYAnchor),
            overflow.heightAnchor.constraint(equalToConstant: 24),
            overflowWidth
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(_ tabs: [Tab], selected id: ObjectIdentifier?) {
        guard self.tabs != tabs || selected != id else { return }
        let availableTabsChanged = self.tabs.map(\.id) != tabs.map(\.id)
        let activeTabChanged = selected != id
        self.tabs = tabs
        selected = id

        if availableTabsChanged {
            for row in rows {
                stack.removeArrangedSubview(row)
                row.removeFromSuperview()
            }
            rows = tabs.map { tab in
                let row = FileTabView()
                row.onSelect = { [weak self] in self?.onSelect?(tab.id) }
                row.onClose = { [weak self] in self?.onClose?(tab.id) }
                stack.addArrangedSubview(row)
                return row
            }
        }
        for (row, tab) in zip(rows, tabs) {
            row.update(tab, isSelected: tab.id == id)
        }
        let spacing = stack.spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.reduce(stack.edgeInsets.left + stack.edgeInsets.right + spacing) { $0 + $1.tabWidth }
        stack.setFrameSize(NSSize(width: width, height: Self.height - 1))
        stack.layoutSubtreeIfNeeded()
        updateOverflow()
        let clip = scroll.contentView
        let maximum = max(0, width - clip.bounds.width)
        if clip.bounds.minX > maximum {
            clip.scroll(to: NSPoint(x: maximum, y: 0))
            scroll.reflectScrolledClipView(clip)
        }
        if activeTabChanged || availableTabsChanged { revealSelection() }
    }

    override func layout() {
        super.layout()
        updateOverflow()
        if viewportWidth != scroll.contentView.bounds.width {
            viewportWidth = scroll.contentView.bounds.width
            revealSelection()
        }
    }

    private func updateOverflow() {
        let hidden = bounds.width <= 0 || stack.bounds.width <= bounds.width
        guard overflow.isHidden != hidden else { return }
        overflow.isHidden = hidden
        overflowWidth.constant = hidden ? 0 : 32
    }

    @objc private func showOverflow(_ sender: NSButton) {
        let menu = NSMenu()
        for (index, tab) in tabs.enumerated() {
            let title = tab.isEdited ? tab.name + " •" : tab.name
            let item = NSMenuItem(title: title, action: #selector(selectOverflowTab(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = tab.id == selected ? .on : .off
            item.toolTip = tab.path
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }

    @objc private func selectOverflowTab(_ sender: NSMenuItem) {
        guard tabs.indices.contains(sender.tag) else { return }
        onSelect?(tabs[sender.tag].id)
    }

    private func revealSelection() {
        guard let index = tabs.firstIndex(where: { $0.id == selected }), rows.indices.contains(index) else { return }
        let clip = scroll.contentView
        let visible = clip.bounds
        guard visible.width > 0 else { return }
        let frame = rows[index].frame.insetBy(dx: -4, dy: 0)
        let target = min(max(visible.minX, frame.maxX - visible.width), frame.minX)
        let x = max(0, min(target, stack.bounds.width - visible.width))
        guard x != visible.minX else { return }
        clip.scroll(to: NSPoint(x: x, y: 0))
        scroll.reflectScrolledClipView(clip)
    }

    override func draw(_ dirtyRect: NSRect) {
        AppPalette.chrome.setFill()
        dirtyRect.intersection(bounds).fill()
        AppPalette.rule.setFill()
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class FileTabScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let wheelDelta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : 16 * wheelDelta
        guard delta != 0, let documentView, documentView.bounds.width > contentView.bounds.width else {
            super.scrollWheel(with: event)
            return
        }
        let maximum = documentView.bounds.width - contentView.bounds.width
        let x = min(maximum, max(0, contentView.bounds.minX - delta))
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }
}

@MainActor
private final class FileTabView: NSView {
    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let editedIcon = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 6, weight: .regular))

    private let titleButton = NSButton()
    private let closeButton = NSButton()
    private lazy var width = widthAnchor.constraint(equalToConstant: 78)
    private var tracking: NSTrackingArea?
    private var selected = false
    private var hovered = false
    private var tab: FileTabStrip.Tab?

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var tabWidth: CGFloat { width.constant }

    init() {
        super.init(frame: .zero)
        titleButton.isBordered = false
        titleButton.imagePosition = .imageLeading
        titleButton.alignment = .left
        titleButton.font = Self.titleFont
        titleButton.cell?.lineBreakMode = .byTruncatingMiddle
        titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleButton.target = self
        titleButton.action = #selector(selectTab(_:))

        closeButton.title = ""
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8.5, weight: .semibold))
        closeButton.imagePosition = .imageOnly
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.showsBorderOnlyWhileMouseInside = true
        closeButton.contentTintColor = AppPalette.mutedText
        closeButton.target = self
        closeButton.action = #selector(closeTab(_:))

        for control in [titleButton, closeButton] {
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
        }
        NSLayoutConstraint.activate([
            width,
            heightAnchor.constraint(equalToConstant: 27),
            titleButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleButton.topAnchor.constraint(equalTo: topAnchor),
            titleButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -3),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 21)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(_ tab: FileTabStrip.Tab, isSelected: Bool) {
        guard self.tab != tab || selected != isSelected else { return }
        self.tab = tab
        selected = isSelected
        titleButton.title = tab.name
        let fileIcon = NSImage(systemSymbolName: tab.kind.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        titleButton.image = tab.isEdited ? Self.editedIcon : fileIcon
        titleButton.contentTintColor = isSelected || tab.isEdited ? AppPalette.accent : AppPalette.secondaryText
        titleButton.toolTip = tab.path ?? tab.name
        let details = [tab.name, isSelected ? "Current tab" : nil, tab.isEdited ? "Unsaved changes" : nil].compactMap { $0 }
        titleButton.setAccessibilityLabel(details.joined(separator: ", "))
        closeButton.setAccessibilityLabel("Close \(tab.name)")
        closeButton.toolTip = closeButton.accessibilityLabel()
        let labelWidth = (tab.name as NSString).size(withAttributes: [.font: Self.titleFont]).width
        width.constant = min(158, max(78, ceil(labelWidth) + 51))
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
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

    override func draw(_ dirtyRect: NSRect) {
        guard selected || hovered else { return }
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (selected ? AppPalette.accentSurface : AppPalette.hover).setFill()
        pill.fill()
        if selected {
            AppPalette.rule.setStroke()
            pill.lineWidth = 1
            pill.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @objc private func selectTab(_ sender: Any?) { onSelect?() }
    @objc private func closeTab(_ sender: Any?) { onClose?() }
}
