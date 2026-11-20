import AppKit

@MainActor
final class TexOutlineController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private struct ItemID: Hashable {
        let heading: String
        let occurrence: Int
    }

    private final class Item {
        let heading: TeXHeading
        let id: ItemID
        var children: [Item] = []

        init(heading: TeXHeading, id: ItemID) {
            self.heading = heading
            self.id = id
        }
    }

    private let outline = NSOutlineView()
    private let emptyLabel = NSTextField(labelWithString: "No section headings")
    private var roots: [Item] = []
    private var collapsed: Set<ItemID> = []
    private var collapsingItem: ItemID?
    private var isReloading = false
    private var hasInitialSource = false
    private var updateTask: Task<Void, Never>?

    var onNavigate: ((NSRange) -> Void)?

    override func loadView() {
        let panel = NSView()
        view = panel
        let heading = SidebarAppearance.heading("Outline")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Heading"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.autoresizesOutlineColumn = false
        let scroll = NSScrollView()
        SidebarAppearance.configure(outline, in: scroll)
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(navigate(_:))
        outline.setAccessibilityLabel("Document outline")

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = AppPalette.secondaryText
        emptyLabel.alignment = .center
        for child in [heading, scroll, emptyLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(child)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: SidebarAppearance.titleInset),
            heading.centerYAnchor.constraint(equalTo: panel.topAnchor, constant: SidebarAppearance.headerHeight / 2),
            scroll.topAnchor.constraint(equalTo: panel.topAnchor, constant: SidebarAppearance.headerHeight),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: SidebarAppearance.listInset),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -SidebarAppearance.listInset),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
    }

    func update(source: String) {
        guard hasInitialSource else {
            hasInitialSource = true
            reload(source)
            return
        }
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            self.updateTask = nil
            self.reload(source)
        }
    }

    private func reload(_ source: String) {
        _ = view
        let selected: Item? = outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? Item : nil
        var occurrences: [String: Int] = [:]
        var ancestors: [Item] = []
        var items: [Item] = []
        roots.removeAll()
        for heading in TeXHeading.parse(source) {
            let key = "\(heading.level):\(heading.title)"
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            let item = Item(heading: heading, id: ItemID(heading: key, occurrence: occurrence))
            while let parent = ancestors.last, parent.heading.level >= heading.level {
                ancestors.removeLast()
            }
            if let parent = ancestors.last {
                parent.children.append(item)
            } else {
                roots.append(item)
            }
            ancestors.append(item)
            items.append(item)
        }

        isReloading = true
        collapsed.formIntersection(items.map(\.id))
        outline.reloadData()
        restoreExpandedItems(roots)
        if let selected, let item = items.first(where: { $0.id == selected.id }) {
            let row = outline.row(forItem: item)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        isReloading = false
        emptyLabel.isHidden = !roots.isEmpty
    }

    private func restoreExpandedItems(_ items: [Item]) {
        for item in items where !item.children.isEmpty && !collapsed.contains(item.id) {
            outline.expandItem(item)
        }
    }

    @objc private func navigate(_ sender: NSOutlineView) {
        guard updateTask == nil, sender.clickedRow >= 0,
              let item = sender.item(atRow: sender.clickedRow) as? Item else { return }
        onNavigate?(item.heading.range)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? Item)?.children ?? roots).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Item)?.children ?? roots)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Item)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        PaletteSelectionRow.reusable(in: outlineView)
    }

    func outlineViewItemWillCollapse(_ notification: Notification) {
        guard !isReloading, collapsingItem == nil, let item = notification.userInfo?["NSObject"] as? Item else { return }
        // AppKit also reports child collapses when an expanded parent closes.
        collapsingItem = item.id
        collapsed.insert(item.id)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? Item, collapsingItem == item.id {
            collapsingItem = nil
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? Item else { return }
        if !isReloading {
            collapsed.remove(item.id)
        }
        restoreExpandedItems(item.children)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("HeadingCell")
        let cell: SidebarTextCell
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: nil) as? SidebarTextCell {
            cell = reused
        } else {
            cell = SidebarTextCell()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.textColor = AppPalette.text
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = item.heading.title
        cell.textField?.font = .systemFont(ofSize: 13, weight: outlineView.level(forItem: item) == 0 ? .medium : .regular)
        cell.needsLayout = true
        return cell
    }
}

private struct TeXHeading {
    let level: Int
    let title: String
    let range: NSRange

    private static let levels = [
        "part": 0, "chapter": 1, "section": 2, "subsection": 3,
        "subsubsection": 4, "paragraph": 5, "subparagraph": 6
    ]
    private static let verbatimEnvironments: Set = [
        "verbatim", "verbatim*", "Verbatim", "BVerbatim", "LVerbatim", "lstlisting", "minted", "comment"
    ]
    private static let textFormatting: Set = [
        "emph", "textbf", "textit", "textup", "textsl", "textsc",
        "textrm", "textsf", "texttt", "textnormal", "underline", "mbox"
    ]

    static func parse(_ text: String) -> [TeXHeading] {
        var scanner = TeXScanner(text)
        var headings: [TeXHeading] = []
        var insideDocument = false
        while let command = scanner.nextCommand() {
            if command == "verb" || command == "lstinline" {
                scanner.skipInlineVerbatim(allowsOptions: command == "lstinline")
                continue
            }
            if command == "begin" || command == "end" {
                scanner.skipTrivia()
                guard let range = scanner.readGroup() else { continue }
                let environment = scanner.source.substring(with: range)
                if command == "begin" && verbatimEnvironments.contains(environment) {
                    scanner.skipVerbatimEnvironment(environment)
                } else if environment == "document" {
                    if command == "end" && insideDocument { break }
                    if command == "begin" && !insideDocument {
                        headings.removeAll()
                        insideDocument = true
                    }
                }
                continue
            }
            guard let level = levels[command] else { continue }
            scanner.skipTrivia()
            _ = scanner.consume(TeXScanner.star)
            scanner.skipTrivia()
            if scanner.current == TeXScanner.leftBracket {
                guard scanner.readGroup(optional: true) != nil else { continue }
                scanner.skipTrivia()
            }
            guard let range = scanner.readGroup() else { continue }
            let title = displayTitle(scanner.source.substring(with: range))
            headings.append(TeXHeading(level: level, title: title.isEmpty ? "Untitled" : title, range: range))
        }
        return headings
    }

