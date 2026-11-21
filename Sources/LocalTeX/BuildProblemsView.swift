import AppKit

@MainActor
final class BuildProblemsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = BuildProblemsTable()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var diagnostics: [BuildDiagnostic] = []
    var onNavigate: ((BuildDiagnostic.Source) -> Void)?
    var hasFocus: Bool { window?.firstResponder === table }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Problem"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = AppPalette.editor
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.rowHeight = 38
        table.style = .plain
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(openClickedProblem(_:))
        table.openSelected = { [weak self] row in self?.open(row) }
        table.setAccessibilityLabel("Build Problems")
        table.setAccessibilityIdentifier("BuildProblems")

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = AppPalette.editor
        scroll.documentView = table
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = AppPalette.secondaryText
        for child in [scroll, emptyLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(_ issues: [BuildDiagnostic], emptyMessage: String) {
        emptyLabel.stringValue = emptyMessage
        emptyLabel.isHidden = !issues.isEmpty
        guard issues != diagnostics else { return }
        diagnostics = issues
        table.reloadData()
        if !issues.isEmpty { table.scrollRowToVisible(0) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { diagnostics.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("BuildProblem")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? BuildProblemCell ?? BuildProblemCell()
        cell.identifier = identifier
        cell.update(diagnostics[row])
        return cell
    }

    @objc private func openClickedProblem(_ sender: NSTableView) {
        open(sender.clickedRow)
    }

    private func open(_ row: Int) {
        guard diagnostics.indices.contains(row), let source = diagnostics[row].source else { return }
        onNavigate?(source)
    }
}

@MainActor
private final class BuildProblemsTable: NSTableView {
    var openSelected: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        if selectedRow >= 0, event.keyCode == 36 || event.keyCode == 76 {
            openSelected?(selectedRow)
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class BuildProblemCell: NSTableCellView {
    private let icon = NSImageView()
    private let message = NSTextField(labelWithString: "")
    private let location = NSTextField(labelWithString: "")
    private let disclosure = NSImageView()

    init() {
        super.init(frame: .zero)
        message.font = .systemFont(ofSize: 12, weight: .medium)
        message.textColor = AppPalette.text
        message.lineBreakMode = .byTruncatingTail
        location.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        location.textColor = AppPalette.secondaryText
        location.lineBreakMode = .byTruncatingMiddle

        let text = NSStackView(views: [message, location])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.detachesHiddenViews = true
        disclosure.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        disclosure.contentTintColor = AppPalette.accent
        for child in [icon, text, disclosure] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: disclosure.leadingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
            location.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
            disclosure.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 10),
            disclosure.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(_ issue: BuildDiagnostic) {
        let error = issue.severity == .error
        let title = error ? "Error" : "Warning"
        icon.image = NSImage(systemSymbolName: error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill",
                             accessibilityDescription: title)?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        icon.contentTintColor = error ? AppPalette.error : AppPalette.warning
        message.stringValue = issue.message
        location.stringValue = issue.location ?? ""
        location.isHidden = issue.location == nil
        disclosure.isHidden = issue.source == nil
        toolTip = [issue.message, issue.location].compactMap { $0 }.joined(separator: "\n")
        setAccessibilityLabel([title, issue.message, issue.location].compactMap { $0 }.joined(separator: ", "))
    }
}
