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
    weak var documentUndoManager: UndoManager?
    var referenceCandidates: ((ProjectReferenceKind, String) async -> [LaTeXCompletion.Candidate])? {
        get { textView.referenceCandidates }
        set { textView.referenceCandidates = newValue }
    }
    var onLabelDefinition: ((String) -> Void)? {
        get { textView.onLabelDefinition }
        set { textView.onLabelDefinition = newValue }
    }
    var onImageDrop: (([URL], Int) -> Bool)? {
        get { textView.onImageDrop }
        set { textView.onImageDrop = newValue }
    }
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
            guard !newValue.utf8.elementsEqual(textView.string.utf8) else { return }
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

    @discardableResult
    func insertImagePaths(_ paths: [String], at offset: Int, expectedSource: String) -> Bool {
        guard !paths.isEmpty, textView.isEditable, !textView.hasMarkedText(),
              textView.string.utf8.elementsEqual(expectedSource.utf8) else { return false }
        let source = textView.string as NSString
        guard (0...source.length).contains(offset) else { return false }
        let location = offset < source.length ? source.rangeOfComposedCharacterSequence(at: offset).location : offset
        let range = NSRange(location: location, length: 0)
        let commands = paths.map { "\\includegraphics[width=\\linewidth]{\($0)}" }.joined(separator: "\n")
        focusEditor()
        textView.breakUndoCoalescing()
        textView.insertText(commands, replacementRange: range)
        textView.breakUndoCoalescing()
        return textView.string.utf8.elementsEqual(source.replacingCharacters(in: range, with: commands).utf8)
    }

    var editorPosition: ProjectHistory.EditorPosition? {
        let location = textView.selectedRange().location
        guard location != NSNotFound, let scrollView = textView.enclosingScrollView else { return nil }
        let clip = scrollView.contentView
        return .init(caretOffset: location, scrollY: clip.bounds.minY,
                     caretWasVisible: isCaretVisible(in: clip), upstreamAffinity: textView.selectionAffinity == .upstream)
    }

    func restoreEditorPosition(_ position: ProjectHistory.EditorPosition) {
        let source = textView.string as NSString
        let offset = min(max(0, position.caretOffset), source.length)
        let location = offset < source.length ? source.rangeOfComposedCharacterSequence(at: offset).location : offset
        let range = NSRange(location: location, length: 0)
        textView.setSelectedRange(range, affinity: position.upstreamAffinity == true ? .upstream : .downstream,
                                  stillSelecting: false)
        restoreEditorScroll(position)
    }

    func restoreEditorScroll(_ position: ProjectHistory.EditorPosition) {
        guard let scrollView = textView.enclosingScrollView else { return }
        scrollView.layoutSubtreeIfNeeded()
        let range = NSRange(location: textView.selectedRange().location, length: 0)
        if range.location != NSNotFound { textView.scrollRangeToVisible(range) }
        guard position.scrollY.isFinite else { return }
        let clip = scrollView.contentView
        var bounds = clip.bounds
        bounds.origin.y = max(0, position.scrollY)
        let origin = textView.textContainerOrigin
        let textBounds = textView.convert(bounds, from: clip).offsetBy(dx: -origin.x, dy: -origin.y)
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(forBoundingRect: textBounds, in: container)
        }
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
        // A different window width can rewrap text above the caret before the saved scroll offset.
        if range.location != NSNotFound, position.caretWasVisible == true, isCaretVisible(in: clip) != true {
            textView.scrollRangeToVisible(range)
        }
    }

    private func isCaretVisible(in clip: NSClipView) -> Bool? {
        let row = textView.currentVisualRow
        guard !row.isEmpty else { return nil }
        return textView.convert(clip.bounds, from: clip).intersects(row)
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
            return SourceTextEdit(
                range: NSRange(location: prefix.offset, length: uncomment ? (removeSpace ? 2 : 1) : 0),
                replacement: uncomment ? "" : "% "
            )
        }
        guard !edits.isEmpty else { return }
        focusEditor()
        applyEdits(edits, actionName: "Toggle Comment", storage: storage)
    }

    func applyProjectReplacement(ranges: [NSRange], replacement: String, expected: String) -> Bool {
        guard !textView.hasMarkedText(), let storage = textView.textStorage,
              textView.string.utf8.elementsEqual(expected.utf8) else { return false }
        let edits = ranges.map { SourceTextEdit(range: $0, replacement: replacement) }
        return applyEdits(edits, actionName: "Replace in Project", storage: storage)
    }

    @discardableResult
    private func applyEdits(_ edits: [SourceTextEdit], actionName: String, storage: NSTextStorage) -> Bool {
        guard let first = edits.first, let last = edits.last else { return false }
        let changedRange = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        let source = textView.string as NSString
        let replacement = NSMutableString(string: source.substring(with: changedRange))
        for edit in edits.reversed() {
            let localRange = NSRange(location: edit.range.location - changedRange.location, length: edit.range.length)
            replacement.replaceCharacters(in: localRange, with: edit.replacement)
        }
        let updatedSelections = textView.selectedRanges.map(\.rangeValue).map { selection in
            let start = movedOffset(selection.location, through: edits)
            let end = movedOffset(NSMaxRange(selection), through: edits)
            return NSValue(range: NSRange(location: start, length: end - start))
        }

        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: changedRange, replacementString: replacement as String) else { return false }
        storage.replaceCharacters(in: changedRange, with: replacement as String)
        textView.setSelectedRanges(updatedSelections, affinity: .downstream, stillSelecting: false)
        textView.didChangeText()
        textView.breakUndoCoalescing()
        textView.undoManager?.setActionName(actionName)
        return true
    }

    private func movedOffset(_ offset: Int, through edits: [SourceTextEdit]) -> Int {
        var delta = 0
        for edit in edits {
            if offset < edit.range.location { break }
            if offset < NSMaxRange(edit.range) { return edit.range.location + delta }
            delta += edit.replacement.utf16.count - edit.range.length
        }
        return offset + delta
    }

    func undoManager(for view: NSTextView) -> UndoManager? { documentUndoManager }

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

