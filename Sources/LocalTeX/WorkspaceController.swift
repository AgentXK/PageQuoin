import AppKit
import PDFKit
import UniformTypeIdentifiers

enum WorkspaceLayout {
    case split
    case editorOnly
    case pdfOnly
}

@MainActor
final class WorkspaceController: NSViewController {
    struct SidebarLayout {
        var width: CGFloat?
        var isCollapsed: Bool
    }

    private weak var document: TeXDocument?
    private let emptyTabs: DocumentTabGroup?
    private let editor = SourceEditorController()
    private let fileTree = FileTreeController()
    private let outline = TexOutlineController()
    private let tabStrip = FileTabStrip()
    private let split = WorkspaceSplitViewController()
    private let columns = WorkspaceSplitViewController()
    private let sidebar = WorkspaceSplitViewController(isVertical: false)
    private lazy var sidebarItem = NSSplitViewItem(viewController: FrostedSidebarController(content: sidebar))
    private var lastSidebarWidth: CGFloat?
    private lazy var projectButton = WorkspaceToolbarButton(title: AppIdentity.displayName, symbol: "folder",
        showsChevron: true, target: self, action: #selector(showProjectMenu(_:)))
    private lazy var searchButton = WorkspaceToolbarButton(title: "Search Project", symbol: "magnifyingglass",
        restingBackground: true, target: self, action: #selector(showProjectSearch(_:)))
    private lazy var logButton = WorkspaceToolbarButton(symbol: "list.bullet.rectangle",
        target: self, action: #selector(toggleLog(_:)))
    private let pdfView = PreviewPDFView()
    private lazy var pdfPageNavigator = PDFPageNavigator(pdfView: pdfView)
    private let previewPlaceholder = NSView()
    private let compileButton = PreviewCompileButton()
    private lazy var sourceJumpButton = WorkspaceToolbarButton(symbol: "arrow.right", restingBackground: true,
        target: self, action: #selector(showSourceInPDF(_:)))
    private var sourceJumpDividerConstraint: NSLayoutConstraint?
    private var splitEditorFraction: CGFloat?
    private let zoomLabel = NSTextField(labelWithString: "—")
    private let zoomInButton = NSButton()
    private let zoomOutButton = NSButton()
    private let fitButton = NSButton()
    private let logView = NSTextView()
    private let logPanel = NSView()
    private let errorButton = NSButton()
    private let statusImage = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var logHeight: NSLayoutConstraint?
    private var logHeaderHeight: NSLayoutConstraint?
    private var projectFolder: URL?
    private var fileURLObservation: NSKeyValueObservation?
    private var buildSession: ProjectBuildSession?
    private var projectSearch: ProjectSearchController?
    private var autosaveWarning: String?
    private var isCreatingProjectEntry = false
    private var isCleaningBuildFiles = false

    private(set) var workspaceLayout: WorkspaceLayout = .split
    var hasBuildTarget: Bool { buildSession != nil }
    var canCompile: Bool { hasBuildTarget && buildSession?.phase != .building }
    var canShowSourceInPDF: Bool { sourcePreviewLocation() != nil }
    var canCleanBuildFiles: Bool {
        !isCleaningBuildFiles && (buildFilesDirectory != nil || (projectDirectory != nil && buildSession?.phase == .building))
    }
    var buildFilesDirectory: URL? {
        projectDirectory.flatMap(TectonicCompiler.buildArtifactDirectory(in:))
    }
    var canExport: Bool { buildSession?.preview != nil }
    var canZoomIn: Bool { canExport && pdfView.canZoomIn }
    var canZoomOut: Bool { canExport && pdfView.canZoomOut }
    var isSidebarVisible: Bool { !sidebarItem.isCollapsed }
    var isAutoCompiling: Bool { buildSession?.automatic == true }
    var canSearchProject: Bool { fileTreeRoot != nil }
    var projectDirectory: URL? { fileTreeRoot }
    var documentURL: URL? { document?.fileURL }
    var documentTabs: DocumentTabGroup? { document?.tabs ?? emptyTabs }
    var projectTabDocumentURLs: [URL] { documentTabs?.documents.compactMap(\.fileURL) ?? [] }
    var hasActiveDocument: Bool { document != nil }
    var canEditSource: Bool { document?.kind.isEditable == true }
    var canUseLaTeXCommands: Bool {
        guard let document, document.kind.isEditable else { return false }
        if document.kind == .latex { return true }
        let ext = document.fileURL?.pathExtension.lowercased() ?? ""
        return ["sty", "cls", "clo", "def", "fd", "dtx", "ins"].contains(ext)
    }
    var hasMarkedText: Bool { canEditSource && editor.hasMarkedText }

    private var fileTreeRoot: URL? {
        projectFolder ?? document?.fileURL?.deletingLastPathComponent()
    }
    private var tabWorkspaces: [WorkspaceController] {
        hasActiveDocument ? documentTabs?.documents.compactMap(\.workspace) ?? [self] : [self]
    }

    init(document: TeXDocument) {
        self.document = document
        emptyTabs = nil
        super.init(nibName: nil, bundle: nil)
    }

    init(emptyTabs: DocumentTabGroup, projectDirectory: URL?) {
        self.emptyTabs = emptyTabs
        projectFolder = projectDirectory
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        view = root
        editor.usesLaTeXSyntax = canUseLaTeXCommands

        for pane in [fileTree, outline] as [NSViewController] {
            let item = NSSplitViewItem(viewController: pane)
            item.minimumThickness = 95
            sidebar.addSplitViewItem(item)
        }
        sidebarItem.minimumThickness = 208
        sidebarItem.maximumThickness = 340
        sidebarItem.preferredThicknessFraction = 0.18
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.defaultLow.rawValue + 1)
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = false
        split.addSplitViewItem(sidebarItem)
        let main = NSSplitViewItem(viewController: makeMainPane())
        main.minimumThickness = 521
        split.addSplitViewItem(main)
        addChild(split)

        let titleBar = makeTitleBar()
        let statusBar = makeStatusBar()
        for child in [titleBar, split.view, statusBar] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: root.trailingAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: root.topAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: WorkspaceTitleBar.height),
            split.view.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            split.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 28),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        editor.source = document?.source ?? ""
        outline.update(source: canUseLaTeXCommands ? editor.source : "")
        editor.onChange = { [weak self] source in
            guard let self else { return }
            document?.source = source
            if canUseLaTeXCommands { outline.update(source: source) }
            ProjectBuildSession.sourceDidChange(in: document, primary: buildSession)
        }
        outline.onNavigate = { [weak self] range in
            guard let self else { return }
            revealEditorIfNeeded()
            editor.reveal(range)
        }
        tabStrip.onSelect = { [weak self] id in self?.documentTabs?.select(id) }
        tabStrip.onClose = { [weak self] id in self?.documentTabs?.close(id) }
        fileTree.onChooseRoot = { [weak self] in self?.chooseProjectFolder() }
        fileTree.onCreateEntry = { [weak self] kind, directory in self?.createProjectEntry(kind, in: directory) }
        fileTree.onOpenFile = { [weak self] url in self?.openProjectFile(url) }
        fileTree.onSetMainFile = { [weak self] url in self?.setMainFile(url) }
        fileURLObservation = document?.observe(\.fileURL, options: [.old]) { [weak self] _, change in
            let previousURL = change.oldValue ?? nil
            Task { @MainActor in self?.documentLocationChanged(from: previousURL) }
        }
        for notification in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged] {
            NotificationCenter.default.addObserver(self, selector: #selector(previewChanged(_:)),
                                                   name: notification, object: pdfView)
        }
        updateFileTree()
        bindBuildSession()
        updatePreviewControls()
        if !hasBuildTarget { updateStandaloneStatus() }
    }

