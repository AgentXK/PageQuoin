import AppKit

@MainActor
final class SourceEditorController: NSViewController, NSTextViewDelegate {
    private let textView = LaTeXTextView(usingTextLayoutManager: false)
    private var lineStarts = SourceLineStarts("")
    private var lineNumbers: LineNumberRuler?
    private var highlightTask: Task<Void, Never>?
    private var isSettingSource = false
    private var typographyPending = false

    var onChange: ((String) -> Void)?
    var hasMarkedText: Bool { textView.hasMarkedText() }
    var caretLine: Int {
        let offset = textView.selectedRange().location
        return offset == NSNotFound ? 1 : lineStarts.index(containing: offset) + 1
    }

    var usesLaTeXSyntax: Bool {
        get { textView.usesLaTeXSyntax }
        set { textView.usesLaTeXSyntax = newValue }
    }

    var source: String {
        get { textView.string }
        set {
            guard newValue != textView.string else { return }
            _ = view
            isSettingSource = true
            textView.resetTypingAssistance()
            textView.string = newValue
            applyTypography()
            isSettingSource = false
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            updateLineNumbers()
            scheduleHighlighting()
        }
    }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = AppPalette.editor

        textView.frame = scrollView.contentView.bounds
        textView.autoresizingMask = .width
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 5, height: 18)
        textView.textContainer?.lineFragmentPadding = 3
        textView.isRichText = false
        textView.backgroundColor = AppPalette.editor
        textView.textColor = AppPalette.text
        textView.insertionPointColor = AppPalette.accent
        textView.selectedTextAttributes[.backgroundColor] = AppPalette.selection
        textView.selectedTextAttributes[.foregroundColor] = AppPalette.selectionText
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.smartInsertDeleteEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        if #available(macOS 14.0, *) {
            textView.inlinePredictionType = .no
        }
        textView.setAccessibilityLabel("Source editor")
        textView.delegate = self
        textView.onUnmark = { [weak self] in
            guard let self, typographyPending else { return }
            applyTypography()
        }
        applyTypography()

        scrollView.documentView = textView
        let ruler = LineNumberRuler(scrollView: scrollView, textView: textView)
        lineNumbers = ruler
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewBoundsChanged(_:)), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(self, selector: #selector(typographyDidChange(_:)),
                                               name: EditorTypography.didChange, object: nil)
        view = scrollView
    }

    func focusEditor() {
        view.window?.makeFirstResponder(textView)
    }

    func endTypingGroup() {
        textView.breakUndoCoalescing()
    }

    func reveal(_ range: NSRange) {
        guard NSMaxRange(range) <= textView.string.utf16.count else { return }
        focusEditor()
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    func goToLine(_ line: Int) {
        let index = min(max(line, 1), lineStarts.offsets.count) - 1
        reveal(NSRange(location: lineStarts.offsets[index], length: 0))
    }

    func completeCommand() {
        guard !textView.hasMarkedText() else { return }
        focusEditor()
        textView.complete(nil)
    }

    func toggleComment() {
        guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
        let source = textView.string as NSString
        let selections = textView.selectedRanges.map(\.rangeValue)
        var selectedLines = IndexSet()
        for range in selections {
            let first = lineStarts.index(containing: range.location)
            let last = lineStarts.index(containing: max(range.location, NSMaxRange(range) - 1))
            selectedLines.insert(integersIn: first...last)
        }

        let includeEmptyLines = selectedLines.count == 1
        let prefixes = selectedLines.compactMap { line -> (offset: Int, end: Int, commented: Bool)? in
            let start = lineStarts.offsets[line]
            var end = start
            if start < source.length {
                source.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: start, length: 0))
            }
            var offset = start
            while offset < end, source.character(at: offset) == 0x20 || source.character(at: offset) == 0x09 {
                offset += 1
            }
            if offset == end && !includeEmptyLines { return nil }
            return (offset, end, offset < end && source.character(at: offset) == 0x25)
        }
        let uncomment = prefixes.allSatisfy(\.commented)
        let edits = prefixes.map { prefix in
            let removeSpace = uncomment && prefix.offset + 1 < prefix.end
                && source.character(at: prefix.offset + 1) == 0x20
            return CommentEdit(
                range: NSRange(location: prefix.offset, length: uncomment ? (removeSpace ? 2 : 1) : 0),
                replacement: uncomment ? "" : "% "
            )
        }
        guard let first = edits.first, let last = edits.last else { return }
        let changedRange = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        let replacement = NSMutableString(string: source.substring(with: changedRange))
        for edit in edits.reversed() {
            let localRange = NSRange(location: edit.range.location - changedRange.location, length: edit.range.length)
            replacement.replaceCharacters(in: localRange, with: edit.replacement)
        }
        let updatedSelections = selections.map { selection in
            let start = movedOffset(selection.location, through: edits)
            let end = movedOffset(NSMaxRange(selection), through: edits)
            return NSValue(range: NSRange(location: start, length: end - start))
        }

        focusEditor()
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: changedRange, replacementString: replacement as String) else { return }
        storage.replaceCharacters(in: changedRange, with: replacement as String)
        textView.setSelectedRanges(updatedSelections, affinity: .downstream, stillSelecting: false)
        textView.didChangeText()
        textView.breakUndoCoalescing()
        textView.undoManager?.setActionName("Toggle Comment")
    }

    private func movedOffset(_ offset: Int, through edits: [CommentEdit]) -> Int {
        var delta = 0
        for edit in edits {
            if offset < edit.range.location { break }
            if offset < NSMaxRange(edit.range) { return edit.range.location + delta }
            delta += edit.replacement.utf16.count - edit.range.length
        }
        return offset + delta
    }

    func textDidChange(_ notification: Notification) {
        guard !isSettingSource else { return }
        if typographyPending || textView.undoManager?.isUndoing == true || textView.undoManager?.isRedoing == true {
            applyTypography()
        }
        updateLineNumbers()
        onChange?(textView.string)
        scheduleHighlighting()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        textView.dismissCompletionIfCaretMoved()
        if textView.redrawCurrentLine() {
            lineNumbers?.needsDisplay = true
        }
    }

    @objc private func clipViewBoundsChanged(_ notification: Notification) {
        textView.dismissCompletion()
        lineNumbers?.needsDisplay = true
    }

    @objc private func typographyDidChange(_ notification: Notification) {
        applyTypography()
    }

    private func applyTypography() {
        guard !textView.hasMarkedText() else {
            typographyPending = true
            return
        }
        typographyPending = false
        let typography = EditorTypography.current
        let font = typography.font
        let style = NSMutableParagraphStyle()
        let fontHeight = textView.layoutManager?.defaultLineHeight(for: font) ?? font.pointSize
        style.lineSpacing = (fontHeight * CGFloat(typography.lineHeight - 100) / 100).rounded()
        textView.defaultParagraphStyle = style
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style]
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        textView.typingAttributes.merge(attributes) { _, updated in updated }
        lineNumbers?.needsDisplay = true
        textView.redrawCurrentLine()
    }

    private func updateLineNumbers() {
        lineStarts = SourceLineStarts(textView.string)
        lineNumbers?.update(lineStarts)
        textView.lineStarts = lineStarts
    }

    private func scheduleHighlighting() {
        guard usesLaTeXSyntax else { return }
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(65))
            guard !Task.isCancelled else { return }
            self?.highlightSource()
        }
    }

    private func highlightSource() {
        guard !textView.hasMarkedText(), let layoutManager = textView.layoutManager else { return }
        let contents = textView.string
        let fullRange = NSRange(location: 0, length: contents.utf16.count)
        guard fullRange.length > 0 else { return }

        // Temporary colors leave the source, undo history and clipboard text intact.
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        Self.tokens.enumerateMatches(in: contents, range: fullRange) { match, _, _ in
            guard let match else { return }
            let group = (1..<match.numberOfRanges).first { match.range(at: $0).location != NSNotFound }
            let color: NSColor
            switch group {
            case 1: color = AppPalette.syntaxComment
            case 2: color = AppPalette.syntaxMath
            case 3: color = AppPalette.syntaxCommand
            default: color = AppPalette.syntaxArgument
            }
            layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: match.range)
        }
    }

    // Escaped symbols are consumed as commands before they can start comments or math.
    private static let tokens = try! NSRegularExpression(
        pattern: #"(%[^\r\n]*)|(\${1,2}|\\[\[\]()])|(\\(?:[A-Za-z@]+\*?|[^\r\n]))|([{}])"#
    )
}

