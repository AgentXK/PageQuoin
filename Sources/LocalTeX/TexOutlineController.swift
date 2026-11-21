import AppKit

@MainActor
final class TexOutlineController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private struct HeadingKey: Hashable {
        let title: String
        let level: Int
        let file: URL?
    }

    private struct ItemID: Hashable {
        let heading: HeadingKey
        let occurrence: Int
    }

    private final class Item {
        let heading: TeXOutlineHeading
        let id: ItemID
        var children: [Item] = []

        init(heading: TeXOutlineHeading, id: ItemID) {
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
    private var displayedHeadings: [TeXOutlineHeading]?
    private var updateTask: Task<Void, Never>?

    var onNavigate: ((TeXOutlineHeading) -> Void)?

    deinit { updateTask?.cancel() }

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
        outline.setAccessibilityLabel("Project outline")

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

    func update(source: @escaping () -> ProjectOutline?) {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            let snapshot = source()
            let worker = Task.detached(priority: .utility) { snapshot?.headings() ?? [] }
            let headings = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            self.updateTask = nil
            guard self.displayedHeadings != headings else { return }
            self.displayedHeadings = headings
            self.reload(headings)
        }
    }

    private func reload(_ headings: [TeXOutlineHeading]) {
        _ = view
        let selected: Item? = outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? Item : nil
        var occurrences: [HeadingKey: Int] = [:]
        var ancestors: [Item] = []
        var items: [Item] = []
        roots.removeAll()
        for heading in headings {
            let key = HeadingKey(title: heading.title, level: heading.level, file: heading.file)
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
        onNavigate?(item.heading)
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
        cell.textField?.toolTip = item.heading.file.map { "\(item.heading.title)\n\($0.lastPathComponent)" }
        cell.needsLayout = true
        return cell
    }
}
