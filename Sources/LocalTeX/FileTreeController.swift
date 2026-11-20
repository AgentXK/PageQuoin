import AppKit

@MainActor
final class FileTreeController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuItemValidation {
    enum CreationKind {
        case file, folder
    }

    private final class Entry: NSObject {
        let url: URL
        let isDirectory: Bool
        let kind: ProjectFileKind?
        var children: [Entry]?
        var isUnreadable = false

        init(url: URL, isDirectory: Bool, kind: ProjectFileKind? = nil) {
            self.url = url
            self.isDirectory = isDirectory
            self.kind = kind
        }
    }

    private let tree = FileOutlineView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private var creationButtons: [NSButton] = []
    private var root: Entry?
    private var mainFile: URL?

    var onOpenFile: ((URL) -> Void)?
    var onCreateEntry: ((CreationKind, URL) -> Void)?
    var onChooseRoot: (() -> Void)?
    var onSetMainFile: ((URL) -> Void)?

    override func loadView() {
        let container = NSView()
        view = container

        let title = SidebarAppearance.heading("Files")
        let newFile = headerButton(symbol: "doc.badge.plus", label: "New File", action: #selector(createFile(_:)))
        let newFolder = headerButton(symbol: "folder.badge.plus", label: "New Folder", action: #selector(createFolder(_:)))
        creationButtons = [newFile, newFolder]

        let header = NSView()
        header.menu = contextMenu(for: -1)
        for child in [title, newFile, newFolder] {
            child.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(child)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: SidebarAppearance.titleInset),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            newFile.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            newFile.trailingAnchor.constraint(equalTo: newFolder.leadingAnchor, constant: -4),
            newFile.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            newFolder.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            newFolder.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ProjectEntry"))
        column.resizingMask = .autoresizingMask
        tree.addTableColumn(column)
        tree.outlineTableColumn = column
        tree.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tree.autoresizesOutlineColumn = false
        SidebarAppearance.configure(tree, in: scroll)
        tree.dataSource = self
        tree.delegate = self
        tree.target = self
        tree.doubleAction = #selector(openClickedEntry(_:))
        tree.onReturn = { [weak self] in
            guard let self else { return }
            openEntry(at: tree.selectedRow)
        }
        tree.contextMenuForRow = { [weak self] row in self?.contextMenu(for: row) }
        tree.setAccessibilityLabel("Project Files")

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = AppPalette.secondaryText
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2

        let body = NSView()
        for child in [scroll, emptyLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(child)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: body.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: SidebarAppearance.listInset),
            scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -SidebarAppearance.listInset),
            emptyLabel.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -12)
        ])

        for child in [header, body] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: container.trailingAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.heightAnchor.constraint(equalToConstant: SidebarAppearance.headerHeight),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        updateRows()
    }

    @discardableResult
    func setRoot(_ url: URL?) -> Bool {
        let normalized = url?.standardizedFileURL
        guard root?.url.path != normalized?.path else { return false }
        root = normalized.map { Entry(url: $0, isDirectory: true) }
        if isViewLoaded {
            updateRows()
        }
        return true
    }

    func selectFile(_ url: URL?) {
        _ = view
        guard let url, let ancestry = entries(to: url), let entry = ancestry.last else {
            tree.deselectAll(nil)
            return
        }
        for directory in ancestry.dropLast() {
            tree.expandItem(directory)
        }
        let row = tree.row(forItem: entry)
        guard row >= 0 else { return }
        tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tree.scrollRowToVisible(row)
    }

    func setMainFile(_ url: URL?) {
        let normalized = url?.standardizedFileURL
        guard mainFile?.path != normalized?.path else { return }
        let previous = mainFile
        mainFile = normalized
        guard isViewLoaded else { return }
        var rows = IndexSet()
        for file in [previous, normalized].compactMap({ $0 }) {
            if let entry = entries(to: file)?.last {
                let row = tree.row(forItem: entry)
                if row >= 0 { rows.insert(row) }
            }
        }
        tree.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    }

    func reload() {
        guard let root else { return }
        _ = view
        let selected = entry(at: tree.selectedRow)?.url
        let expanded = (0..<tree.numberOfRows).compactMap { row -> URL? in
            guard let entry = entry(at: row), entry.isDirectory, tree.isItemExpanded(entry) else { return nil }
            return entry.url
        }
        root.children = nil
        updateRows()
        for url in expanded {
            if let entry = entries(to: url)?.last, entry.isDirectory {
                tree.expandItem(entry)
            }
        }
        selectFile(selected)
    }

    private func updateRows() {
        tree.reloadData()
        if let root {
            emptyLabel.stringValue = root.isUnreadable ? "Could Not Read Folder" : "This Folder Is Empty"
        } else {
            emptyLabel.stringValue = "Open a folder to browse project files."
        }
        for button in creationButtons { button.isEnabled = root != nil }
        emptyLabel.isHidden = tree.numberOfRows > 0
        scroll.isHidden = !emptyLabel.isHidden
    }

    private func children(of entry: Entry?) -> [Entry] {
        guard let directory = entry ?? root, directory.isDirectory else { return [] }
        if let children = directory.children { return children }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isRegularFileKey, .isSymbolicLinkKey]
        let urls = try? FileManager.default.contentsOfDirectory(at: directory.url,
                                                              includingPropertiesForKeys: Array(keys),
                                                              options: [.skipsHiddenFiles])
        directory.isUnreadable = urls == nil
        let children = (urls ?? []).map { url in
            let values = try? url.resourceValues(forKeys: keys)
            let isDirectory = values?.isDirectory == true && values?.isPackage != true && values?.isSymbolicLink != true
            let kind = values?.isRegularFile == true || values?.isSymbolicLink == true
                ? ProjectFileKind.detect(for: url) : nil
            return Entry(url: url, isDirectory: isDirectory, kind: kind)
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        directory.children = children
        return children
    }

    private func relativePathComponents(to url: URL) -> [String]? {
        guard let root else { return nil }
        let target = url.standardizedFileURL
        var base = root.url.pathComponents
        var path = target.pathComponents
        if !path.starts(with: base) {
            // Directory listings may canonicalize the project root's path.
            base = root.url.resolvingSymlinksInPath().pathComponents
            path = target.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
                + [target.lastPathComponent]
        }
        guard path.starts(with: base) else { return nil }
        return Array(path.dropFirst(base.count))
    }

    private func entries(to url: URL) -> [Entry]? {
        guard let root, let parts = relativePathComponents(to: url) else { return nil }
        var directory = root
        var ancestry: [Entry] = []
        for part in parts {
            guard let match = children(of: directory).first(where: { $0.url.lastPathComponent == part }) else { return nil }
            ancestry.append(match)
            directory = match
        }
        return ancestry
    }

    private func headerButton(symbol: String, label: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let configuredImage = image.withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) ?? image
        let button = NSButton(image: configuredImage, target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.controlSize = .small
        button.contentTintColor = AppPalette.secondaryText
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    @objc private func chooseRoot(_ sender: Any?) { onChooseRoot?() }
    @objc private func refresh(_ sender: Any?) { reload() }
    @objc private func createFile(_ sender: Any?) { requestCreation(.file) }
    @objc private func createFolder(_ sender: Any?) { requestCreation(.folder) }

    private func requestCreation(_ kind: CreationKind) {
        guard let root else { return }
        let directory = entry(at: tree.selectedRow).map {
            $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent()
        }
        onCreateEntry?(kind, directory ?? root.url)
    }

    @objc private func openClickedEntry(_ sender: Any?) {
        openEntry(at: tree.clickedRow)
    }

    private func contextMenu(for row: Int) -> NSMenu {
        let menu = NSMenu()
        if let entry = entry(at: row) {
            if entry.kind == .latex, onSetMainFile != nil {
                let main = menu.addItem(withTitle: "Set as Main Document", action: #selector(setMainFromMenu(_:)), keyEquivalent: "")
                main.target = self
                main.representedObject = entry.url
                main.state = isMainFile(entry) ? .on : .off
                menu.addItem(.separator())
            }
            if let parts = relativePathComponents(to: entry.url), !parts.isEmpty {
                let copy = menu.addItem(withTitle: "Copy Relative Path", action: #selector(copyRelativePath(_:)), keyEquivalent: "")
                copy.target = self
                copy.representedObject = parts.joined(separator: "/")
            }
            let reveal = menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealEntry(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = entry.url
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Refresh Files", action: #selector(refresh(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Choose Project Folder…", action: #selector(chooseRoot(_:)), keyEquivalent: "").target = self
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(refresh(_:)) { return root != nil }
        return true
    }

    @objc private func setMainFromMenu(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL {
            onSetMainFile?(url)
        }
    }

    @objc private func copyRelativePath(_ item: NSMenuItem) {
        guard let path = item.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    @objc private func revealEntry(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func isMainFile(_ entry: Entry) -> Bool {
        entry.kind == .latex && entry.url.standardizedFileURL.path == mainFile?.path
    }

    private func entry(at row: Int) -> Entry? {
        guard row >= 0 else { return nil }
        return tree.item(atRow: row) as? Entry
    }

    private func openEntry(at row: Int) {
        guard let entry = entry(at: row) else { return }
        if entry.isDirectory {
            if tree.isItemExpanded(entry) {
                tree.collapseItem(entry)
            } else {
                tree.expandItem(entry)
            }
        } else if entry.kind != nil {
            onOpenFile?(entry.url)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item as? Entry).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item as? Entry)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Entry)?.isDirectory == true
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        PaletteSelectionRow.reusable(in: outlineView)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let entry = item as? Entry else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ProjectEntryCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? FileTreeCell ?? FileTreeCell()
        cell.identifier = identifier
        let name = entry.url.lastPathComponent
        let main = isMainFile(entry)
        let label = main ? "\(name) (Main Document)" : name
        cell.textField?.stringValue = name
        cell.textField?.font = .systemFont(ofSize: 13, weight: main ? .semibold : .regular)
        cell.needsLayout = true
        cell.setAccessibilityLabel(label)
        let symbol = main ? "doc.text.fill" : (entry.isDirectory ? "folder" : entry.kind?.symbol ?? "doc")
        cell.setIcon(symbol, tint: main ? AppPalette.accent : AppPalette.secondaryText)
        return cell
    }
}

@MainActor
private final class FileOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    var contextMenuForRow: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return contextMenuForRow?(row(at: point)) ?? super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76, selectedRow >= 0 {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class FileTreeCell: SidebarTextCell {
    init() {
        super.init(frame: .zero)
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        let label = NSTextField(labelWithString: "")
        label.textColor = AppPalette.text
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for child in [icon, label] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func setIcon(_ symbol: String, tint: NSColor) {
        imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imageView?.contentTintColor = tint
    }
}
