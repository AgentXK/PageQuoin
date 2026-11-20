import AppKit

@MainActor
final class DocumentTabGroup: NSObject {
    private final class Member {
        weak var document: TeXDocument?

        init(_ document: TeXDocument) {
            self.document = document
        }
    }

    private var members: [Member] = []
    private weak var active: TeXDocument?
    private weak var window: DocumentTabWindow?
    private weak var closeRequested: TeXDocument?
    private var keepWindowForCloseRequest = true
    private var deferredOpenings: [() -> Void] = []

    var workspaceLayout: WorkspaceLayout = .split
    var documents: [TeXDocument] { members.compactMap(\.document) }
    var canSwitchTabs: Bool { documents.count > 1 && window?.attachedSheet == nil }

    func isReviewingClose(of document: TeXDocument) -> Bool { closeRequested === document }

    func add(_ document: TeXDocument) {
        members.append(Member(document))
        refresh()
    }

    func show(_ document: TeXDocument, onShown: ((Bool) -> Void)? = nil) {
        guard documents.contains(where: { $0 === document }), let workspace = document.workspace,
              let controller = document.windowControllers.first else { onShown?(false); return }
        if active !== document && window?.attachedSheet != nil {
            deferredOpenings.append { [weak self, weak document] in
                if let self, let document { show(document, onShown: onShown) }
                else { onShown?(false) }
            }
            return
        }
        let isNewWindow = window == nil
        let window = window ?? DocumentTabWindow(tabs: self)
        if active !== document {
            let frame = window.frame
            let sidebar = (window.contentViewController as? WorkspaceController)?.sidebarLayout
            active?.workspace?.endTypingGroup()
            window.makeFirstResponder(nil)
            active?.windowControllers.first?.window = nil
            active = document
            window.contentViewController = workspace
            controller.window = window
            window.releaseFromEmptyWorkspace()
            window.contentMinSize = NSSize(width: 740, height: 420 + WorkspaceTitleBar.height)
            controller.synchronizeWindowTitleWithDocumentName()
            window.isDocumentEdited = document.isDocumentEdited
            workspace.installToolbar(on: window)
            if isNewWindow {
                NotificationCenter.default.addObserver(self, selector: #selector(sheetEnded(_:)),
                                                       name: NSWindow.didEndSheetNotification, object: window)
                window.setContentSize(NSSize(width: 1180, height: 720 + WorkspaceTitleBar.height))
                window.center()
            } else if !window.styleMask.contains(.fullScreen) {
                window.setFrame(frame, display: false)
            }
            if let sidebar { workspace.restoreSidebar(sidebar) }
            workspace.setWorkspaceLayout(workspaceLayout)
            self.window = window
            workspace.focusEditor()
        }
        refresh()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        noteActiveProject()
        onShown?(true)
    }

    func select(_ id: ObjectIdentifier) {
        guard window?.attachedSheet == nil,
              let document = documents.first(where: { ObjectIdentifier($0) == id }) else { return }
        show(document)
    }