    private static func displayTitle(_ text: String) -> String {
        var scanner = TeXScanner(text)
        var title = ""
        while let character = scanner.current {
            switch character {
            case TeXScanner.comment:
                scanner.skipComment()
            case TeXScanner.backslash:
                let start = scanner.offset
                let command = scanner.readCommand()
                switch command {
                case "%", "#", "_", "{", "}", "$", "&": title += command
                case "\\", " ", "\n", "\r": title += " "
                case "LaTeX", "TeX": title += command
                case _ where textFormatting.contains(command): break
                default:
                    title += scanner.source.substring(with: NSRange(location: start, length: scanner.offset - start))
                }
            case TeXScanner.leftBrace, TeXScanner.rightBrace:
                scanner.offset += 1
            case TeXScanner.tilde:
                scanner.offset += 1
                title += " "
            default:
                let start = scanner.offset
                scanner.offset += 1
                while let next = scanner.current,
                      next != TeXScanner.comment && next != TeXScanner.backslash &&
                      next != TeXScanner.leftBrace && next != TeXScanner.rightBrace && next != TeXScanner.tilde {
                    scanner.offset += 1
                }
                title += scanner.source.substring(with: NSRange(location: start, length: scanner.offset - start))
            }
        }
        return title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private struct TeXScanner {
    static let backslash: UInt16 = 0x5C
    static let comment: UInt16 = 0x25
    static let leftBrace: UInt16 = 0x7B
    static let rightBrace: UInt16 = 0x7D
    static let leftBracket: UInt16 = 0x5B
    static let rightBracket: UInt16 = 0x5D
    static let star: UInt16 = 0x2A
    static let tilde: UInt16 = 0x7E

    let source: NSString
    private let length: Int
    var offset = 0
    var current: UInt16? { offset < length ? source.character(at: offset) : nil }

    init(_ text: String) {
        source = text as NSString
        length = source.length
    }

    mutating func nextCommand() -> String? {
        while let character = current {
            switch character {
            case Self.backslash: return readCommand()
            case Self.comment: skipComment()
            default: offset += 1
            }
        }
        return nil
    }

    mutating func readCommand() -> String {
        offset += 1
        let start = offset
        while let character = current, Self.isCommandLetter(character) {
            offset += 1
        }
        if offset == start && offset < length {
            offset = NSMaxRange(source.rangeOfComposedCharacterSequence(at: offset))
        }
        return source.substring(with: NSRange(location: start, length: offset - start))
    }

    mutating func consume(_ character: UInt16) -> Bool {
        guard current == character else { return false }
        offset += 1
        return true
    }

    mutating func skipTrivia() {
        while let character = current {
            if character == Self.comment {
                skipComment()
            } else if Self.isWhitespace(character) {
                offset += 1
            } else {
                break
            }
        }
    }

    mutating func skipComment() {
        while let character = current, !Self.isNewline(character) {
            offset += 1
        }
        _ = consume(0x0D)
        _ = consume(0x0A)
    }

    mutating func readGroup(optional: Bool = false) -> NSRange? {
        let opening = optional ? Self.leftBracket : Self.leftBrace
        let closing = optional ? Self.rightBracket : Self.rightBrace
        guard consume(opening) else { return nil }
        let start = offset
        var depth = 1
        var braces = 0
        while let character = current {
            if character == Self.backslash {
                _ = readCommand()
            } else if character == Self.comment {
                skipComment()
            } else {
                offset += 1
                if optional && character == Self.leftBrace {
                    braces += 1
                } else if optional && character == Self.rightBrace && braces > 0 {
                    braces -= 1
                } else if braces == 0 && character == opening {
                    depth += 1
                } else if braces == 0 && character == closing {
                    depth -= 1
                    if depth == 0 {
                        return NSRange(location: start, length: offset - start - 1)
                    }
                }
            }
        }
        return nil
    }

    mutating func skipInlineVerbatim(allowsOptions: Bool) {
        _ = consume(Self.star)
        if allowsOptions && current == Self.leftBracket {
            _ = readGroup(optional: true)
        }
        guard let marker = current, !Self.isWhitespace(marker) else { return }
        let terminator = marker == Self.leftBrace && allowsOptions ? Self.rightBrace : marker
        offset += 1
        while let character = current, !Self.isNewline(character) {
            offset += 1
            if character == terminator { return }
        }
    }

    mutating func skipVerbatimEnvironment(_ name: String) {
        let range = source.range(of: "\\end{\(name)}", range: NSRange(location: offset, length: length - offset))
        offset = range.location == NSNotFound ? length : NSMaxRange(range)
    }

    private static func isCommandLetter(_ character: UInt16) -> Bool {
        (0x41...0x5A).contains(character) || (0x61...0x7A).contains(character) || character == 0x40
    }

    private static func isWhitespace(_ character: UInt16) -> Bool {
        character == 0x20 || (0x09...0x0D).contains(character)
    }

    private static func isNewline(_ character: UInt16) -> Bool {
        character == 0x0A || character == 0x0D
    }
}