    private func makeMainPane() -> NSViewController {
        let controller = NSViewController()
        let container = NSView()
        controller.view = container
        let sourcePane = makePane(header: tabStrip, content: makeEditorContent())
        compileButton.target = self
        compileButton.action = #selector(compile(_:))
        let previewHeader = PDFPreviewHeader(compileButton: compileButton, navigator: pdfPageNavigator,
                                            zoomControls: makeZoomControls(), zoomLabel: zoomLabel)
        let previewPane = makePane(header: previewHeader, content: makePreview())
        for pane in [sourcePane, previewPane] {
            let item = NSSplitViewItem(viewController: pane)
            item.minimumThickness = 260
            item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
            columns.addSplitViewItem(item)
        }
        controller.addChild(columns)

        makeLogPanel()
        for child in [columns.view, logPanel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: container.trailingAnchor)
            ])
        }
        let logHeight = logPanel.heightAnchor.constraint(equalToConstant: 0)
        self.logHeight = logHeight
        logPanel.isHidden = true
        NSLayoutConstraint.activate([
            columns.view.topAnchor.constraint(equalTo: container.topAnchor),
            columns.view.bottomAnchor.constraint(equalTo: logPanel.topAnchor),
            logHeight,
            logPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        sourceJumpButton.toolTip = "Show in PDF (⇧⌘J)"
        sourceJumpButton.setAccessibilityLabel("Show in PDF")
        sourceJumpButton.setAccessibilityIdentifier("ShowSourceInPDF")
        sourceJumpButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sourceJumpButton)
        let sourceJumpDividerConstraint = sourceJumpButton.centerXAnchor.constraint(equalTo: previewPane.view.leadingAnchor)
        self.sourceJumpDividerConstraint = sourceJumpDividerConstraint
        NSLayoutConstraint.activate([
            sourceJumpDividerConstraint,
            sourceJumpButton.topAnchor.constraint(equalTo: columns.view.topAnchor, constant: FileTabStrip.height + 8)
        ])
        return controller
    }

    func setWorkspaceLayout(_ layout: WorkspaceLayout) {
        documentTabs?.workspaceLayout = layout
        guard workspaceLayout != layout else { return }
        _ = view
        let sourceItem = columns.splitViewItems[0]
        let previewItem = columns.splitViewItems[1]
        let divider = columns.splitView
        if workspaceLayout == .split {
            view.layoutSubtreeIfNeeded()
            let width = divider.bounds.width - divider.dividerThickness
            let editorWidth = sourceItem.viewController.view.frame.width
            if width > 0, editorWidth > 0 { splitEditorFraction = editorWidth / width }
        }
        if layout == .pdfOnly, let window = view.window, let focusedView = window.firstResponder as? NSView,
           focusedView.isDescendant(of: sourceItem.viewController.view) {
            endTypingGroup()
            window.makeFirstResponder(nil)
        }

        workspaceLayout = layout
        sourceJumpDividerConstraint?.isActive = false
        switch layout {
        case .split:
            sourceItem.isCollapsed = false
            previewItem.isCollapsed = false
            sourceJumpDividerConstraint?.isActive = true
            if let splitEditorFraction {
                view.layoutSubtreeIfNeeded()
                let desired = splitEditorFraction * (divider.bounds.width - divider.dividerThickness)
                let minimum = divider.minPossiblePositionOfDivider(at: 0)
                let maximum = divider.maxPossiblePositionOfDivider(at: 0)
                divider.setPosition(min(maximum, max(minimum, desired)), ofDividerAt: 0)
            }
        case .editorOnly:
            sourceItem.isCollapsed = false
            previewItem.isCollapsed = true
            focusEditor()
        case .pdfOnly:
            previewItem.isCollapsed = false
            sourceItem.isCollapsed = true
        }
        updateSourceJumpButton()
    }

    private func revealEditorIfNeeded() {
        if workspaceLayout == .pdfOnly { setWorkspaceLayout(.split) }
    }

    private func makeEditorContent() -> NSViewController {
        guard let document else { return makeEmptyEditor() }
        guard let data = document.mediaData else { return editor }
        return OpenedMediaController(kind: document.kind, data: data, name: document.displayName)
    }

    private func makeEmptyEditor() -> NSViewController {
        let controller = NSViewController()
        let surface = WorkspaceSurface(AppPalette.editor)
        controller.view = surface
        let hint = NSTextField(labelWithString: "No file open")
        hint.textColor = AppPalette.secondaryText
        let open = WorkspaceToolbarButton(title: "Open File…", symbol: "folder", restingBackground: true,
                                          target: self, action: #selector(openFileFromEmptyEditor(_:)))
        open.toolTip = "Open File (⌘O)"
        let actions = NSStackView(views: [hint, open])
        actions.orientation = .vertical
        actions.alignment = .centerX
        actions.spacing = 10
        actions.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(actions)
        NSLayoutConstraint.activate([
            actions.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            actions.centerYAnchor.constraint(equalTo: surface.centerYAnchor)
        ])
        return controller
    }

    @objc private func openFileFromEmptyEditor(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openFile(sender)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        let layout = sidebarLayout
        restoreSidebar(SidebarLayout(width: layout.width, isCollapsed: !layout.isCollapsed))
        if sidebarItem.isCollapsed { focusEditor() }
    }

    var sidebarLayout: SidebarLayout {
        let width = sidebarItem.isCollapsed ? lastSidebarWidth : sidebarItem.viewController.view.frame.width
        return SidebarLayout(width: width.flatMap { $0 > 0 ? $0 : nil }, isCollapsed: sidebarItem.isCollapsed)
    }

    func restoreSidebar(_ layout: SidebarLayout) {
        lastSidebarWidth = layout.width
        sidebarItem.isCollapsed = layout.isCollapsed
        guard !layout.isCollapsed, let width = layout.width else { return }
        view.layoutSubtreeIfNeeded()
        let divider = split.splitView
        let minimum = divider.minPossiblePositionOfDivider(at: 0)
        let maximum = divider.maxPossiblePositionOfDivider(at: 0)
        divider.setPosition(min(maximum, max(minimum, width)), ofDividerAt: 0)
    }

    private func updateFileTree(refresh: Bool = false) {
        let rootChanged = fileTree.setRoot(fileTreeRoot)
        if refresh && !rootChanged {
            fileTree.reload()
        }
        fileTree.selectFile(document?.fileURL)
        updateToolbar()
    }

    private func documentLocationChanged(from previousURL: URL?) {
        guard previousURL?.standardizedFileURL.path != document?.fileURL?.standardizedFileURL.path else { return }
        updateFileTree(refresh: true)
        let previousBuild = buildSession
        bindBuildSession()
        if let previousBuild, let buildSession, previousBuild !== buildSession,
           previousBuild.target == previousURL.map(ProjectBuildSession.normalized),
           buildSession.target == document?.fileURL.map(ProjectBuildSession.normalized) {
            buildSession.keepPreview(from: previousBuild)
        }
        if let root = fileTreeRoot.map(ProjectBuildSession.normalized) {
            for workspace in tabWorkspaces where workspace !== self
                && workspace.fileTreeRoot.map(ProjectBuildSession.normalized) == root {
                workspace.updateFileTree(refresh: true)
                workspace.bindBuildSession()
            }
        }
        document?.tabs?.refresh()
        noteProjectChanged()
    }

    private func setProjectFolder(_ url: URL?) {
        projectFolder = url
        guard isViewLoaded else { return }
        updateFileTree()
        bindBuildSession()
    }

    func useProjectDirectory(_ url: URL) {
        for workspace in tabWorkspaces { workspace.setProjectFolder(url) }
        noteProjectChanged()
    }

    private func noteProjectChanged() {
        if let active = tabWorkspaces.first(where: { $0.isViewLoaded && $0.view.window?.isMainWindow == true }) {
            (NSApp.delegate as? AppDelegate)?.noteProjectChanged(active)
        }
    }

    private func chooseProjectFolder() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Project Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = fileTreeRoot
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            useProjectDirectory(url)
        }
    }

    private func createProjectEntry(_ kind: FileTreeController.CreationKind, in directory: URL) {
        guard let window = view.window, window.attachedSheet == nil, !isCreatingProjectEntry else { return }
        isCreatingProjectEntry = true

        Task {
            defer { isCreatingProjectEntry = false }
            let isFolder = kind == .folder
            let title = isFolder ? "New Folder" : "New File"
            let directoryName = directory.lastPathComponent.isEmpty ? directory.path : directory.lastPathComponent
            let location = "The new item will be created in “\(directoryName)”."
            var input = ""
            var feedback = isFolder ? location : location + " A .tex extension is added if you leave it out."

            while view.window === window {
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = feedback
                alert.addButton(withTitle: "Create")
                alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"

                let field = NSTextField(string: input)
                field.frame.size = NSSize(width: 280, height: 24)
                field.placeholderString = isFolder ? "Folder name" : "File name"
                field.setAccessibilityLabel(field.placeholderString)
                alert.accessoryView = field
                alert.window.initialFirstResponder = field

                guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn,
                      view.window === window else { return }
                input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !input.isEmpty else {
                    feedback = "Enter a name."
                    continue
                }
                let invalidCharacters = CharacterSet(charactersIn: "/:").union(.controlCharacters)
                guard !input.hasPrefix("."), input.rangeOfCharacter(from: invalidCharacters) == nil else {
                    feedback = "Names must start with a character other than a period and cannot contain slashes, colons, or control characters."
                    continue
                }

                var entry = directory.appendingPathComponent(input, isDirectory: isFolder)
                if !isFolder && entry.pathExtension.isEmpty {
                    entry.appendPathExtension("tex")
                }
                do {
                    if isFolder {
                        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: false)
                    } else {
                        try Data().write(to: entry, options: .withoutOverwriting)
                    }
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    feedback = "“\(entry.lastPathComponent)” already exists here."
                    continue
                } catch {
                    feedback = error.localizedDescription
                    continue
                }

                let root = fileTreeRoot.map(ProjectBuildSession.normalized)
                for workspace in tabWorkspaces where workspace.isViewLoaded
                    && workspace.fileTreeRoot.map(ProjectBuildSession.normalized) == root {
                    workspace.fileTree.reload()
                }
                fileTree.selectFile(entry)
                if !isFolder && ProjectFileKind.detect(for: entry)?.isEditable == true {
                    openProjectFile(entry)
                }
                return
            }
        }
    }

    func openProjectFile(_ url: URL, onOpened: ((WorkspaceController) -> Void)? = nil,
                         onFailure: (() -> Void)? = nil) {
        guard let tabs = documentTabs else { onFailure?(); return }
        let folder = fileTreeRoot
        NSDocumentController.shared.openDocument(withContentsOf: url, display: false) { [weak self] opened, _, error in
            guard let opened = opened as? TeXDocument else {
                if let onFailure { onFailure() }
                else if let error { NSApp.presentError(error) }
                return
            }
            if opened.workspace == nil {
                if self?.documentTabs === tabs {
                    opened.prepareWorkspace(in: tabs)
                    opened.workspace?.setProjectFolder(folder)
                } else {
                    opened.makeWindowControllers()
                }
            }
            guard let group = opened.tabs else { onFailure?(); return }
            group.show(opened) { [weak opened] shown in
                if shown, let workspace = opened?.workspace { onOpened?(workspace) }
                else { onFailure?() }
            }
        }
    }

    func activateProjectTab() { document?.showWindows() }

    func updateFileTabs(_ tabs: [FileTabStrip.Tab], selected: ObjectIdentifier?) {
        tabStrip.update(tabs, selected: selected)
    }

    func focusEditor() {
        if canEditSource && workspaceLayout != .pdfOnly { editor.focusEditor() }
    }

    func endTypingGroup() {
        if canEditSource { editor.endTypingGroup() }
    }

    @objc func compile(_ sender: Any?) {
        bindBuildSession()
        buildSession?.compile()
    }

    private func sourcePreviewLocation() -> (ProjectBuildSession, SyncTeXMap.PDFLocation)? {
        guard canEditSource else { return nil }
        let file = documentURL
        let line = editor.caretLine
        let workspaces = file == nil ? [self] : [self] + tabWorkspaces.filter { $0 !== self }
        for workspace in workspaces {
            guard let session = workspace.buildSession, file != nil || session.target == nil,
                  let location = session.preview?.syncTeX?.forward(file: file, line: line) else { continue }
            return (session, location)
        }
        return nil
    }

    @objc func showSourceInPDF(_ sender: Any? = nil) {
        guard let (session, location) = sourcePreviewLocation() else { return }
        if workspaceLayout == .editorOnly { setWorkspaceLayout(.split) }
        attachBuildSession(session)
        _ = pdfView.revealSourceLocation(pageIndex: location.pageIndex, rect: location.rect)
    }

    private func showSourceFromPDF(pageIndex: Int, point: CGPoint) -> Bool {
        guard let session = buildSession, let preview = session.preview,
              let location = preview.syncTeX?.inverse(pageIndex: pageIndex, point: point) else { return false }
        return navigateToSource(file: location.file, line: location.line) { [weak self] workspace in
            guard let self, workspace !== self, workspace.documentTabs === documentTabs else { return }
            workspace.attachBuildSession(session)
            if workspace.pdfView.document === preview.document {
                let rect = CGRect(origin: point, size: CGSize(width: 1, height: 1))
                _ = workspace.pdfView.revealSourceLocation(pageIndex: pageIndex, rect: rect)
            }
        }
    }

    func showBuildFiles() {
        if let buildFilesDirectory { NSWorkspace.shared.open(buildFilesDirectory) }
    }

    func cleanBuildFiles() {
        guard canCleanBuildFiles, let directory = projectDirectory, let window = view.window,
              window.attachedSheet == nil else { return }
        isCleaningBuildFiles = true
        Task { [weak self, weak window] in
            defer { self?.isCleaningBuildFiles = false }
            do {
                try await Task.detached {
                    try TectonicCompiler.cleanBuildArtifacts(in: directory)
                }.value
                if let self, view.window === window {
                    statusLabel.stringValue = "Build files cleaned"
                }
            } catch {
                if let window, window.isVisible, window.attachedSheet == nil {
                    _ = await NSAlert(error: error).beginSheetModal(for: window)
                }
            }
        }
    }

    func toggleAutoCompile() {
        bindBuildSession()
        buildSession?.toggleAutomatic()
    }

    private func bindBuildSession() {
        guard let document else { return }
        let folder = fileTreeRoot
        let main = ProjectBuildSession.mainFile(in: folder)
        fileTree.setMainFile(main)
        let session: ProjectBuildSession
        if let target = main ?? compilationSource(for: document, in: folder) {
            session = ProjectBuildSession.shared(root: folder, target: target, document: document)
        } else if document.kind == .latex && document.fileURL == nil {
            if let buildSession, buildSession.target == nil { return }
            session = ProjectBuildSession.untitled(document: document)
        } else {
            if let buildSession {
                buildSession.detach(self)
                self.buildSession = nil
                display(nil)
                showLog("No build log yet.")
                setLogVisible(false)
                errorButton.isHidden = true
                updatePreviewControls()
            }
            updateStandaloneStatus()
            updateToolbar()
            return
        }
        attachBuildSession(session)
    }

    private func attachBuildSession(_ session: ProjectBuildSession) {
        guard buildSession !== session else { return }
        buildSession?.detach(self)
        buildSession = session
        session.attach(self)
    }

    private func compilationSource(for document: TeXDocument, in folder: URL?) -> URL? {
        if document.kind == .latex { return document.fileURL }
        guard let root = folder.map(ProjectBuildSession.normalized) else { return nil }
        return document.tabs?.documents.lazy.compactMap { candidate -> URL? in
            guard candidate.kind == .latex, let location = candidate.fileURL else { return nil }
            let file = ProjectBuildSession.normalized(location)
            return ProjectBuildSession.contains(file, in: root) ? file : nil
        }.first
    }

    private func setMainFile(_ url: URL) {
        guard let folder = fileTreeRoot else { return }
        ProjectBuildSession.setMainFile(url, in: folder)
        let root = ProjectBuildSession.normalized(folder)
        for case let document as TeXDocument in NSDocumentController.shared.documents {
            if let workspace = document.workspace, workspace.fileTreeRoot.map(ProjectBuildSession.normalized) == root {
                workspace.bindBuildSession()
            }
        }
    }

    func closeWorkspace() {
        projectSearch?.dismiss()
        if document?.isDocumentEdited == true {
            ProjectBuildSession.sourceDidChange(in: document, primary: buildSession)
        }
        buildSession?.detach(self)
        buildSession = nil
    }

    @objc func showProjectSearch(_ sender: Any? = nil) {
        guard let root = fileTreeRoot, let parent = view.window else { return }
        guard parent.attachedSheet == nil else { return }
        let search = ProjectSearchController(root: root, openSources: ProjectBuildSession.openSources(in: root))
        search.openSourcesProvider = { ProjectBuildSession.openSources(in: root) }
        search.onNavigate = { [weak self] url, range in
            self?.openProjectFile(url) { workspace in
                workspace.revealEditorIfNeeded()
                workspace.editor.reveal(range)
            }
        }
        projectSearch = search
        search.show(attachedTo: parent)
    }

    func showQuickOpen() {
        guard let root = fileTreeRoot, let parent = view.window, parent.attachedSheet == nil else { return }
        let openFiles = [documentURL].compactMap { $0 } + projectTabDocumentURLs
        let search = ProjectSearchController(root: root, openFiles: openFiles)
        search.onOpenFile = { [weak self] url in self?.openProjectFile(url) }
        projectSearch = search
        search.show(attachedTo: parent)
    }

    func toggleComment() {
        if canUseLaTeXCommands { editor.toggleComment() }
    }

    func completeCommand() {
        if canUseLaTeXCommands { editor.completeCommand() }
    }

    func promptForLine() {
        guard canEditSource, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        field.placeholderString = "Line number"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        Task {
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn,
                  let line = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), line > 0 else { return }
            revealEditorIfNeeded()
            editor.goToLine(line)
        }
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let pdfData = buildSession?.preview?.data, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.title = "Export PDF"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        let target = ProjectBuildSession.mainFile(in: fileTreeRoot) ?? document?.fileURL
        let name = target?.deletingPathExtension().lastPathComponent ?? "Untitled"
        panel.nameFieldStringValue = name + ".pdf"
        panel.directoryURL = target?.deletingLastPathComponent()
        Task {
            let response = await panel.beginSheetModal(for: window)
            guard response == .OK, let url = panel.url else { return }
            do {
                try pdfData.write(to: url, options: .atomic)
            } catch {
                _ = await NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc func toggleLog(_ sender: Any?) {
        setLogVisible(logPanel.isHidden)
    }

    @objc func zoomIn(_ sender: Any?) {
        guard canZoomIn else { return }
        pdfView.autoScales = false
        pdfView.zoomIn(sender)
    }

    @objc func zoomOut(_ sender: Any?) {
        guard canZoomOut else { return }
        pdfView.autoScales = false
        pdfView.zoomOut(sender)
    }

    @objc func fitPDF(_ sender: Any?) {
        guard canExport else { return }
        pdfView.autoScales = true
        updatePreviewControls()
    }

    func buildDidChange(_ session: ProjectBuildSession) {
        guard buildSession === session else { return }
        if pdfView.document !== session.preview?.document {
            display(session.preview?.document)
            for workspace in tabWorkspaces where workspace !== self && workspace.isViewLoaded {
                workspace.updateSourceJumpButton()
            }
        }
        if logView.string != session.log {
            showLog(session.log)
            if session.phase == .failed { setLogVisible(true) }
        }
        errorButton.isHidden = session.location == nil
        updateStatus(session)
        updatePreviewControls()
        updateToolbar()
    }

    private func display(_ pdf: PDFDocument?) {
        let previousPage = pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) } ?? 0
        let fitted = pdfView.document == nil || pdfView.autoScales
        let scale = pdfView.scaleFactor
        pdfView.clearSourceHighlight()
        pdfView.document = pdf
        pdfView.isHidden = pdf == nil
        previewPlaceholder.isHidden = pdf != nil
        guard let pdf, pdf.pageCount > 0 else { return }
        if fitted {
            pdfView.autoScales = true
        } else {
            pdfView.scaleFactor = scale
        }
        if let page = pdf.page(at: min(previousPage, pdf.pageCount - 1)) {
            pdfView.go(to: page)
        }
    }

    @objc private func previewChanged(_ notification: Notification) {
        updatePreviewControls()
    }

    private func updatePreviewControls() {
        zoomOutButton.isEnabled = canZoomOut
        zoomInButton.isEnabled = canZoomIn
        fitButton.isEnabled = canExport
        guard let pdf = pdfView.document, pdf.pageCount > 0 else {
            zoomLabel.stringValue = "—"
            return
        }
        let scale = pdfView.scaleFactor
        zoomLabel.stringValue = scale.isFinite && scale > 0 ? "\(Int((100 * scale).rounded()))%" : "—"
    }

    func setAutosaveWarning(_ warning: String?) {
        guard autosaveWarning != warning else { return }
        autosaveWarning = warning
        if let buildSession { updateStatus(buildSession) }
        else { updateStandaloneStatus() }
    }

    private func updateStandaloneStatus() {
        if autosaveWarning != nil {
            statusLabel.stringValue = "Autosave failed"
        } else {
            switch document?.kind {
            case .image: statusLabel.stringValue = "Read-only image"
            case .pdf: statusLabel.stringValue = "Read-only PDF"
            default: statusLabel.stringValue = "Ready"
            }
        }
        statusLabel.toolTip = autosaveWarning
        let symbol = autosaveWarning == nil ? "circle" : "exclamationmark.circle.fill"
        statusImage.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        statusImage.contentTintColor = autosaveWarning == nil ? AppPalette.secondaryText : AppPalette.warning
    }

    private func updateStatus(_ session: ProjectBuildSession) {
        let message: String
        let symbol: String
        let color: NSColor
        switch session.phase {
        case .ready:
            (message, symbol, color) = ("Ready", "circle", AppPalette.secondaryText)
        case .building:
            (message, symbol, color) = ("Compiling with Tectonic…", "arrow.clockwise", AppPalette.accent)
        case .complete:
            (message, symbol, color) = ("Build complete", "checkmark.circle.fill", AppPalette.success)
        case .outdated:
            (message, symbol, color) = ("Source changed · Press ⌘R to update the preview", "circle.dotted", AppPalette.warning)
        case .failed:
            message = !canExport ? "Build failed · See the build log" : "Build failed · Showing the last successful PDF"
            (symbol, color) = ("exclamationmark.circle.fill", AppPalette.error)
        }
        statusLabel.stringValue = [message, session.target?.lastPathComponent, session.automatic ? "Auto-compile" : nil,
                                   autosaveWarning == nil ? nil : "Autosave failed",
                                   session.artifactWarning == nil ? nil : "Build files not saved"]
            .compactMap { $0 }.joined(separator: " · ")
        let warnings = [autosaveWarning, session.artifactWarning].compactMap { $0 }
        statusLabel.toolTip = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        statusImage.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        statusImage.contentTintColor = color
    }

    private func makePane(header: NSView, content: NSViewController) -> NSViewController {
        let controller = NSViewController()
        let panel = NSView()
        controller.view = panel
        controller.addChild(content)
        content.view.clipsToBounds = true
        for child in [header, content.view] {
            child.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: panel.topAnchor),
            header.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: FileTabStrip.height),
            content.view.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.view.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            content.view.bottomAnchor.constraint(equalTo: panel.bottomAnchor)
        ])
        return controller
    }

    private func makeHeader(title: String, symbol: String, accessory: NSView?) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 11.5, weight: .semibold)
        heading.textColor = AppPalette.secondaryText
        heading.lineBreakMode = .byTruncatingTail
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        icon.contentTintColor = AppPalette.accent
        let titleGroup = NSStackView(views: [icon, heading])
        titleGroup.alignment = .centerY
        titleGroup.spacing = 7
        return makeHeader(leading: titleGroup, accessory: accessory)
    }

    private func makeHeader(leading: NSView, accessory: NSView?) -> NSView {
        let header = WorkspaceSurface(AppPalette.chrome)
        let rule = WorkspaceSurface(AppPalette.rule)
        for child in [leading, rule] {
            child.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(child)
        }
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            leading.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            leading.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -12),
            rule.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1)
        ])
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(accessory)
            NSLayoutConstraint.activate([
                accessory.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 8),
                accessory.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -9),
                accessory.centerYAnchor.constraint(equalTo: header.centerYAnchor)
            ])
        }
        return header
    }

    private func makeZoomControls() -> NSView {
        let buttons: [(NSButton, String, String, Selector)] = [
            (zoomOutButton, "minus", "Zoom Out (⌘−)", #selector(zoomOut(_:))),
            (zoomInButton, "plus", "Zoom In (⌘+)", #selector(zoomIn(_:))),
            (fitButton, "arrow.up.left.and.arrow.down.right", "Fit PDF (⌘0)", #selector(fitPDF(_:)))
        ]
        for (button, symbol, label, action) in buttons {
            button.title = ""
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            button.imagePosition = .imageOnly
            button.bezelStyle = .accessoryBarAction
            button.showsBorderOnlyWhileMouseInside = true
            button.contentTintColor = AppPalette.secondaryText
            button.target = self
            button.action = action
            button.toolTip = label
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomLabel.textColor = AppPalette.secondaryText
        zoomLabel.alignment = .center
        zoomLabel.setAccessibilityLabel("PDF Zoom")
        zoomLabel.toolTip = "Hold Control and scroll to zoom"
        zoomLabel.widthAnchor.constraint(equalToConstant: 41).isActive = true
        let steppers = NSStackView(views: [zoomOutButton, zoomLabel, zoomInButton])
        steppers.alignment = .centerY
        steppers.spacing = 0
        steppers.detachesHiddenViews = true
        steppers.translatesAutoresizingMaskIntoConstraints = false
        let tray = WorkspaceSurface(AppPalette.control, radius: 7)
        tray.addSubview(steppers)
        NSLayoutConstraint.activate([
            steppers.leadingAnchor.constraint(equalTo: tray.leadingAnchor, constant: 2),
            steppers.trailingAnchor.constraint(equalTo: tray.trailingAnchor, constant: -2),
            steppers.topAnchor.constraint(equalTo: tray.topAnchor),
            steppers.bottomAnchor.constraint(equalTo: tray.bottomAnchor)
        ])
        let controls = NSStackView(views: [tray, fitButton])
        controls.alignment = .centerY
        controls.spacing = 4
        return controls
    }

    private func makePreview() -> NSViewController {
        let controller = NSViewController()
        let container = WorkspaceSurface(AppPalette.preview)
        controller.view = container

        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = AppPalette.preview
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 21, left: 18, bottom: 21, right: 18)
        pdfView.pageShadowsEnabled = true
        pdfView.minScaleFactor = 0.15
        pdfView.maxScaleFactor = 5
        pdfView.isHidden = true
        pdfView.onSourceJump = { [weak self] page, point in self?.showSourceFromPDF(pageIndex: page, point: point) == true }
        for child in [pdfView, previewPlaceholder] {
            child.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                child.topAnchor.constraint(equalTo: container.topAnchor),
                child.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }

        let emblem = WorkspaceSurface(AppPalette.accentSurface, radius: 16)
        let artwork = NSImageView()
        artwork.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 25, weight: .regular))
        artwork.contentTintColor = AppPalette.accent
        artwork.translatesAutoresizingMaskIntoConstraints = false
        emblem.addSubview(artwork)
        NSLayoutConstraint.activate([
            emblem.widthAnchor.constraint(equalToConstant: 58),
            emblem.heightAnchor.constraint(equalToConstant: 58),
            artwork.centerXAnchor.constraint(equalTo: emblem.centerXAnchor),
            artwork.centerYAnchor.constraint(equalTo: emblem.centerYAnchor)
        ])
        let hint = NSTextField(labelWithString: "No compiled PDF yet")
        hint.textColor = AppPalette.secondaryText
        hint.font = .systemFont(ofSize: 13)
        let emptyState = NSStackView(views: [emblem, hint])
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 13
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        previewPlaceholder.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: previewPlaceholder.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: previewPlaceholder.centerYAnchor)
        ])
        return controller
    }

    private func makeLogPanel() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = AppPalette.editor
        scroll.documentView = logView
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.backgroundColor = AppPalette.editor
        logView.textColor = AppPalette.text
        logView.isEditable = false
        logView.isRichText = false
        logView.string = "No build log yet."
        logView.textContainerInset = NSSize(width: 12, height: 8)
        logView.isVerticallyResizable = true
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        logView.setAccessibilityLabel("Build Log")
        errorButton.title = "Go to Error"
        errorButton.target = self
        errorButton.action = #selector(goToCompilationError(_:))
        errorButton.controlSize = .small
        errorButton.isHidden = true
        let header = makeHeader(title: "Build Log", symbol: "terminal", accessory: errorButton)
        for child in [header, scroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            logPanel.addSubview(child)
        }
        let headerHeight = header.heightAnchor.constraint(equalToConstant: 0)
        logHeaderHeight = headerHeight
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: logPanel.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: logPanel.trailingAnchor),
            header.topAnchor.constraint(equalTo: logPanel.topAnchor),
            headerHeight,
            scroll.leadingAnchor.constraint(equalTo: logPanel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: logPanel.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: logPanel.bottomAnchor)
        ])
    }

    @objc private func goToCompilationError(_ sender: Any?) {
        guard let location = buildSession?.location else { return }
        _ = navigateToSource(file: location.file, line: location.line)
    }

    @discardableResult
    private func navigateToSource(file: URL?, line: Int, onOpened: ((WorkspaceController) -> Void)? = nil) -> Bool {
        if let file = file.map(ProjectBuildSession.normalized),
           documentURL.map(ProjectBuildSession.normalized) != file {
            guard let root = projectDirectory.map(ProjectBuildSession.normalized),
                  ProjectBuildSession.contains(file, in: root), ProjectFileKind.detect(for: file)?.isEditable == true,
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
            openProjectFile(file) { workspace in
                workspace.revealEditorIfNeeded()
                workspace.editor.goToLine(line)
                onOpened?(workspace)
            }
            return true
        }
        guard canEditSource else { return false }
        revealEditorIfNeeded()
        editor.goToLine(line)
        onOpened?(self)
        return true
    }

    private func showLog(_ message: String) {
        logView.string = message
        logView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func setLogVisible(_ visible: Bool) {
        if !visible && view.window?.firstResponder === logView {
            focusEditor()
        }
        logPanel.isHidden = !visible
        logHeight?.constant = visible ? 184 : 0
        logHeaderHeight?.constant = visible ? 32 : 0
    }

    private func makeStatusBar() -> NSView {
        let statusBar = WorkspaceSurface(AppPalette.chrome)
        let line = WorkspaceSurface(AppPalette.rule)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = AppPalette.secondaryText
        for child in [line, statusImage, statusLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            statusBar.addSubview(child)
        }
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: statusBar.topAnchor),
            line.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            statusImage.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusImage.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusImage.widthAnchor.constraint(equalToConstant: 13),
            statusImage.heightAnchor.constraint(equalToConstant: 13),
            statusLabel.leadingAnchor.constraint(equalTo: statusImage.trailingAnchor, constant: 6),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusBar.trailingAnchor, constant: -14)
        ])
        return statusBar
    }

    private func makeTitleBar() -> NSView {
        let sidebarButton = WorkspaceToolbarButton(symbol: "sidebar.left", target: self,
                                                   action: #selector(toggleSidebar(_:)))
        sidebarButton.toolTip = "Toggle Sidebar (⌥⌘S)"
        sidebarButton.setAccessibilityLabel("Toggle Sidebar")
        projectButton.setAccessibilityIdentifier("ProjectMenu")
        searchButton.toolTip = "Search Project (⇧⌘F)"
        searchButton.setAccessibilityIdentifier("ProjectSearch")
        let layoutButton = WorkspaceToolbarButton(title: "Layout", symbol: "rectangle.split.2x1",
            showsChevron: true, target: self, action: #selector(showLayoutMenu(_:)))
        layoutButton.toolTip = "Layout Options"
        layoutButton.setAccessibilityIdentifier("WorkspaceLayout")
        layoutButton.setAccessibilityLabel("Layout Options")
        logButton.toolTip = "Build Log (⌘L)"
        logButton.setAccessibilityLabel("Build Log")
        return WorkspaceTitleBar(sidebar: sidebarButton, project: projectButton, search: searchButton,
                                 layout: layoutButton, log: logButton)
    }

    func installToolbar(on window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = AppPalette.titleBar
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.standardWindowButton(.documentIconButton)?.isHidden = true
        updateToolbar()
    }

    @objc private func showProjectMenu(_ sender: Any?) {
        guard let button = sender as? NSButton, let app = NSApp.delegate as? AppDelegate,
              view.window?.attachedSheet == nil else { return }
        let bottom = button.isFlipped ? button.bounds.maxY : button.bounds.minY
        app.projectMenu(for: projectDirectory).popUp(positioning: nil,
            at: NSPoint(x: button.bounds.minX, y: bottom), in: button)
    }

    @objc private func showLayoutMenu(_ sender: NSButton) {
        guard let window = sender.window, window.attachedSheet == nil else { return }
        let menu = NSMenu(title: "Layout Options")
        let choices: [(WorkspaceLayout, String)] = [
            (.split, "Split View"), (.editorOnly, "Editor Only"), (.pdfOnly, "PDF Only")
        ]
        for (layout, title) in choices {
            let item = NSMenuItem(title: title, action: #selector(selectWorkspaceLayout(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = layout
            item.state = layout == workspaceLayout ? .on : .off
            menu.addItem(item)
        }
        let bottom = sender.isFlipped ? sender.bounds.maxY : sender.bounds.minY
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.minX, y: bottom), in: sender)
    }

    @objc private func selectWorkspaceLayout(_ sender: NSMenuItem) {
        if let layout = sender.representedObject as? WorkspaceLayout {
            setWorkspaceLayout(layout)
        }
    }

    private func updateToolbar() {
        compileButton.update(enabled: canCompile, building: buildSession?.phase == .building)
        updateSourceJumpButton()
        let name = projectDirectory?.lastPathComponent ?? ""
        projectButton.title = name.isEmpty ? AppIdentity.displayName : name
        projectButton.toolTip = projectDirectory?.path ?? "Open or switch projects"
        projectButton.setAccessibilityLabel("\(projectButton.title), Project Menu")
        searchButton.isEnabled = canSearchProject
        logButton.isEnabled = hasBuildTarget
    }

    private func updateSourceJumpButton() {
        sourceJumpButton.isHidden = !canEditSource || workspaceLayout != .split
        sourceJumpButton.isEnabled = canShowSourceInPDF
    }
}

