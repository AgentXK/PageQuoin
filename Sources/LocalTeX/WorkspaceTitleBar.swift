import AppKit

@MainActor
final class WorkspaceTitleBar: NSView {
    static let height: CGFloat = 32
    private static let windowedInset: CGFloat = 79
    private static let fullScreenInset: CGFloat = 8

    private let left: NSStackView
    private lazy var leftLeading = left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.windowedInset)

    init(sidebar: NSButton, project: NSButton, search: NSButton, layout: NSButton, log: NSButton) {
        left = NSStackView(views: [sidebar, project])
        super.init(frame: .zero)
        setAccessibilityIdentifier("WorkspaceTitleBar")

        let right = NSStackView(views: [search, layout, log])
        left.spacing = 4
        right.spacing = 8
        for stack in [left, right] {
            stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
        }
        NSLayoutConstraint.activate([
            leftLeading,
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 16),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            center.removeObserver(self, name: name, object: nil)
            if let window {
                center.addObserver(self, selector: #selector(fullScreenDidChange(_:)), name: name, object: window)
            }
        }
        updateLeadingInset()
    }

    @objc private func fullScreenDidChange(_ notification: Notification) {
        updateLeadingInset()
    }

    private func updateLeadingInset() {
        let isFullScreen = window?.styleMask.contains(.fullScreen) == true
        leftLeading.constant = isFullScreen ? Self.fullScreenInset : Self.windowedInset
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window, window.isMovable, !window.styleMask.contains(.fullScreen) else {
            super.mouseDown(with: event)
            return
        }
        switch event.clickCount {
        case 1:
            window.performDrag(with: event)
        case 2 where window.styleMask.contains(.resizable):
            window.zoom(self)
        default:
            super.mouseDown(with: event)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        AppPalette.titleBar.setFill()
        dirtyRect.fill()
        AppPalette.titleBarRule.setFill()
        let rule = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1)
        rule.intersection(dirtyRect).fill()
    }
}

@MainActor
final class WorkspaceToolbarButton: NSButton {
    private static let horizontalInset: CGFloat = 11
    private static let symbolGap: CGFloat = 9
    private static let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        return style
    }()

    private let symbol: NSImage?
    private let textFont: NSFont
    private let showsChevron: Bool
    private let restingBackground: Bool
    private var hoverTracking: NSTrackingArea?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    init(title: String = "", symbol: String, showsChevron: Bool = false, restingBackground: Bool = false,
         target: AnyObject, action: Selector) {
        self.symbol = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        self.showsChevron = showsChevron
        self.restingBackground = restingBackground
        textFont = .systemFont(ofSize: showsChevron ? 13 : 12, weight: showsChevron ? .semibold : .medium)
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { nil }

    override var title: String {
        didSet {
            guard oldValue != title else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        guard !title.isEmpty else { return NSSize(width: 28, height: 25) }
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: textFont]).width)
        let leadingWidth = (symbol?.size.width ?? 0) + Self.symbolGap
        let trailingWidth = showsChevron ? (Self.chevron?.size.width ?? 0) + Self.symbolGap : 0
        return NSSize(width: min(titleWidth + leadingWidth + trailingWidth + 2 * Self.horizontalInset + 2, 250), height: 25)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override var mouseDownCanMoveWindow: Bool { false }

    private var buttonShape: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { buttonShape.fill() }

    override func draw(_ dirtyRect: NSRect) {
        let active = isEnabled && (isHighlighted || isHovered)
        if restingBackground || active {
            let fill = active ? (isHighlighted ? AppPalette.inactiveSelection : AppPalette.hover) : AppPalette.control
            fill.setFill()
            buttonShape.fill()
        }

        let symbolColor = isEnabled ? AppPalette.secondaryText : AppPalette.disabledText
        let symbolWidth = symbol?.size.width ?? 0
        let symbolX = title.isEmpty ? bounds.midX - symbolWidth / 2 : bounds.minX + Self.horizontalInset
        draw(symbol, at: symbolX, tint: symbolColor)
        guard !title.isEmpty else { return }

        let titleX = symbolX + symbolWidth + Self.symbolGap
        var titleEnd = bounds.maxX - Self.horizontalInset
        if showsChevron {
            let chevronX = titleEnd - (Self.chevron?.size.width ?? 0)
            draw(Self.chevron, at: chevronX, tint: symbolColor)
            titleEnd = chevronX - Self.symbolGap
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: textFont, .paragraphStyle: Self.paragraph,
            .foregroundColor: isEnabled ? AppPalette.text : AppPalette.disabledText
        ]
        let text = title as NSString
        let height = ceil(text.size(withAttributes: attributes).height)
        let rect = NSRect(x: titleX, y: floor(bounds.midY - height / 2), width: max(0, titleEnd - titleX), height: height)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    private func draw(_ symbol: NSImage?, at x: CGFloat, tint: NSColor) {
        guard let symbol,
              let image = symbol.withSymbolConfiguration(symbol.symbolConfiguration.applying(.init(hierarchicalColor: tint)))
        else { return }
        let rect = NSRect(x: x, y: floor(bounds.midY - image.size.height / 2),
                          width: image.size.width, height: image.size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