private struct CommentEdit {
    let range: NSRange
    let replacement: String
}

private struct SourceLineStarts {
    let offsets: [Int]

    init(_ text: String) {
        let source = text as NSString
        let length = source.length
        var offsets = [0]
        var start = 0
        while start < length {
            var end = 0
            var contentsEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            if contentsEnd < end { offsets.append(end) }
            start = end
        }
        self.offsets = offsets
    }

    func index(containing offset: Int) -> Int {
        var low = 0
        var high = offsets.count
        while low < high {
            let middle = low + (high - low) / 2
            if offsets[middle] <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return max(0, low - 1)
    }
}

private final class LaTeXTextView: NSTextView {
    var usesLaTeXSyntax = true {
        didSet { if !usesLaTeXSyntax { resetTypingAssistance() } }
    }
    private var highlightedRow = NSRect.zero
    private var completionPopup: LaTeXCompletionPopup?
    private var completionRange: NSRange?
    private var automaticClosers: [Int: String] = [:]
    private var isTypingKey = false
    private static let closingDelimiters = ["{": "}", "[": "]", "(": ")"]
    var onUnmark: (() -> Void)?
    var lineStarts = SourceLineStarts("") {
        didSet { redrawCurrentLine() }
    }

    @discardableResult
    func redrawCurrentLine() -> Bool {
        let row = currentVisualRow
        guard highlightedRow != row else { return false }
        for rect in [highlightedRow, row] {
            let visibleRow = rect.intersection(visibleRect)
            if !visibleRow.isEmpty { setNeedsDisplay(visibleRow, avoidAdditionalLayout: true) }
        }
        highlightedRow = row
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        highlightedRow = currentVisualRow
        let dirtyRow = highlightedRow.intersection(rect)
        guard !dirtyRow.isEmpty else { return }
        AppPalette.currentLine.setFill()
        dirtyRow.fill()
    }