private final class PDFPreviewHeader: WorkspaceSurface {
    private let compileButton: PreviewCompileButton
    private let navigator: PDFPageNavigator
    private let zoomControls: NSView
    private let zoomLabel: NSTextField
    private let rule = WorkspaceSurface(AppPalette.rule)
    private let zoomSize: NSSize
    private let zoomLabelWidth: CGFloat

    init(compileButton: PreviewCompileButton, navigator: PDFPageNavigator, zoomControls: NSView,
         zoomLabel: NSTextField) {
        self.compileButton = compileButton
        self.navigator = navigator
        self.zoomControls = zoomControls
        self.zoomLabel = zoomLabel
        zoomSize = zoomControls.fittingSize
        zoomLabelWidth = zoomLabel.fittingSize.width
        super.init(AppPalette.chrome)
        setAccessibilityLabel("PDF Preview")
        for child in [compileButton, navigator, zoomControls, rule] { addSubview(child) }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let navigationSize = navigator.intrinsicContentSize
        let compact = !navigator.isHidden && bounds.width < navigationSize.width + 2 * (zoomSize.width + 14)
        compileButton.isCompact = compact
        zoomLabel.isHidden = compact
        let edge: CGFloat = compact ? 6 : 10
        let gap: CGFloat = compact ? 4 : 6
        let compileSize = compileButton.intrinsicContentSize
        compileButton.frame = NSRect(x: bounds.minX + edge, y: floor(bounds.midY - compileSize.height / 2),
                                     width: compileSize.width, height: compileSize.height)
        let zoomWidth = compact ? zoomSize.width - zoomLabelWidth : zoomSize.width
        zoomControls.frame = NSRect(x: bounds.maxX - edge - zoomWidth, y: floor(bounds.midY - zoomSize.height / 2),
                                    width: zoomWidth, height: zoomSize.height)
        let left = compileButton.frame.maxX + gap
        let right = zoomControls.frame.minX - gap
        let width = max(0, min(navigationSize.width, right - left))
        let preferredX = bounds.midX - width / 2
        let x = min(max(left, preferredX), right - width)
        navigator.frame = NSRect(x: x, y: floor(bounds.midY - navigationSize.height / 2), width: width,
                                 height: navigationSize.height)
        rule.frame = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: 1)
    }
}

