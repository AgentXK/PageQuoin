import AppKit

/// Side-by-side panes with a quiet divider and a wide resize target.
@MainActor
final class WorkspaceSplitViewController: NSSplitViewController {
    init(isVertical: Bool = true) {
        super.init(nibName: nil, bundle: nil)
        let separator = WorkspaceSplitView()
        separator.isVertical = isVertical
        separator.dividerStyle = .thin
        splitView = separator
    }

    required init?(coder: NSCoder) { nil }

    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let nativeRect = super.splitView(splitView, effectiveRect: proposedEffectiveRect,
                                         forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        guard !nativeRect.isEmpty, !drawnRect.isEmpty else { return nativeRect }
        let thickness = splitView.isVertical ? drawnRect.width : drawnRect.height
        let expansion = max(0, (12 - thickness) / 2)
        let hitArea = splitView.isVertical ? drawnRect.insetBy(dx: -expansion, dy: 0)
            : drawnRect.insetBy(dx: 0, dy: -expansion)
        return nativeRect.union(hitArea).intersection(splitView.bounds)
    }
}

private final class WorkspaceSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 1 }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func drawDivider(in rect: NSRect) {
        AppPalette.rule.setFill()
        rect.fill()
    }
}