    var currentVisualRow: NSRect {
        guard !bounds.isEmpty, let layout = layoutManager, let container = textContainer,
              let length = textStorage?.length else { return .zero }

        let selection = selectedRange()
        let position = min(selection.location, length)
        if position == length {
            if length == 0 {
                layout.ensureLayout(for: container)
            } else {
                layout.ensureLayout(forCharacterRange: NSRange(location: length - 1, length: 1))
            }
            if layout.extraLineFragmentTextContainer === container {
                return fullWidthRow(layout.extraLineFragmentRect)
            }
        }

        guard length > 0 else { return .zero }
        // At a soft wrap the same offset can be displayed on either adjacent fragment.
        let start = lineStarts.offsets[lineStarts.index(containing: position)]
        let usesPreviousGlyph = selection.length == 0 && selectionAffinity == .upstream && position > start
        let character = usesPreviousGlyph ? position - 1 : min(position, length - 1)
        let glyph = layout.glyphIndexForCharacter(at: character)
        return fullWidthRow(layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil))
    }

    private func fullWidthRow(_ fragment: NSRect) -> NSRect {
        NSRect(x: bounds.minX, y: textContainerOrigin.y + fragment.minY, width: bounds.width,
               height: fragment.height).intersection(bounds)
    }

    override func unmarkText() {
        super.unmarkText()
        onUnmark?()
    }

    override func keyDown(with event: NSEvent) {
        let shortcuts = event.modifierFlags.intersection([.command, .option, .control])
        if shortcuts.isEmpty, !event.modifierFlags.contains(.shift), !hasMarkedText(),
           let popup = completionPopup, popup.isVisible {
            switch event.keyCode {
            case 125: popup.move(by: 1)
            case 126: popup.move(by: -1)
            case 36, 48, 76: popup.accept()
            case 53: dismissCompletion()
            default: break
            }
            if [125, 126, 36, 48, 76, 53].contains(event.keyCode) { return }
        }
        isTypingKey = shortcuts.isEmpty
        defer { isTypingKey = false }
        super.keyDown(with: event)
    }

