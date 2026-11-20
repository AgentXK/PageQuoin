import AppKit

@MainActor
enum SidebarAppearance {
    static let headerHeight: CGFloat = 28
    static let titleInset: CGFloat = 15
    static let listInset: CGFloat = 5

    static func heading(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.textColor = AppPalette.secondaryText
        return label
    }

    static func configure(_ outline: NSOutlineView, in scroll: NSScrollView) {
        outline.headerView = nil
        outline.style = .fullWidth
        outline.rowSizeStyle = .custom
        outline.rowHeight = 24
        outline.indentationPerLevel = 13
        outline.backgroundColor = .clear

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        outline.frame = scroll.contentView.bounds
        outline.autoresizingMask = .width
        scroll.documentView = outline
    }
}

final class PaletteSelectionRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    static func reusable(in table: NSTableView) -> NSTableRowView {
        let identifier = NSUserInterfaceItemIdentifier("PaletteSelectionRow")
        if let row = table.makeView(withIdentifier: identifier, owner: nil) as? PaletteSelectionRow {
            return row
        }
        let row = PaletteSelectionRow()
        row.identifier = identifier
        return row
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let fill = isEmphasized ? AppPalette.selection : AppPalette.inactiveSelection
        fill.setFill()
        let rect = bounds.insetBy(dx: 2, dy: 1)
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

class SidebarTextCell: NSTableCellView {
    override func layout() {
        super.layout()
        guard let label = textField else { return }
        let hint = label.intrinsicContentSize.width > label.bounds.width + 0.5 ? label.stringValue : nil
        if toolTip != hint { toolTip = hint }
    }
}