    func selectRelative(_ offset: Int) {
        let tabs = documents
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0 === active }) else { return }
        select(ObjectIdentifier(tabs[(index + offset + tabs.count) % tabs.count]))
    }

    func close(_ id: ObjectIdentifier) {
        guard let document = documents.first(where: { ObjectIdentifier($0) == id }) else { return }
        requestClose(document)
    }

    func closeActiveTab(keepingProjectWindow: Bool = true) -> Bool {
        guard let active else { return false }
        requestClose(active, keepingProjectWindow: keepingProjectWindow)
        return true
    }

    private func requestClose(_ document: TeXDocument, keepingProjectWindow: Bool = true) {
        guard closeRequested == nil, window?.attachedSheet == nil else { return }
        // Present the save sheet on the shared window belonging to the document being closed.
        if document.isDocumentEdited && active !== document { show(document) }
        closeRequested = document
        keepWindowForCloseRequest = keepingProjectWindow
        document.canClose(withDelegate: self, shouldClose: #selector(closeDecision(_:shouldClose:contextInfo:)),
                          contextInfo: nil)
    }

    @objc private func closeDecision(_ document: NSDocument, shouldClose: Bool,
                                     contextInfo: UnsafeMutableRawPointer?) {
        guard shouldClose, let document = document as? TeXDocument else {
            closeRequested = nil
            return
        }
        let keepWindow = keepWindowForCloseRequest
        Task { @MainActor [weak self] in
            guard let self, closeRequested === document else { return }
            document.close(keepingProjectWindow: keepWindow)
            closeRequested = nil
        }
    }

    @objc private func sheetEnded(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.flushOpenings()
        }
    }

    private func flushOpenings() {
        guard window?.attachedSheet == nil else { return }
        let openings = deferredOpenings
        deferredOpenings.removeAll()
        for open in openings { open() }
    }

    func remove(_ document: TeXDocument, keepingProjectWindow: Bool) {
        let previous = documents
        members.removeAll { $0.document == nil || $0.document === document }
        if active === document, !documents.isEmpty {
            let next = documents[min(previous.firstIndex(where: { $0 === document }) ?? 0, documents.count - 1)]
            show(next)
        } else if active === document, keepingProjectWindow, let window {
            showEmptyWorkspace(in: window, afterClosing: document)
        } else {
            if active === document {
                active = nil
                window = nil
                flushOpenings()
            }
            refresh()
            noteActiveProject()
        }
    }

    private func showEmptyWorkspace(in window: DocumentTabWindow, afterClosing document: TeXDocument) {
        let frame = window.frame
        let wasKey = window.isKeyWindow
        let directory = document.workspace?.projectDirectory
        let sidebar = document.workspace?.sidebarLayout
        window.retainForEmptyWorkspace()
        window.makeFirstResponder(nil)
        document.windowControllers.first?.window = nil
        active = nil
        let workspace = WorkspaceController(emptyTabs: self, projectDirectory: directory)
        window.contentViewController = workspace
        let projectName = directory?.lastPathComponent ?? ""
        window.title = projectName.isEmpty ? AppIdentity.displayName : projectName
        window.representedURL = nil
        window.isDocumentEdited = false
        workspace.installToolbar(on: window)
        if !window.styleMask.contains(.fullScreen) { window.setFrame(frame, display: false) }
        if let sidebar { workspace.restoreSidebar(sidebar) }
        workspace.setWorkspaceLayout(workspaceLayout)
        if wasKey { window.makeKeyAndOrderFront(nil) }
        else if !window.isVisible { window.orderFront(nil) }
        (NSApp.delegate as? AppDelegate)?.noteProjectChanged(workspace)
        flushOpenings()
    }

    func refresh() {
        let rows = documents.map { document in
            FileTabStrip.Tab(id: ObjectIdentifier(document),
                             name: document.fileURL?.lastPathComponent ?? document.displayName,
                             path: document.fileURL?.path, isEdited: document.isDocumentEdited, kind: document.kind)
        }
        active?.workspace?.updateFileTabs(rows, selected: active.map(ObjectIdentifier.init))
    }

    private func noteActiveProject() {
        if let workspace = active?.workspace {
            (NSApp.delegate as? AppDelegate)?.noteProjectChanged(workspace)
        }
    }
}

@MainActor
private final class DocumentTabWindow: NSWindow {
    // Once the last document controller detaches, the project view keeps the tab group
    // and this registry keeps the open window until a new document takes ownership.
    private static var documentFreeWindows: [ObjectIdentifier: DocumentTabWindow] = [:]
    private weak var tabs: DocumentTabGroup?

    init(tabs: DocumentTabGroup) {
        self.tabs = tabs
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720 + WorkspaceTitleBar.height),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        tabbingMode = .disallowed
        isReleasedWhenClosed = false
        isRestorable = false
    }

    func retainForEmptyWorkspace() {
        Self.documentFreeWindows[ObjectIdentifier(self)] = self
    }

    func releaseFromEmptyWorkspace() {
        Self.documentFreeWindows.removeValue(forKey: ObjectIdentifier(self))
    }

    override func performClose(_ sender: Any?) {
        if tabs?.closeActiveTab(keepingProjectWindow: false) == true { return }
        super.performClose(sender)
    }

    override func close() {
        if let workspace = contentViewController as? WorkspaceController, !workspace.hasActiveDocument {
            workspace.closeWorkspace()
        }
        super.close()
        releaseFromEmptyWorkspace()
    }

    override func selectNextTab(_ sender: Any?) {
        tabs?.selectRelative(1)
    }

    override func selectPreviousTab(_ sender: Any?) {
        tabs?.selectRelative(-1)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(selectNextTab(_:)) || item.action == #selector(selectPreviousTab(_:)) {
            return tabs?.canSwitchTabs == true
        }
        return super.validateUserInterfaceItem(item)
    }
}