    override func complete(_ sender: Any?) {
        showCompletions(manual: true)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let input = (insertString as? NSAttributedString)?.string ?? insertString as? String
        guard usesLaTeXSyntax, isTypingKey, !hasMarkedText(), selectedRanges.count == 1,
              let input, input.utf16.count == 1 else {
            dismissCompletion()
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let source = string as NSString
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        let closer = Self.closingDelimiters[input]
        let skippingCloser = range.length == 0 && automaticClosers[range.location] == input
        if (closer != nil || skippingCloser), range.location != NSNotFound, NSMaxRange(range) <= source.length,
           LaTeXCompletion.isCode(in: source, before: range.location) {
            if skippingCloser, range.location < source.length,
               source.substring(with: NSRange(location: range.location, length: 1)) == input {
                automaticClosers.removeValue(forKey: range.location)
                setSelectedRange(NSRange(location: range.location + 1, length: 0))
                dismissCompletion()
                return
            }
            if let closer, canPair(in: source, replacing: range) {
                let pair = input + source.substring(with: range) + closer
                let inner = NSRange(location: range.location + 1, length: range.length)
                super.insertText(pair, replacementRange: range)
                if NSMaxRange(inner) < (textStorage?.length ?? 0),
                   (string as NSString).substring(with: NSRange(location: range.location, length: pair.utf16.count)) == pair {
                    automaticClosers[NSMaxRange(inner)] = closer
                    setSelectedRange(inner)
                }
                showCompletions()
                return
            }
        }
        super.insertText(insertString, replacementRange: replacementRange)
        showCompletions()
    }

    private func canPair(in source: NSString, replacing range: NSRange) -> Bool {
        if range.length > 0 || range.location == source.length { return true }
        return switch source.character(at: range.location) {
        case 0x09, 0x0a, 0x0d, 0x20, 0x29, 0x2c, 0x2e, 0x3b, 0x5d, 0x7d: true
        default: false
        }
    }

    override func deleteBackward(_ sender: Any?) {
        let range = selectedRange()
        let source = string as NSString
        if usesLaTeXSyntax, isTypingKey, !hasMarkedText(), selectedRanges.count == 1,
           range.length == 0, range.location > 0, range.location < source.length,
           let closer = automaticClosers[range.location],
           Self.closingDelimiters[source.substring(with: NSRange(location: range.location - 1, length: 1))] == closer,
           source.substring(with: NSRange(location: range.location, length: 1)) == closer {
            super.insertText("", replacementRange: NSRange(location: range.location - 1, length: 2))
        } else {
            super.deleteBackward(sender)
        }
        if isTypingKey { showCompletions() }
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        guard !automaticClosers.isEmpty, let replacementString else { return true }
        let end = NSMaxRange(affectedCharRange)
        let delta = replacementString.utf16.count - affectedCharRange.length
        automaticClosers = Dictionary(uniqueKeysWithValues: automaticClosers.compactMap { offset, closer in
            if offset < affectedCharRange.location { return (offset, closer) }
            if offset >= end { return (offset + delta, closer) }
            return nil
        })
        return true
    }

    override func didChangeText() {
        if undoManager?.isUndoing == true || undoManager?.isRedoing == true { automaticClosers.removeAll() }
        if !isTypingKey { dismissCompletion() }
        super.didChangeText()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { dismissCompletion() }
        return resigned
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { dismissCompletion() }
        super.viewWillMove(toWindow: newWindow)
    }

    func resetTypingAssistance() {
        automaticClosers.removeAll()
        dismissCompletion()
    }

    func dismissCompletionIfCaretMoved() {
        guard let completionRange else { return }
        let selection = selectedRange()
        if selection.length != 0 || selection.location != NSMaxRange(completionRange) { dismissCompletion() }
    }

    func dismissCompletion() {
        completionRange = nil
        completionPopup?.dismiss()
    }

    private func showCompletions(manual: Bool = false) {
        let selection = selectedRange()
        guard usesLaTeXSyntax, !hasMarkedText(), selectedRanges.count == 1, selection.length == 0,
              let window, window.firstResponder === self,
              let match = LaTeXCompletion.match(in: string as NSString, at: selection.location, manual: manual),
              let caret = completionAnchor(at: selection.location, in: window) else {
            dismissCompletion()
            return
        }
        let popup = completionPopup ?? LaTeXCompletionPopup()
        popup.onAccept = { [weak self] option in self?.acceptCompletion(option) }
        completionPopup = popup
        completionRange = match.range
        popup.show(match.candidates, below: caret, in: window)
    }

    private func completionAnchor(at offset: Int, in window: NSWindow) -> NSRect? {
        guard offset > 0, let layout = layoutManager, let container = textContainer else { return nil }
        let character = NSRange(location: offset - 1, length: 1)
        layout.ensureLayout(forCharacterRange: character)
        let glyph = layout.glyphRange(forCharacterRange: character, actualCharacterRange: nil)
        guard glyph.length > 0 else { return nil }
        let bounds = layout.boundingRect(forGlyphRange: glyph, in: container)
        let row = layout.lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil)
        let caret = NSRect(x: textContainerOrigin.x + bounds.maxX, y: textContainerOrigin.y + row.minY,
                           width: 1, height: row.height)
        return window.convertToScreen(convert(caret, to: nil))
    }