private struct SourceTextEdit {
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
    private var completionCaret: Int?
    private var referenceTask: Task<Void, Never>?
    private var automaticClosers: [Int: String] = [:]
    private var isTypingKey = false
    private static let closingDelimiters = ["{": "}", "[": "]", "(": ")"]
    var onUnmark: (() -> Void)?
    var referenceCandidates: ((ProjectReferenceKind, String) async -> [LaTeXCompletion.Candidate])?
    var onLabelDefinition: ((String) -> Void)?
    var onImageDrop: (([URL], Int) -> Bool)?
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

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        let types = super.acceptableDragTypes
        return types.contains(.fileURL) ? types : types + [.fileURL]
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let native = super.draggingEntered(sender)
        return imageDropURLs(sender) == nil ? native : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let native = super.draggingUpdated(sender)
        return imageDropURLs(sender) == nil ? native : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        imageDropURLs(sender) != nil || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = imageDropURLs(sender), let onImageDrop else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        let offset = characterIndexForInsertion(at: point)
        return offset != NSNotFound && onImageDrop(urls, offset)
    }

    private func imageDropURLs(_ sender: NSDraggingInfo) -> [URL]? {
        guard usesLaTeXSyntax, isEditable, !hasMarkedText(), onImageDrop != nil,
              sender.draggingSourceOperationMask.contains(.copy) else { return nil }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let urls, !urls.isEmpty, urls.allSatisfy(ProjectImageImport.supports) else { return nil }
        return urls
    }

    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .command, let onLabelDefinition, let label = labelReference(for: event) {
            dismissCompletion()
            onLabelDefinition(label)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let nativeMenu = super.menu(for: event)
        guard onLabelDefinition != nil, let label = labelReference(for: event) else { return nativeMenu }
        let menu = nativeMenu?.copy() as? NSMenu ?? NSMenu()
        let item = NSMenuItem(title: "Go to Label Definition", action: #selector(goToLabelDefinition(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = label
        if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        menu.insertItem(item, at: 0)
        return menu
    }

    @objc private func goToLabelDefinition(_ item: NSMenuItem) {
        if let label = item.representedObject as? String { onLabelDefinition?(label) }
    }

    private func labelReference(for event: NSEvent) -> String? {
        guard usesLaTeXSyntax, let layout = layoutManager, let container = textContainer else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let source = string as NSString
        let index = characterIndexForInsertion(at: point)
        guard let reference = LaTeXCompletion.referenceMatch(in: source, at: index), reference.kind == .label,
              reference.range.length > 0 else { return nil }
        let label = source.substring(with: reference.range)
        guard label.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: reference.range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textContainerOrigin.x,
                                                                                   dy: textContainerOrigin.y)
        return rect.contains(point) ? label : nil
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !registeredDraggedTypes.contains(.fileURL) {
            registerForDraggedTypes(registeredDraggedTypes + [.fileURL])
        }
    }

    func resetTypingAssistance() {
        automaticClosers.removeAll()
        dismissCompletion()
    }

    func dismissCompletionIfCaretMoved() {
        guard let completionCaret else { return }
        let selection = selectedRange()
        if selection.length != 0 || selection.location != completionCaret { dismissCompletion() }
    }

    func dismissCompletion() {
        referenceTask?.cancel()
        referenceTask = nil
        completionRange = nil
        completionCaret = nil
        completionPopup?.dismiss()
    }

    private func showCompletions(manual: Bool = false) {
        let selection = selectedRange()
        guard usesLaTeXSyntax, !hasMarkedText(), selectedRanges.count == 1, selection.length == 0,
              let window, window.firstResponder === self else {
            dismissCompletion()
            return
        }
        let source = string as NSString
        if let reference = LaTeXCompletion.referenceMatch(in: source, at: selection.location), let referenceCandidates {
            dismissCompletion()
            completionCaret = selection.location
            referenceTask = Task { [weak self] in
                let candidates = await referenceCandidates(reference.kind, reference.query)
                guard !Task.isCancelled, let self, self.selectedRange() == selection else { return }
                self.referenceTask = nil
                self.presentCompletions(candidates, replacing: reference.range, at: selection.location,
                                        showsReferenceDetails: true)
            }
            return
        }
        guard let match = LaTeXCompletion.match(in: source, at: selection.location, manual: manual) else {
            dismissCompletion()
            return
        }
        presentCompletions(match.candidates, replacing: match.range, at: selection.location)
    }

    private func presentCompletions(_ candidates: [LaTeXCompletion.Candidate], replacing range: NSRange, at offset: Int,
                                    showsReferenceDetails: Bool = false) {
        guard !candidates.isEmpty, let window, window.firstResponder === self,
              let caret = completionAnchor(at: offset, in: window) else {
            dismissCompletion()
            return
        }
        let popup = completionPopup ?? LaTeXCompletionPopup()
        popup.onAccept = { [weak self] option in self?.acceptCompletion(option) }
        completionPopup = popup
        completionRange = range
        completionCaret = offset
        popup.show(candidates, below: caret, in: window, showsReferenceDetails: showsReferenceDetails)
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
        guard let range = completionRange, let caret = completionCaret else { return }
        dismissCompletion()
        let selection = selectedRange()
        guard !hasMarkedText(), selection.length == 0, selection.location == caret else { return }
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
