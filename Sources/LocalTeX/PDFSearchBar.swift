import AppKit
import PDFKit

@MainActor
final class PDFSearchBar: WorkspaceSurface, NSSearchFieldDelegate {
    private weak var pdfView: PreviewPDFView?
    private let field = NSSearchField()
    private let previous = NSButton()
    private let next = NSButton()
    private let status = NSTextField(labelWithString: "")
    private lazy var barHeight = heightAnchor.constraint(equalToConstant: 0)
    private var data: Data?
    private var searchDocument: PDFDocument?
    private var observers: [NSObjectProtocol] = []
    private var pendingSearch: Task<Void, Never>?
    private var matches: [PDFSelection] = []
    private var matchIndex: Int?
    private var query = ""
    private var directionWhenReady: Int?
    private var isSearching = false

    init(pdfView: PreviewPDFView) {
        self.pdfView = pdfView
        super.init(AppPalette.chrome)
        setAccessibilityIdentifier("PDFSearchBar")
        isHidden = true
        barHeight.isActive = true

        field.placeholderString = "Find in PDF"
        field.setAccessibilityLabel("Find in PDF")
        field.setAccessibilityIdentifier("PDFSearchField")
        field.sendsWholeSearchString = true
        field.delegate = self
        field.target = self
        field.action = #selector(nextMatch(_:))
        field.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = AppPalette.secondaryText
        status.alignment = .right
        status.lineBreakMode = .byTruncatingTail
        let close = NSButton()
        configure(previous, symbol: "chevron.up", label: "Previous PDF Match", action: #selector(previousMatch(_:)))
        configure(next, symbol: "chevron.down", label: "Next PDF Match", action: #selector(nextMatch(_:)))
        configure(close, symbol: "xmark", label: "Close PDF Search", action: #selector(closeSearch(_:)))
        let controls = NSStackView(views: [field, status, previous, next, close])
        controls.alignment = .centerY
        controls.spacing = 5
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 86),
            status.widthAnchor.constraint(lessThanOrEqualToConstant: 85)
        ])
        updateControls()
    }

    required init?(coder: NSCoder) { nil }

    var hasFocus: Bool {
        guard !isHidden, let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self) || field.currentEditor() === responder
    }

    var visibleQuery: String? { isHidden ? nil : field.stringValue }

    deinit {
        pendingSearch?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        searchDocument?.cancelFindString()
    }

    func setPreviewData(_ data: Data?) {
        self.data = data
        if data == nil { closeSearch(nil) }
        else if !isHidden { startSearch(direction: nil) }
    }

    func show() {
        if isHidden { restoreVisibleQuery(field.stringValue) }
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    func restoreVisibleQuery(_ query: String?) {
        guard visibleQuery != query else { return }
        guard let query else {
            closeSearch(nil)
            return
        }
        field.stringValue = query
        barHeight.constant = 34
        isHidden = false
        startSearch(direction: nil)
    }

    @objc private func closeSearch(_ sender: Any?) {
        guard !isHidden else { return }
        if hasFocus { window?.makeFirstResponder(pdfView?.isHidden == false ? pdfView : nil) }
        isHidden = true
        barHeight.constant = 0
        pendingSearch?.cancel()
        pendingSearch = nil
        stopSearch()
        matches.removeAll()
        matchIndex = nil
        pdfView?.highlightedSelections = nil
    }

    func move(_ direction: Int) {
        if isHidden { show() }
        if pendingSearch != nil || currentQuery != query {
            startSearch(direction: direction)
        } else if isSearching {
            directionWhenReady = direction
        } else if !matches.isEmpty {
            let index = matchIndex.map { ($0 + direction + matches.count) % matches.count }
                ?? firstMatch(inDirection: direction)
            reveal(index)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        pendingSearch?.cancel()
        pendingSearch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            self?.startSearch(direction: 1)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            closeSearch(nil)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            move(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
        default:
            return false
        }
        return true
    }

    private var currentQuery: String { field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func startSearch(direction: Int?) {
        pendingSearch?.cancel()
        pendingSearch = nil
        stopSearch()
        matches.removeAll()
        matchIndex = nil
        pdfView?.highlightedSelections = nil
        query = currentQuery
        directionWhenReady = direction
        guard !query.isEmpty, let data, let document = PDFDocument(data: data) else {
            updateControls()
            return
        }

        // PDFKit has one asynchronous search per document. Isolate each window's search.
        searchDocument = document
        isSearching = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .PDFDocumentDidFindMatch, object: document, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.foundMatch(note) }
            },
            center.addObserver(forName: .PDFDocumentDidEndFind, object: document, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.finishedSearch(note) }
            }
        ]
        document.beginFindString(query, withOptions: .caseInsensitive)
        updateControls()
    }

    private func stopSearch() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        let document = searchDocument
        searchDocument = nil
        isSearching = false
        document?.cancelFindString()
    }

    private func foundMatch(_ notification: Notification) {
        guard let document = notification.object as? PDFDocument, document === searchDocument,
              let match = notification.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
        matches.append(match)
    }

    private func finishedSearch(_ notification: Notification) {
        guard let document = notification.object as? PDFDocument, document === searchDocument else { return }
        isSearching = false
        if let direction = directionWhenReady, !matches.isEmpty { reveal(firstMatch(inDirection: direction)) }
        directionWhenReady = nil
        updateControls()
    }

    private func firstMatch(inDirection direction: Int) -> Int {
        guard let view = pdfView, let page = view.currentPage, let index = view.document?.index(for: page),
              let searchDocument else { return direction > 0 ? 0 : matches.count - 1 }
        if direction > 0 {
            return matches.firstIndex { $0.pages.first.map { searchDocument.index(for: $0) >= index } ?? false } ?? 0
        }
        return matches.lastIndex { $0.pages.last.map { searchDocument.index(for: $0) <= index } ?? false }
            ?? matches.count - 1
    }

    private func reveal(_ index: Int) {
        guard let pdfView, let displayed = pdfView.document, let searchDocument else { return }
        let match = matches[index]
        let selection = PDFSelection(document: displayed)
        for page in match.pages {
            guard let displayedPage = displayed.page(at: searchDocument.index(for: page)) else { continue }
            for rangeIndex in 0..<match.numberOfTextRanges(on: page) {
                if let part = displayedPage.selection(for: match.range(at: rangeIndex, on: page)) { selection.add(part) }
            }
        }
        guard !selection.pages.isEmpty else { return }
        matchIndex = index
        selection.color = NSColor(srgbRed: 0.98, green: 0.67, blue: 0.29, alpha: 0.68)
        pdfView.highlightedSelections = [selection]
        pdfView.go(to: selection)
        updateControls()
    }

    private func updateControls() {
        previous.isEnabled = !isSearching && !matches.isEmpty
        next.isEnabled = previous.isEnabled
        if query.isEmpty { status.stringValue = "" }
        else if isSearching { status.stringValue = "Searching…" }
        else if let matchIndex { status.stringValue = "\(matchIndex + 1) of \(matches.count)" }
        else { status.stringValue = matches.isEmpty ? "No matches" : "\(matches.count) matches" }
    }

    @objc private func nextMatch(_ sender: Any?) { move(1) }
    @objc private func previousMatch(_ sender: Any?) { move(-1) }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.contentTintColor = AppPalette.secondaryText
        button.toolTip = label
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 21).isActive = true
    }
}
