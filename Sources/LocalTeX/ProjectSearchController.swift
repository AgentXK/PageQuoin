import AppKit

@MainActor
final class ProjectSearchController: NSWindowController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum Mode {
        case text([URL: String])
        case files([URL])

        var isFileSearch: Bool {
            if case .files = self { return true }
            return false
        }
    }

    private let root: URL
    private let mode: Mode
    private let searchField = NSSearchField()
    private let replacementField = NSTextField()
    private let replaceToggle = NSButton(checkboxWithTitle: "Replace", target: nil, action: nil)
    private let selectFilesButton = NSButton(title: "Select All Files", target: nil, action: nil)
    private let replacementRow = NSStackView()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "Enter text to search")
    private let navigateButton = NSButton(title: "Go to Match", target: nil, action: nil)
    private var searchTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    private var catalog: ProjectFileCatalog?
    private var results: [ProjectSearchResult] = []
    private var selectedResult: ProjectSearchResult?
    private var replacementFiles: [ProjectReplacementFile] = []
    private var checkedFiles: Set<URL> = []
    private var replacementIsLimited = false
    private var isApplyingReplacement = false

    private var showsReplacement: Bool { !mode.isFileSearch && replaceToggle.state == .on }

    var openSourcesProvider: (() -> [URL: String])?
    var onNavigate: ((URL, NSRange) -> Void)?
    var onOpenFile: ((URL) -> Void)?

    convenience init(root: URL, openSources: [URL: String]) {
        self.init(root: root, mode: .text(openSources))
    }

    convenience init(root: URL, openFiles: [URL]) {
        self.init(root: root, mode: .files(openFiles))
    }

    private init(root: URL, mode: Mode) {
        self.root = root
        self.mode = mode
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 402),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init(window: sheet)
        installContent(in: sheet)
    }

    required init?(coder: NSCoder) { nil }

    func show(attachedTo parent: NSWindow) {
        guard let window, window.sheetParent == nil, parent.attachedSheet == nil else { return }
        parent.beginSheet(window) { [weak self] response in
            guard let self else { return }
            searchTask?.cancel()
            catalogTask?.cancel()
            let result = selectedResult
            selectedResult = nil
            if response == .OK, let result {
                DispatchQueue.main.async { [weak self] in
                    switch result {
                    case let .text(match): self?.onNavigate?(match.url, match.range)
                    case let .file(entry): self?.onOpenFile?(entry.url)
                    case .replacementFile: break
                    }
                }
            }
        }
        if case let .files(openFiles) = mode { loadFileCatalog(openFiles: openFiles) }
    }

    @objc func dismiss() {
        guard !isApplyingReplacement else { return }
        searchTask?.cancel()
        catalogTask?.cancel()
        if let window, let parent = window.sheetParent {
            parent.endSheet(window, returnCode: .cancel)
        }
    }

    private func installContent(in window: NSWindow) {
        window.title = mode.isFileSearch ? "Quick Open" : "Find in Project"
        window.backgroundColor = AppPalette.window
        let content = NSView()
        window.contentView = content

        searchField.placeholderString = mode.isFileSearch ? "Type a file name or path" : "Search text files in this project"
        searchField.setAccessibilityLabel(mode.isFileSearch ? "File name or path" : "Search project")
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(queryChanged(_:))
        searchField.delegate = self
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        window.initialFirstResponder = searchField

        let inputControls = NSStackView()
        inputControls.orientation = .vertical
        inputControls.alignment = .leading
        inputControls.spacing = 8
        inputControls.detachesHiddenViews = true
        let searchRow = NSStackView(views: [searchField])
        searchRow.alignment = .centerY
        searchRow.spacing = 10
        inputControls.addArrangedSubview(searchRow)
        searchRow.widthAnchor.constraint(equalTo: inputControls.widthAnchor).isActive = true
        if !mode.isFileSearch {
            replaceToggle.target = self
            replaceToggle.action = #selector(toggleReplacement(_:))
            replaceToggle.setAccessibilityIdentifier("ProjectReplaceToggle")
            searchRow.addArrangedSubview(replaceToggle)
            replacementField.placeholderString = "Replace with (leave empty to remove matches)"
            replacementField.setAccessibilityLabel("Replacement text")
            replacementField.setAccessibilityIdentifier("ProjectReplacementText")
            replacementField.delegate = self
            replacementField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            selectFilesButton.target = self
            selectFilesButton.action = #selector(toggleAllFiles(_:))
            selectFilesButton.isEnabled = false
            replacementRow.alignment = .centerY
            replacementRow.spacing = 10
            replacementRow.addArrangedSubview(replacementField)
            replacementRow.addArrangedSubview(selectFilesButton)
            inputControls.addArrangedSubview(replacementRow)
            replacementRow.widthAnchor.constraint(equalTo: inputControls.widthAnchor).isActive = true
            replacementRow.isHidden = true
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Match"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.style = mode.isFileSearch ? .plain : .inset
        table.backgroundColor = AppPalette.editor
        table.rowHeight = 41
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(navigate(_:))
        table.setAccessibilityLabel(mode.isFileSearch ? "Matching files" : "Search results")
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.backgroundColor = AppPalette.editor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table

        status.font = .systemFont(ofSize: 11)
        status.textColor = AppPalette.secondaryText
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(dismiss))
        cancel.keyEquivalent = "\u{1b}"
        if mode.isFileSearch { navigateButton.title = "Open" }
        navigateButton.target = self
        navigateButton.action = #selector(navigate(_:))
        navigateButton.keyEquivalent = "\r"
        navigateButton.isEnabled = false

        for child in [inputControls, scroll, status, cancel, navigateButton] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
        }
        NSLayoutConstraint.activate([
            inputControls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            inputControls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            inputControls.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: inputControls.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: inputControls.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: inputControls.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: navigateButton.topAnchor, constant: -14),
            status.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            status.centerYAnchor.constraint(equalTo: navigateButton.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: cancel.leadingAnchor, constant: -12),
            cancel.trailingAnchor.constraint(equalTo: navigateButton.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: navigateButton.centerYAnchor),
            navigateButton.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            navigateButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        window.setContentSize(NSSize(width: 620, height: 402))
    }

    @objc private func queryChanged(_ sender: NSSearchField) {
        switch mode {
        case let .text(openSources): searchText(sender.stringValue, openSources: openSources)
        case .files: searchFileNames(sender.stringValue)
        }
    }

    @objc private func toggleReplacement(_ sender: Any?) {
        replacementRow.isHidden = !showsReplacement
        navigateButton.title = showsReplacement ? "Replace Checked Files…" : "Go to Match"
        navigateButton.keyEquivalent = showsReplacement ? "" : "\r"
        queryChanged(searchField)
    }

    private func searchText(_ query: String, openSources: [URL: String]) {
        searchTask?.cancel()
        checkedFiles.removeAll()
        replacementFiles.removeAll()
        replacementIsLimited = false
        replaceResults([])
        status.toolTip = nil
        guard !query.isEmpty else {
            status.stringValue = "Enter text to search"
            return
        }
        status.stringValue = "Searching…"
        let root = root
        let sources = openSourcesProvider?() ?? openSources
        let replacement = showsReplacement ? replacementField.stringValue : nil
        if let replacement, replacement.utf8.count > ProjectReplacementFile.fileSizeLimit {
            status.stringValue = "Replacement text is too large"
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let work = Task.detached(priority: .userInitiated) {
                ProjectSearch.find(query: query, root: root, openSources: sources, replacement: replacement)
            }
            let batch = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled else { return }
            self?.showResults(batch)
        }
    }

    private func showResults(_ batch: ProjectSearch.Batch) {
        replacementFiles = batch.replacementFiles
        replacementIsLimited = batch.limited
        if showsReplacement {
            let grouped = Dictionary(grouping: batch.matches, by: \.url)
            replaceResults(replacementFiles.flatMap { file in
                [.replacementFile(file)] + (grouped[file.url] ?? []).map(ProjectSearchResult.text)
            })
        } else {
            replaceResults(batch.matches.map(ProjectSearchResult.text))
        }
        if batch.inaccessible {
            status.stringValue = "Could not read the project folder"
            return
        }
        let count = batch.matches.count
        let matches = count == 1 ? "1 match" : "\(count) matches"
        if showsReplacement && batch.limited {
            status.stringValue = "Too many matches to replace. Narrow the search."
            return
        }
        let summary = batch.limited ? "Showing the first \(matches)" : matches
        let skipped = batch.skippedFiles
        status.stringValue = skipped == 0 ? summary : "\(summary) · \(skipped) files skipped"
        if skipped > 0 { status.toolTip = "Some files were too large or could not be read." }
    }

    private func loadFileCatalog(openFiles: [URL]) {
        catalogTask?.cancel()
        catalog = nil
        replaceResults([])
        status.stringValue = "Finding project files…"
        let root = root
        catalogTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                ProjectFileCatalog.load(root: root, openFiles: openFiles)
            }
            let catalog = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            self.catalog = catalog
            searchFileNames(searchField.stringValue)
        }
    }

    private func searchFileNames(_ query: String) {
        searchTask?.cancel()
        replaceResults([])
        guard let catalog else { return }
        guard !catalog.inaccessible else {
            status.stringValue = "Could not read the project folder"
            return
        }
        status.stringValue = "Searching…"
        searchTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { catalog.search(query) }
            let batch = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            replaceResults(batch.entries.map(ProjectSearchResult.file))
            let count = batch.total == 1 ? "1 file" : "\(batch.total) files"
            let summary = batch.entries.count < batch.total ? "Showing \(batch.entries.count) of \(count)" : count
            status.stringValue = catalog.limited ? summary + " · Project scan limit reached" : summary
        }
    }

    private func replaceResults(_ updatedResults: [ProjectSearchResult]) {
        results = updatedResults
        table.reloadData()
        if !results.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        updateActions()
    }

    @objc private func navigate(_ sender: Any?) {
        if showsReplacement, sender as? NSButton === navigateButton {
            confirmReplacement()
            return
        }
        let row = sender as? NSTableView === table && table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard results.indices.contains(row), let window, let parent = window.sheetParent else { return }
        if case let .replacementFile(file) = results[row] {
            setChecked(!checkedFiles.contains(file.url), for: file.url)
            table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            return
        }
        selectedResult = results[row]
        parent.endSheet(window, returnCode: .OK)
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === replacementField { queryChanged(searchField) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)) where showsReplacement:
            queryChanged(searchField)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            navigate(control)
            return true
        case #selector(NSResponder.cancelOperation(_:)) where mode.isFileSearch:
            dismiss()
            return true
        case #selector(NSResponder.moveUp(_:)) where mode.isFileSearch && !results.isEmpty:
            moveFileSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)) where mode.isFileSearch && !results.isEmpty:
            moveFileSelection(by: 1)
            return true
        case #selector(NSResponder.moveDown(_:)) where !results.isEmpty:
            window?.makeFirstResponder(table)
            return true
        default:
            return false
        }
    }

    private func moveFileSelection(by offset: Int) {
        let row = min(max(table.selectedRow + offset, 0), results.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActions()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteSelectionRow.reusable(in: tableView)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if case let .replacementFile(file) = results[row] {
            let identifier = NSUserInterfaceItemIdentifier("ReplacementFileCell")
            let cell = table.makeView(withIdentifier: identifier, owner: self) as? ReplacementFileCell ?? ReplacementFileCell()
            cell.identifier = identifier
            cell.update(file, checked: checkedFiles.contains(file.url), enabled: !replacementIsLimited && !isApplyingReplacement)
            cell.onToggle = { [weak self] checked in self?.setChecked(checked, for: file.url) }
            return cell
        }
        let identifier = NSUserInterfaceItemIdentifier("SearchMatchCell")
        let cell = table.makeView(withIdentifier: identifier, owner: self) as? SearchMatchCell ?? SearchMatchCell()
        cell.identifier = identifier
        cell.update(results[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch results[row] {
        case .replacementFile: 30
        case let .text(match) where match.after != nil: 57
        default: tableView.rowHeight
        }
    }

    private func setChecked(_ checked: Bool, for url: URL) {
        if checked { checkedFiles.insert(url) }
        else { checkedFiles.remove(url) }
        updateActions()
    }

    @objc private func toggleAllFiles(_ sender: Any?) {
        if checkedFiles.count == replacementFiles.count { checkedFiles.removeAll() }
        else { checkedFiles = Set(replacementFiles.map(\.url)) }
        table.reloadData()
        updateActions()
    }

    private func updateActions() {
        if showsReplacement {
            navigateButton.isEnabled = !checkedFiles.isEmpty && !replacementIsLimited && !isApplyingReplacement
            selectFilesButton.isEnabled = !replacementFiles.isEmpty && !replacementIsLimited && !isApplyingReplacement
            selectFilesButton.title = !checkedFiles.isEmpty && checkedFiles.count == replacementFiles.count
                ? "Deselect All Files" : "Select All Files"
        } else {
            navigateButton.isEnabled = results.indices.contains(table.selectedRow)
        }
    }

    private func confirmReplacement() {
        guard !isApplyingReplacement, !replacementIsLimited, !checkedFiles.isEmpty, let window else { return }
        let files = replacementFiles.filter { checkedFiles.contains($0.url) }
        let matchCount = files.reduce(0) { $0 + $1.ranges.count }
        let replacement = replacementField.stringValue
        guard replacement.utf8.count * matchCount <= 16 * 1024 * 1024 else {
            status.stringValue = "This replacement is too large. Select fewer files."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Replace \(matchCount) \(matchCount == 1 ? "match" : "matches") in \(files.count) \(files.count == 1 ? "file" : "files")?"
        alert.informativeText = "Open tabs receive an undoable edit. Closed files are updated on disk. Files changed since the preview are skipped."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        isApplyingReplacement = true
        updateActions()
        table.reloadData()
        Task {
            if await alert.beginSheetModal(for: window) == .alertFirstButtonReturn {
                await applyReplacement(files, replacement: replacement)
            }
            isApplyingReplacement = false
            table.reloadData()
            updateActions()
        }
    }

    private func applyReplacement(_ files: [ProjectReplacementFile], replacement: String) async {
        searchField.isEnabled = false
        replaceToggle.isEnabled = false
        replacementField.isEnabled = false
        status.stringValue = "Replacing…"
        defer {
            searchField.isEnabled = true
            replaceToggle.isEnabled = true
            replacementField.isEnabled = true
        }

        let root = ProjectHistory.normalized(root)
        var matchCount = 0
        var updatedCount = 0
        var wroteClosedFile = false
        var skipped: [String] = []
        for file in files {
            do {
                if let document = openDocument(at: file.url) {
                    guard !document.isSavingDocument else { throw ReplacementError.editorUnavailable }
                    _ = try file.validateDisk(in: root)
                    let documentURL = document.fileURL ?? file.url
                    let diskMatches = document.diskBaseline(at: documentURL).map {
                        $0.digest == file.version.digest && $0.version.matchesFileMetadata(of: file.version.disk)
                    } ?? (document.fileModificationDate == file.version.disk.modificationDate)
                    guard diskMatches,
                          ProjectReplacementFile.sourceDigest(document.source) == file.sourceDigest else {
                        throw ReplacementError.changed
                    }
                    guard document.workspace?.applyProjectReplacement(file, replacement: replacement) == true else {
                        throw ReplacementError.editorUnavailable
                    }
                } else {
                    try file.write(toClosedFileIn: root, replacement: replacement)
                    wroteClosedFile = true
                }
                updatedCount += 1
                matchCount += file.ranges.count
            } catch {
                skipped.append("\(file.path) — \(error.localizedDescription)")
            }
            await Task.yield()
        }
        if wroteClosedFile { ProjectBuildSession.sourcesDidChange(in: root) }
        checkedFiles.removeAll()
        replacementFiles.removeAll()
        replaceResults([])
        let summary = "Replaced \(matchCount) \(matchCount == 1 ? "match" : "matches") in \(updatedCount) \(updatedCount == 1 ? "file" : "files")"
        status.stringValue = skipped.isEmpty ? summary : "\(summary) · \(skipped.count) skipped"
        status.toolTip = ([status.stringValue] + skipped + ["Press Return in the search field to refresh the preview."])
            .joined(separator: "\n")
        if !skipped.isEmpty, let window {
            let alert = NSAlert()
            alert.messageText = status.stringValue
            alert.informativeText = skipped.prefix(5).joined(separator: "\n\n")
            if skipped.count > 5 { alert.informativeText += "\n\nHover over the result summary to review all skipped files." }
            alert.addButton(withTitle: "OK")
            _ = await alert.beginSheetModal(for: window)
        }
    }

    private func openDocument(at url: URL) -> TeXDocument? {
        NSDocumentController.shared.documents.lazy.compactMap { $0 as? TeXDocument }.first {
            $0.fileURL.map(ProjectHistory.normalized)?.path == url.path
        }
    }
}

private enum ProjectSearchResult {
    case text(ProjectMatch)
    case file(ProjectFileCatalog.Entry)
    case replacementFile(ProjectReplacementFile)
}

private struct ProjectFileCatalog: Sendable {
    struct Entry: Sendable {
        let url: URL
        let path: String
        let symbol: String
        let foldedName: String
        let foldedPath: String

        init(url: URL, relativeTo root: URL, kind: ProjectFileKind) {
            self.url = url
            path = url.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
            symbol = kind.symbol
            foldedName = Self.fold(url.lastPathComponent)
            foldedPath = Self.fold(path)
        }

        static func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        }
    }

    private static let scanLimit = 20_000
    private static let resultLimit = 200
    private var entries: [Entry] = []
    private(set) var limited = false
    private(set) var inaccessible = false

    static func load(root: URL, openFiles: [URL]) -> Self {
        let root = ProjectHistory.normalized(root)
        let manager = FileManager.default
        var catalog = Self()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard manager.isReadableFile(atPath: root.path),
              let listing = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                errorHandler: { _, _ in true }) else {
            catalog.inaccessible = true
            return catalog
        }

        var seen = Set<String>()
        for open in openFiles {
            guard let url = ProjectHistory.projectFile(open, in: root),
                  let kind = ProjectFileKind.detect(for: url), seen.insert(url.path).inserted else { continue }
            catalog.entries.append(Entry(url: url, relativeTo: root, kind: kind))
        }

        var otherEntries: [Entry] = []
        for (index, item) in listing.enumerated() {
            guard !Task.isCancelled else { return Self() }
            if index == scanLimit {
                catalog.limited = true
                break
            }
            guard let file = item as? URL, let attributes = try? file.resourceValues(forKeys: keys),
                  attributes.isRegularFile == true, attributes.isSymbolicLink != true else { continue }
            let url = file.standardizedFileURL
            guard let kind = ProjectFileKind.detect(for: url), seen.insert(url.path).inserted else { continue }
            otherEntries.append(Entry(url: url, relativeTo: root, kind: kind))
        }
        otherEntries.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        catalog.entries.append(contentsOf: otherEntries)
        return catalog
    }

    func search(_ query: String) -> (entries: [Entry], total: Int) {
        let query = Entry.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return (Array(entries.prefix(Self.resultLimit)), entries.count) }
        let words = query.split(whereSeparator: \.isWhitespace)
        var ordered = Array(repeating: [Entry](), count: 6)
        var total = 0
        for entry in entries {
            guard !Task.isCancelled else { return ([], 0) }
            let priority: Int
            if entry.foldedName == query { priority = 0 }
            else if entry.foldedName.hasPrefix(query) { priority = 1 }
            else if entry.foldedName.contains(query) { priority = 2 }
            else if entry.foldedPath.hasPrefix(query) { priority = 3 }
            else if entry.foldedPath.contains(query) { priority = 4 }
            else if words.count > 1, words.allSatisfy({ entry.foldedPath.contains($0) }) { priority = 5 }
            else { continue }
            total += 1
            if ordered[priority].count < Self.resultLimit { ordered[priority].append(entry) }
        }
        return (Array(ordered.joined().prefix(Self.resultLimit)), total)
    }
}

