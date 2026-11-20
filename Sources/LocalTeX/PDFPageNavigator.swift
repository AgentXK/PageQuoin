import AppKit
import PDFKit

@MainActor
final class PDFPageNavigator: NSView, NSTextFieldDelegate {
    private static let controlHeight: CGFloat = 24
    private static let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let fieldFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private weak var pdfView: PDFView?
    private weak var editingDocument: PDFDocument?
    private let first = NSButton()
    private let previous = NSButton()
    private let next = NSButton()
    private let last = NSButton()
    private let pageLabel = NSTextField(labelWithString: "Page")
    private let pageField = NSTextField()
    private let totalLabel = NSTextField(labelWithString: "")
    private var pageCount = 0
    private var currentPage = 1

    init(pdfView: PDFView) {
        self.pdfView = pdfView
        super.init(frame: .zero)
        setAccessibilityIdentifier("PDFPageNavigator")
        configure(first, symbol: "chevron.left.2", label: "First Page", action: #selector(goFirst(_:)))
        configure(previous, symbol: "chevron.left", label: "Previous Page", action: #selector(goPrevious(_:)))
        configure(next, symbol: "chevron.right", label: "Next Page", action: #selector(goNext(_:)))
        configure(last, symbol: "chevron.right.2", label: "Last Page", action: #selector(goLast(_:)))
        for label in [pageLabel, totalLabel] {
            label.font = Self.labelFont
            label.textColor = AppPalette.secondaryText
            label.lineBreakMode = .byTruncatingTail
        }
        totalLabel.alignment = .left
        pageField.font = Self.fieldFont
        pageField.textColor = AppPalette.text
        pageField.controlSize = .small
        pageField.bezelStyle = .roundedBezel
        pageField.alignment = .center
        pageField.usesSingleLineMode = true
        pageField.delegate = self
        pageField.toolTip = "Enter a page number"
        pageField.setAccessibilityLabel("Page Number")
        pageField.setAccessibilityIdentifier("PDFPageNumber")
        for child in [first, previous, next, last, pageLabel, pageField, totalLabel] {
            addSubview(child)
        }
        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewDocumentChanged, .PDFViewPageChanged] {
            center.addObserver(self, selector: #selector(updatePage), name: name, object: pdfView)
        }
        updatePage()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: Self.controlHeight)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { updatePage() }
    }

    private var pageFieldWidth: CGFloat {
        let digits = (String(pageCount) as NSString).size(withAttributes: [.font: Self.fieldFont]).width
        // Leave room for both the native bezel and the field editor's text padding and caret.
        return max(28, ceil(digits) + 18)
    }

    private func labelWidth(_ label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: Self.labelFont]).width) + 6
    }

    private var preferredWidth: CGFloat {
        4 * 22 + labelWidth(pageLabel.stringValue) + pageFieldWidth + labelWidth("of \(pageCount)") + 20
    }

    override func layout() {
        super.layout()
        let showsWords = bounds.width >= preferredWidth
        let buttonWidth: CGFloat = showsWords ? 22 : 16
        let gap: CGFloat = showsWords ? 5 : 2
        let prefixWidth = showsWords ? labelWidth(pageLabel.stringValue) : 0
        let suffix = showsWords ? "of \(pageCount)" : "/ \(pageCount)"
        let suffixWidth = labelWidth(suffix)
        let fieldWidth = pageFieldWidth
        let numberWidth = prefixWidth + fieldWidth + suffixWidth + (showsWords ? 2 : 1) * gap
        let stepWidth = min(buttonWidth, floor((bounds.width - numberWidth) / 2) - gap)
        let widthWithStepButtons = numberWidth + 2 * (stepWidth + gap)
        let widthWithBoundsButtons = numberWidth + 4 * buttonWidth + 2 * gap
        let showsStepButtons = stepWidth >= 12
        let showsBoundsButtons = bounds.width >= widthWithBoundsButtons
        let contentWidth = showsBoundsButtons ? widthWithBoundsButtons : (showsStepButtons ? widthWithStepButtons : numberWidth)
        var x = floor(bounds.midX - contentWidth / 2)
        func place(_ item: NSView, width: CGFloat, height: CGFloat = 22) {
            item.frame = NSRect(x: x, y: floor(bounds.midY - height / 2), width: width, height: height)
            x += width
        }
        first.isHidden = !showsBoundsButtons
        last.isHidden = !showsBoundsButtons
        previous.isHidden = !showsStepButtons
        next.isHidden = !showsStepButtons
        pageLabel.isHidden = !showsWords
        totalLabel.stringValue = suffix
        if showsBoundsButtons { place(first, width: buttonWidth) }
        if showsStepButtons {
            place(previous, width: stepWidth)
            x += gap
        }
        if showsWords {
            place(pageLabel, width: prefixWidth, height: 16)
            x += gap
        }
        place(pageField, width: fieldWidth)
        x += gap
        place(totalLabel, width: suffixWidth, height: 16)
        if showsStepButtons {
            x += gap
            place(next, width: stepWidth)
        }
        if showsBoundsButtons { place(last, width: buttonWidth) }
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.controlSize = .small
        button.contentTintColor = AppPalette.secondaryText
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    @objc private func updatePage() {
        let document = pdfView?.document
        let count = document?.pageCount ?? 0
        if pageCount != count {
            pageCount = count
            isHidden = pageCount == 0
            invalidateIntrinsicContentSize()
            needsLayout = true
            superview?.needsLayout = true
        } else {
            isHidden = pageCount == 0
        }
        let index = pdfView?.currentPage.flatMap { document?.index(for: $0) } ?? 0
        currentPage = index >= 0 && index < pageCount ? index + 1 : 1
        if pageField.currentEditor() == nil {
            pageField.stringValue = String(currentPage)
        }
        first.isEnabled = currentPage > 1
        previous.isEnabled = first.isEnabled
        last.isEnabled = currentPage < pageCount
        next.isEnabled = last.isEnabled
    }

    @objc private func goFirst(_ sender: Any?) { go(to: 1) }
    @objc private func goPrevious(_ sender: Any?) { go(to: currentPage - 1) }
    @objc private func goNext(_ sender: Any?) { go(to: currentPage + 1) }
    @objc private func goLast(_ sender: Any?) { go(to: pageCount) }

    private func go(to number: Int) {
        guard let pdfView, let document = pdfView.document, document.pageCount > 0,
              let page = document.page(at: min(max(1, number), document.pageCount) - 1) else { return }
        pdfView.go(to: page)
        updatePage()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        editingDocument = pdfView?.document
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let document = editingDocument
        editingDocument = nil
        if let document, document === pdfView?.document,
           let number = Int(pageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            go(to: number)
        }
        pageField.stringValue = String(currentPage)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:))
                || selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        let document = editingDocument
        editingDocument = nil
        let entered = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        window?.makeFirstResponder(nil)
        if selector == #selector(NSResponder.insertNewline(_:)), let document,
           document === pdfView?.document, let number = Int(entered) {
            go(to: number)
        }
        pageField.stringValue = String(currentPage)
        return true
    }
}