private final class PreviewCompileButton: NSButton {
    private static let play = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
    private static let building = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    private var isBuilding = false
    var isCompact = false {
        didSet {
            if oldValue != isCompact { needsDisplay = true }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        font = .systemFont(ofSize: 12, weight: .semibold)
        toolTip = "Compile PDF (⌘R)"
        setAccessibilityIdentifier("CompilePDF")
        update(enabled: false, building: false)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: isCompact ? 28 : 104, height: 27) }

    func update(enabled: Bool, building: Bool) {
        isEnabled = enabled
        isBuilding = building
        title = building ? "Compiling…" : "Compile PDF"
        needsDisplay = true
    }

    private var buttonPath: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1.5), xRadius: 7, yRadius: 7)
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = !isEnabled ? AppPalette.control
            : isHighlighted ? AppPalette.actionPressed : AppPalette.action
        color.setFill()
        buttonPath.fill()

        let tint = isEnabled ? AppPalette.actionText : (isBuilding ? AppPalette.secondaryText : AppPalette.disabledText)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: tint
        ]
        let label = (isCompact ? "" : title) as NSString
        let size = label.size(withAttributes: attributes)
        let symbol = isBuilding ? Self.building : Self.play
        let iconWidth: CGFloat = symbol == nil ? 0 : 11
        let gap: CGFloat = iconWidth > 0 && !isCompact ? 6 : 0
        let start = bounds.midX - (iconWidth + gap + size.width) / 2
        let image = symbol?.withSymbolConfiguration(.init(paletteColors: [tint]))
        image?.draw(in: NSRect(x: start, y: bounds.midY - 5.5, width: iconWidth, height: 11))
        label.draw(at: NSPoint(x: start + iconWidth + gap, y: bounds.midY - size.height / 2),
                   withAttributes: attributes)
    }

    override var focusRingMaskBounds: NSRect { buttonPath.bounds }
    override func drawFocusRingMask() { buttonPath.fill() }
}

class WorkspaceSurface: NSView {
    private let fill: NSColor
    private let radius: CGFloat

    init(_ fill: NSColor, radius: CGFloat = 0) {
        self.fill = fill
        self.radius = radius
        super.init(frame: .zero)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        if radius == 0 {
            NSBezierPath.fill(dirtyRect.intersection(bounds))
        } else {
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