private struct ProjectMatch: Sendable {
    let url: URL
    let path: String
    let line: Int
    let preview: String
    let after: String?
    let range: NSRange
}

private enum ProjectSearch {
    struct Batch: Sendable {
        var matches: [ProjectMatch] = []
        var replacementFiles: [ProjectReplacementFile] = []
        var skippedFiles = 0
        var limited = false
        var inaccessible = false
    }

    private static let resultLimit = 200
    private static let replacementLimit = 2_000
    private static let fileSizeLimit = ProjectReplacementFile.fileSizeLimit

    static func find(query: String, root: URL, openSources: [URL: String], replacement: String?) -> Batch {
        var batch = Batch()
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard !query.isEmpty else { return batch }
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue, FileManager.default.isReadableFile(atPath: root.path) else {
            batch.inaccessible = true
            return batch
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let listing = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                            errorHandler: { _, _ in true }) else {
            batch.inaccessible = true
            return batch
        }
        var snapshots: [String: String] = [:]
        for (url, source) in openSources {
            snapshots[url.resolvingSymlinksInPath().standardizedFileURL.path] = source
        }
        let rootDepth = root.pathComponents.count
        for case let file as URL in listing {
            guard !Task.isCancelled else { break }
            guard let info = try? file.resourceValues(forKeys: keys),
                  info.isRegularFile == true, info.isSymbolicLink != true,
                  ProjectFileKind.detect(for: file)?.isEditable == true else { continue }
            let file = file.standardizedFileURL
            let source: String?
            let version: ProjectReplacementFile.Version?
            if replacement != nil {
                guard let (data, state) = try? ProjectReplacementFile.read(file, in: root),
                      let decoded = ProjectTextEncoding.decode(data) else {
                    batch.skippedFiles += 1
                    continue
                }
                let text = snapshots[file.path] ?? decoded.text
                source = text.utf8.count <= fileSizeLimit ? text : nil
                version = state
            } else if let snapshot = snapshots[file.path] {
                source = snapshot.utf8.count <= fileSizeLimit ? snapshot : nil
                version = nil
            } else if let size = info.fileSize, size <= fileSizeLimit {
                source = read(file)
                version = nil
            } else {
                source = nil
                version = nil
            }
            guard let source else {
                batch.skippedFiles += 1
                continue
            }
            let path = file.pathComponents.dropFirst(rootDepth).joined(separator: "/")
            let start = batch.matches.endIndex
            collectMatches(in: source as NSString, query: query, replacement: replacement, file: file, path: path,
                           batch: &batch)
            if let version, start < batch.matches.endIndex {
                batch.replacementFiles.append(ProjectReplacementFile(url: file, path: path, version: version,
                    sourceDigest: ProjectReplacementFile.sourceDigest(source), ranges: batch.matches[start...].map(\.range)))
            }
            if batch.limited { break }
        }
        batch.matches.sort { a, b in
            if a.path == b.path { return a.range.location < b.range.location }
            return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
        batch.replacementFiles.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return batch
    }

    private static func read(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              data.count <= fileSizeLimit else { return nil }
        return ProjectTextEncoding.decode(data)?.text
    }

    private static func collectMatches(in source: NSString, query: String, replacement: String?, file: URL,
                                       path: String, batch: inout Batch) {
        var offset = 0
        var line = 0
        var lineStart = 0
        var nextLine = 0
        var lineTextEnd = 0
        let limit = replacement == nil ? resultLimit : replacementLimit
        let previewReplacement = replacement.map { text in
            let preview = String(text.prefix(88))
            return preview == text ? preview : preview + "…"
        }
        while offset < source.length && !Task.isCancelled {
            let remaining = NSRange(location: offset, length: source.length - offset)
            let match = source.range(of: query, options: .caseInsensitive, range: remaining)
            guard match.location != NSNotFound, match.length > 0 else { break }
            offset = NSMaxRange(match)
            if let replacement, replacement.utf8.elementsEqual(source.substring(with: match).utf8) { continue }
            if batch.matches.count == limit {
                batch.limited = true
                break
            }
            while nextLine <= match.location {
                source.getLineStart(&lineStart, end: &nextLine, contentsEnd: &lineTextEnd,
                                    for: NSRange(location: nextLine, length: 0))
                line += 1
            }
            let start = max(lineStart, match.location - 40)
            let end = min(lineTextEnd, match.location + min(match.length, 90) + 60)
            let range = source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: max(0, end - start)))
            let leading = start > lineStart ? "…" : ""
            let trailing = end < lineTextEnd ? "…" : ""
            let preview = leading + source.substring(with: range) + trailing
            let after = previewReplacement.map { replacement in
                let before = source.substring(with: NSRange(location: range.location, length: max(0, match.location - range.location)))
                let tailStart = min(offset, NSMaxRange(range))
                let tail = source.substring(with: NSRange(location: tailStart, length: NSMaxRange(range) - tailStart))
                return leading + before + replacement + tail + trailing
            }
            batch.matches.append(ProjectMatch(url: file, path: path, line: line, preview: preview, after: after, range: match))
        }
    }
}