    private func acceptCompletion(_ option: LaTeXCompletion.Candidate) {
        guard let range = completionRange else { return }
        dismissCompletion()
        let selection = selectedRange()
        guard !hasMarkedText(), selection.length == 0, selection.location == NSMaxRange(range) else { return }
        breakUndoCoalescing()
        super.insertText(option.insertion, replacementRange: range)
        breakUndoCoalescing()
    }
}

private final class LineNumberRuler: NSRulerView {
    private weak var textView: LaTeXTextView?
    private var lineStarts = SourceLineStarts("")
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(scrollView: NSScrollView, textView: LaTeXTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        ruleThickness = 41
    }

    required init(coder: NSCoder) { fatalError("LineNumberRuler requires a text view") }

    func update(_ lineStarts: SourceLineStarts) {
        self.lineStarts = lineStarts
        let width = ceil((String(lineStarts.offsets.count) as NSString).size(withAttributes: [.font: numberFont]).width)
        let thickness = max(41, width + 20)
        if ruleThickness != thickness { ruleThickness = thickness }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        let dirtyRect = rect.intersection(bounds)
        guard !dirtyRect.isEmpty else { return }
        AppPalette.gutter.setFill()
        dirtyRect.fill()
        AppPalette.rule.setFill()
        NSRect(x: bounds.maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()

        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let origin = textView.textContainerOrigin
        let visibleRect = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visibleRect, in: container)
        let currentRow = textView.currentVisualRow
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            let start = layout.characterIndexForGlyph(at: glyphRange.location)
            let index = self.lineStarts.index(containing: start)
            guard self.lineStarts.offsets[index] == start else { return }
            self.draw(index + 1, in: fragment.offsetBy(dx: origin.x, dy: origin.y), currentRow: currentRow,
                      from: textView, dirtyRect: dirtyRect)
        }
        if layout.extraLineFragmentTextContainer === container {
            draw(lineStarts.offsets.count, in: layout.extraLineFragmentRect.offsetBy(dx: origin.x, dy: origin.y), currentRow: currentRow,
                 from: textView, dirtyRect: dirtyRect)
        }
    }

    private func draw(_ number: Int, in fragment: NSRect, currentRow: NSRect, from textView: NSTextView, dirtyRect: NSRect) {
        let line = convert(fragment, from: textView)
        guard line.maxY >= dirtyRect.minY, line.minY <= dirtyRect.maxY else { return }
        let isCurrent = currentRow.minY <= fragment.midY && fragment.midY < currentRow.maxY
        if isCurrent {
            let marker = NSRect(x: 5, y: line.minY + 2, width: bounds.width - 10, height: line.height - 4)
            AppPalette.selection.setFill()
            NSBezierPath(roundedRect: marker, xRadius: 4, yRadius: 4).fill()
        }
        let label = String(number) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont, .foregroundColor: isCurrent ? AppPalette.accent : AppPalette.mutedText
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: bounds.maxX - size.width - 10, y: line.midY - size.height / 2), withAttributes: attributes)
    }
}