@MainActor
private final class SearchMatchCell: NSTableCellView {
    private let path = NSTextField(labelWithString: "")
    private let snippet = NSTextField(labelWithString: "")
    private let replacementSnippet = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private lazy var labelLeading = path.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
    private lazy var labelTop = path.topAnchor.constraint(equalTo: topAnchor, constant: 4)

    init() {
        super.init(frame: .zero)
        path.font = .systemFont(ofSize: 11, weight: .semibold)
        path.textColor = AppPalette.text
        snippet.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        snippet.textColor = AppPalette.text
        replacementSnippet.font = snippet.font
        replacementSnippet.textColor = AppPalette.success
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = AppPalette.secondaryText
        icon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        addSubview(icon)
        for label in [path, snippet, replacementSnippet] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 19),
            icon.heightAnchor.constraint(equalToConstant: 19),
            labelLeading,
            path.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            labelTop,
            snippet.leadingAnchor.constraint(equalTo: path.leadingAnchor),
            snippet.trailingAnchor.constraint(equalTo: path.trailingAnchor),
            snippet.topAnchor.constraint(equalTo: path.bottomAnchor, constant: 2),
            replacementSnippet.leadingAnchor.constraint(equalTo: path.leadingAnchor),
            replacementSnippet.trailingAnchor.constraint(equalTo: path.trailingAnchor),
            replacementSnippet.topAnchor.constraint(equalTo: snippet.bottomAnchor, constant: 2)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(_ result: ProjectSearchResult) {
        switch result {
        case let .text(match):
            icon.isHidden = true
            replacementSnippet.isHidden = match.after == nil
            labelLeading.constant = 8
            labelTop.constant = 4
            path.stringValue = "\(match.path):\(match.line)"
            snippet.textColor = match.after == nil ? AppPalette.text : AppPalette.error
            snippet.stringValue = match.after == nil ? match.preview : "− " + match.preview
            replacementSnippet.stringValue = match.after.map { "+ " + $0 } ?? ""
            let description = [path.stringValue, snippet.stringValue, replacementSnippet.stringValue].filter { !$0.isEmpty }
            toolTip = description.joined(separator: "\n")
            setAccessibilityLabel(description.joined(separator: ", "))
        case let .file(entry):
            icon.isHidden = false
            replacementSnippet.isHidden = true
            icon.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
            labelLeading.constant = 36
            let name = entry.url.lastPathComponent
            let isNested = entry.path != name
            labelTop.constant = isNested ? 4 : 12
            path.font = .systemFont(ofSize: 12, weight: .semibold)
            path.stringValue = name
            snippet.font = .systemFont(ofSize: 11)
            snippet.lineBreakMode = .byTruncatingMiddle
            snippet.stringValue = isNested ? entry.path : ""
            toolTip = entry.path
            setAccessibilityLabel(entry.path)
        case .replacementFile:
            break
        }
    }
}

@MainActor
private final class ReplacementFileCell: NSTableCellView {
    private lazy var checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
    var onToggle: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        checkbox.font = .systemFont(ofSize: 12, weight: .medium)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(_ file: ProjectReplacementFile, checked: Bool, enabled: Bool) {
        let count = file.ranges.count
        checkbox.title = "\(file.path) · \(count) \(count == 1 ? "match" : "matches")"
        checkbox.state = checked ? .on : .off
        checkbox.isEnabled = enabled
        checkbox.toolTip = file.path
    }

    @objc private func toggle(_ sender: NSButton) { onToggle?(sender.state == .on) }
}
