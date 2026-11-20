import AppKit

enum AppIdentity {
    static let displayName = "PageQuoin"
}

private final class LocalTeXApplication: NSApplication {
    override func terminate(_ sender: Any?) {
        (delegate as? AppDelegate)?.captureProjectBeforeQuit()
        super.terminate(sender)
    }
}

@main
@MainActor
enum LocalTeXApp {
    static func main() {
        let app = LocalTeXApplication.shared
        let documents = ProjectDocumentController()
        let delegate = AppDelegate()
        app.delegate = delegate
        NSWindow.allowsAutomaticWindowTabbing = false
        app.setActivationPolicy(.regular)
        delegate.installMenus()
        withExtendedLifetime((delegate, documents)) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    static let enginePathKey = "TectonicExecutable"

    private enum Appearance: String, CaseIterable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"

        var appKit: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    private static let appearanceKey = "AppAppearance"
    private var selectedAppearance: Appearance {
        UserDefaults.standard.string(forKey: Self.appearanceKey).flatMap(Appearance.init(rawValue:)) ?? .system
    }

    private let projectHistory = ProjectHistory()
    private let projectOpenPanelDelegate = ProjectOpenPanelDelegate()
    private let recentProjectsMenu = NSMenu(title: "Recent Projects")
    private var projectOpenTask: Task<Void, Never>?
    private var editorSettings: EditorSettingsController?
    private var receivedExternalOpen = false
    private var projectBeforeQuit: ProjectHistory.Project?
    private var isFinishingQuit = false

    private var workspace: WorkspaceController? {
        NSApp.mainWindow?.contentViewController as? WorkspaceController
    }

    private var auxiliaryKeyWindow: NSWindow? {
        guard let window = NSApp.keyWindow, !(window.contentViewController is WorkspaceController) else { return nil }
        return window
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(projectWindowBecameMain(_:)),
                                               name: NSWindow.didBecomeMainNotification, object: nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        Task { [weak self] in
            guard let self, !receivedExternalOpen,
                  projectOpenTask == nil,
                  !NSApp.orderedWindows.contains(where: { $0.contentViewController is WorkspaceController }) else { return }
            let controller = NSDocumentController.shared
            if let existing = controller.documents.first(where: { $0.fileURL != nil || $0.isDocumentEdited }) {
                existing.showWindows()
            } else if let project = projectHistory.recentProjects().first {
                // AppKit may prepare an invisible, unedited untitled document at launch.
                for document in controller.documents { document.close() }
                openProject(project)
            } else if let existing = controller.documents.first {
                existing.showWindows()
            } else {
                controller.newDocument(nil)
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !receivedExternalOpen && projectOpenTask == nil && NSDocumentController.shared.documents.isEmpty
            && projectHistory.recentProjects().isEmpty
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard !filenames.isEmpty else { return }
        receivedExternalOpen = true
        let pending = projectOpenTask
        pending?.cancel()
        Task {
            await pending?.value
            var failure: Error?
            for filename in filenames {
                do {
                    _ = try await NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: filename),
                                                                           display: true)
                } catch {
                    if failure == nil { failure = error }
                }
            }
            sender.reply(toOpenOrPrint: failure == nil ? .success : .failure)
            if let failure { sender.presentError(failure) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isFinishingQuit = true
        projectOpenTask?.cancel()
        if let project = projectBeforeQuit { projectHistory.record(project) }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        guard projectOpenTask == nil else { return false }
        if let project = projectHistory.recentProjects().first { openProject(project) }
        else { NSDocumentController.shared.newDocument(nil) }
        return false
    }

    func captureProjectBeforeQuit() {
        let current = projectOpenTask == nil ? workspace.flatMap(snapshot) : nil
        projectBeforeQuit = current ?? projectHistory.recentProjects().first
    }

    func noteProjectChanged(_ candidate: WorkspaceController) {
        guard !isFinishingQuit, projectOpenTask == nil, workspace === candidate,
              let project = snapshot(candidate) else { return }
        projectHistory.record(project)
    }

    @objc private func projectWindowBecameMain(_ notification: Notification) {
        if let candidate = (notification.object as? NSWindow)?.contentViewController as? WorkspaceController {
            noteProjectChanged(candidate)
        }
    }

    private func snapshot(_ workspace: WorkspaceController) -> ProjectHistory.Project? {
        guard let directory = workspace.projectDirectory else { return nil }
        return projectHistory.snapshot(directory: directory, activeFile: workspace.documentURL,
                                       openFiles: workspace.projectTabDocumentURLs)
    }

    @objc private func showEditorSettings(_ sender: Any?) {
        let settings = editorSettings ?? EditorSettingsController()
        editorSettings = settings
        settings.showWindow(sender)
        settings.window?.makeKeyAndOrderFront(sender)
    }

    @objc func newFile(_ sender: Any?) {
        let documents = NSDocumentController.shared
        guard let workspace, let tabs = workspace.documentTabs, tabs.documents.isEmpty else {
            documents.newDocument(sender)
            return
        }
        guard workspace.view.window?.attachedSheet == nil else { return }
        do {
            if let document = try documents.openUntitledDocumentAndDisplay(false) as? TeXDocument {
                document.prepareWorkspace(in: tabs)
                if let directory = workspace.projectDirectory { document.workspace?.useProjectDirectory(directory) }
                document.showWindows()
            }
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc func openFile(_ sender: Any?) {
        let current = workspace
        let window = current?.view.window
        guard window?.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = current?.projectDirectory
        panel.allowsMultipleSelection = true
        panel.delegate = projectOpenPanelDelegate
        Task { [weak current] in
            let response: NSApplication.ModalResponse
            if let window { response = await panel.beginSheetModal(for: window) }
            else { response = await panel.begin() }
            guard response == .OK else { return }
            for url in panel.urls {
                if let current, let directory = current.projectDirectory,
                   ProjectHistory.projectFile(url, in: ProjectHistory.normalized(directory)) != nil,
                   await openTab(url, in: current) != nil { continue }
                do {
                    _ = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
                } catch {
                    NSApp.presentError(error)
                }
            }
        }
    }

    @objc private func closeFile(_ sender: Any?) {
        if let window = auxiliaryKeyWindow {
            window.performClose(sender)
        } else {
            _ = workspace?.documentTabs?.closeActiveTab()
        }
    }

    @objc private func chooseProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Open Project Folder"
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = workspace?.projectDirectory
        let parent = NSApp.mainWindow
        Task {
            let response: NSApplication.ModalResponse
            if let parent { response = await panel.beginSheetModal(for: parent) }
            else { response = await panel.begin() }
            guard response == .OK, let directory = panel.url else { return }
            let project = projectHistory.recentProjects().first { $0.directory.path == ProjectHistory.normalized(directory).path }
                ?? projectHistory.snapshot(directory: directory, activeFile: nil, openFiles: [])
            if let project { openProject(project) }
        }
    }

    @objc private func openRecentProject(_ sender: NSMenuItem) {
        guard let directory = sender.representedObject as? URL,
              let project = projectHistory.recentProjects().first(where: { $0.directory.path == directory.path }) else { return }
        openProject(project)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentProjectsMenu else { return }
        menu.removeAllItems()
        addRecentProjects(to: menu, currentDirectory: nil)
    }

    func projectMenu(for directory: URL?) -> NSMenu {
        let menu = NSMenu()
        let choose = menu.addItem(withTitle: "Open Project Folder…", action: #selector(chooseProject(_:)), keyEquivalent: "")
        choose.target = self
        if let directory {
            let reveal = menu.addItem(withTitle: "Show Project in Finder", action: #selector(revealProject(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = directory
        }
        menu.addItem(.separator())
        addRecentProjects(to: menu, currentDirectory: directory)
        return menu
    }

    @objc private func revealProject(_ sender: NSMenuItem) {
        if let directory = sender.representedObject as? URL {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        }
    }

    private func addRecentProjects(to menu: NSMenu, currentDirectory: URL?) {
        let projects = projectHistory.recentProjects()
        if projects.isEmpty {
            let empty = NSMenuItem(title: "No Recent Projects", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        let matches = Dictionary(grouping: projects) { $0.directory.lastPathComponent }
        let currentPath = currentDirectory.map(ProjectHistory.normalized)?.path
        for project in projects {
            let folder = project.directory
            let name = folder.lastPathComponent
            let parent = (folder.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            let title = (matches[name]?.count ?? 0) > 1 ? "\(name) (\(parent))" : name
            let item = NSMenuItem(title: title, action: #selector(openRecentProject(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = folder
            item.toolTip = folder.path
            item.state = folder.path == currentPath ? .on : .off
            menu.addItem(item)
        }
    }

    private func openProject(_ project: ProjectHistory.Project) {
        guard projectOpenTask == nil else { return }
        if let window = NSApp.orderedWindows.first(where: { window in
            guard let workspace = window.contentViewController as? WorkspaceController,
                  let directory = workspace.projectDirectory else { return false }
            return ProjectHistory.normalized(directory).path == project.directory.path
        }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        projectOpenTask = Task {
            let restored = await restoreProject(project)
            let cancelled = Task.isCancelled
            projectOpenTask = nil
            if let restored, !cancelled, let session = snapshot(restored) { projectHistory.record(session) }
        }
    }

    private func restoreProject(_ project: ProjectHistory.Project) async -> WorkspaceController? {
        var current: WorkspaceController?
        for file in project.openFiles {
            guard !Task.isCancelled else { return nil }
            if let previous = current {
                if let opened = await openTab(file, in: previous) { current = opened }
            } else {
                current = await openProjectFile(file, directory: project.directory)
            }
        }
        if let current {
            guard !Task.isCancelled else { return nil }
            if let file = project.activeFile, current.documentURL.map(ProjectHistory.normalized)?.path != file.path {
                return await openTab(file, in: current) ?? current
            }
            return current
        }
        let main = ProjectBuildSession.mainFile(in: project.directory)
        for file in [main, ProjectHistory.firstDocument(in: project.directory)].compactMap({ $0 })
        where !project.openFiles.contains(file) {
            guard !Task.isCancelled else { return nil }
            if let opened = await openProjectFile(file, directory: project.directory) { return opened }
        }
        guard !Task.isCancelled else { return nil }
        do {
            let document = try NSDocumentController.shared.openUntitledDocumentAndDisplay(false)
            return showProjectDocument(document, directory: project.directory)
        } catch {
            NSApp.presentError(error)
            return nil
        }
    }

    private func openProjectFile(_ file: URL, directory: URL) async -> WorkspaceController? {
        guard let (document, alreadyOpen) = try? await NSDocumentController.shared
            .openDocument(withContentsOf: file, display: false) else { return nil }
        if Task.isCancelled {
            if !alreadyOpen, document.windowControllers.isEmpty { document.close() }
            return nil
        }
        return showProjectDocument(document, directory: directory)
    }

    private func showProjectDocument(_ document: NSDocument, directory: URL) -> WorkspaceController? {
        guard let document = document as? TeXDocument else { return nil }
        if let workspace = document.workspace,
           workspace.projectDirectory.map(ProjectHistory.normalized)?.path != directory.path { return nil }
        if document.workspace == nil { document.makeWindowControllers() }
        guard let workspace = document.workspace else { return nil }
        workspace.useProjectDirectory(directory)
        document.showWindows()
        return workspace
    }

    private func openTab(_ file: URL, in workspace: WorkspaceController) async -> WorkspaceController? {
        let controller = NSDocumentController.shared
        if let existing = controller.document(for: file) as? TeXDocument, let group = existing.tabs,
           let current = workspace.documentURL.flatMap({ controller.document(for: $0) }) as? TeXDocument,
           group !== current.tabs { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<WorkspaceController?, Never>) in
            workspace.openProjectFile(file, onOpened: { continuation.resume(returning: $0) },
                                      onFailure: { continuation.resume(returning: nil) })
        }
    }

    @objc private func compile(_ sender: Any?) { workspace?.compile(sender) }
    @objc private func showSourceInPDF(_ sender: Any?) { workspace?.showSourceInPDF() }
    @objc private func showBuildFiles(_ sender: Any?) { workspace?.showBuildFiles() }
    @objc private func cleanBuildFiles(_ sender: Any?) { workspace?.cleanBuildFiles() }
    @objc private func toggleAutoCompile(_ sender: Any?) { workspace?.toggleAutoCompile() }
    @objc private func searchProject(_ sender: Any?) { workspace?.showProjectSearch() }
    @objc private func quickOpen(_ sender: Any?) { workspace?.showQuickOpen() }
    @objc private func toggleComment(_ sender: Any?) { workspace?.toggleComment() }
    @objc private func completeCommand(_ sender: Any?) { workspace?.completeCommand() }
    @objc private func goToLine(_ sender: Any?) { workspace?.promptForLine() }
    @objc private func exportPDF(_ sender: Any?) { workspace?.exportPDF(sender) }
    @objc private func toggleSidebar(_ sender: Any?) { workspace?.toggleSidebar(sender) }
    @objc private func toggleLog(_ sender: Any?) { workspace?.toggleLog(sender) }
    @objc private func zoomIn(_ sender: Any?) { workspace?.zoomIn(sender) }
    @objc private func zoomOut(_ sender: Any?) { workspace?.zoomOut(sender) }
    @objc private func fitPDF(_ sender: Any?) { workspace?.fitPDF(sender) }

    @objc private func chooseEngine(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Choose the Tectonic Executable"
        panel.prompt = "Choose"
        panel.showsHiddenFiles = true
        if let path = UserDefaults.standard.string(forKey: Self.enginePathKey) {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        } else {
            panel.directoryURL = TectonicCompiler.findEngine()?.deletingLastPathComponent()
        }
        let window = NSApp.mainWindow
        Task {
            let result: NSApplication.ModalResponse
            if let window {
                result = await panel.beginSheetModal(for: window)
            } else {
                result = await panel.begin()
            }
            guard result == .OK, let url = panel.url else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) else {
                let alert = NSAlert()
                alert.messageText = "The selected file cannot be run"
                alert.informativeText = "Choose an executable Tectonic binary."
                if let window {
                    _ = await alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
                return
            }
            UserDefaults.standard.set(url.path, forKey: Self.enginePathKey)
        }
    }

    @objc private func resetEngine(_ sender: Any?) {
        UserDefaults.standard.removeObject(forKey: Self.enginePathKey)
    }

    @objc private func chooseAppearance(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let appearance = Appearance(rawValue: value) else { return }
        UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey)
        NSApp.appearance = appearance.appKit
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(chooseAppearance(_:)) {
            item.state = (item.representedObject as? String) == selectedAppearance.rawValue ? .on : .off
        }
        if item.action == #selector(toggleSidebar(_:)) {
            item.state = workspace?.isSidebarVisible == true ? .on : .off
        }
        if item.action == #selector(toggleAutoCompile(_:)) {
            item.state = workspace?.isAutoCompiling == true ? .on : .off
        }
        if item.action == #selector(closeFile(_:)) {
            if let window = auxiliaryKeyWindow {
                item.title = "Close Window"
                return window.standardWindowButton(.closeButton)?.isEnabled == true
            }
            item.title = "Close File"
            return workspace?.hasActiveDocument == true
        }
        return switch item.action {
        case #selector(compile(_:)): workspace?.canCompile == true
        case #selector(showSourceInPDF(_:)): workspace?.canShowSourceInPDF == true
        case #selector(showBuildFiles(_:)): workspace?.buildFilesDirectory != nil
        case #selector(cleanBuildFiles(_:)): workspace?.canCleanBuildFiles == true
        case #selector(exportPDF(_:)): workspace?.canExport == true
        case #selector(zoomIn(_:)): workspace?.canZoomIn == true
        case #selector(zoomOut(_:)): workspace?.canZoomOut == true
        case #selector(fitPDF(_:)): workspace?.canExport == true
        case #selector(searchProject(_:)), #selector(quickOpen(_:)): workspace?.canSearchProject == true
        case #selector(toggleSidebar(_:)): workspace != nil
        case #selector(toggleLog(_:)), #selector(toggleAutoCompile(_:)): workspace?.hasBuildTarget == true
        case #selector(toggleComment(_:)), #selector(completeCommand(_:)): workspace?.canUseLaTeXCommands == true
        case #selector(goToLine(_:)): workspace?.canEditSource == true
        case #selector(resetEngine(_:)): UserDefaults.standard.string(forKey: Self.enginePathKey) != nil
        default: true
        }
    }

    func installMenus() {
        NSApp.appearance = selectedAppearance.appKit
        let bar = NSMenu()
        NSApp.mainMenu = bar

        func menu(_ title: String) -> NSMenu {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            bar.addItem(top)
            top.submenu = submenu
            return submenu
        }

        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                 target: AnyObject? = nil, modifiers: NSEvent.ModifierFlags = [.command]) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            menu.addItem(item)
        }

        let app = menu(AppIdentity.displayName)
        add(app, "About \(AppIdentity.displayName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        add(app, "Settings…", #selector(showEditorSettings(_:)), ",", target: self)
        app.addItem(.separator())
        add(app, "Hide \(AppIdentity.displayName)", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
            modifiers: [.command, .option])
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "Quit \(AppIdentity.displayName)", #selector(NSApplication.terminate(_:)), "q")

        let file = menu("File")
        add(file, "New", #selector(newFile(_:)), "n", target: self)
        add(file, "Open…", #selector(openFile(_:)), "o", target: self)
        add(file, "Quick Open…", #selector(quickOpen(_:)), "p", target: self)
        add(file, "Open Project Folder…", #selector(chooseProject(_:)), "o",
            target: self, modifiers: [.command, .shift])
        let recent = NSMenuItem(title: "Recent Projects", action: nil, keyEquivalent: "")
        recentProjectsMenu.delegate = self
        recent.submenu = recentProjectsMenu
        file.addItem(recent)
        file.addItem(.separator())
        add(file, "Close File", #selector(closeFile(_:)), "w", target: self)
        add(file, "Save", #selector(NSDocument.save(_:)), "s")
        add(file, "Save As…", #selector(NSDocument.saveAs(_:)), "s", modifiers: [.command, .shift])
        add(file, "Export PDF…", #selector(exportPDF(_:)), "e", target: self, modifiers: [.command, .shift])

        let edit = menu("Edit")
        add(edit, "Undo", NSSelectorFromString("undo:"), "z")
        add(edit, "Redo", NSSelectorFromString("redo:"), "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        let find = NSMenuItem(title: "Find…", action: #selector(NSResponder.performTextFinderAction(_:)),
                              keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        edit.addItem(find)
        add(edit, "Find in Project…", #selector(searchProject(_:)), "f", target: self, modifiers: [.command, .shift])
        add(edit, "Go to Line…", #selector(goToLine(_:)), "l", target: self, modifiers: [.command, .shift])
        add(edit, "Toggle Line Comment", #selector(toggleComment(_:)), "/", target: self)
        add(edit, "Complete LaTeX Command", #selector(completeCommand(_:)), "\u{1b}", target: self, modifiers: [.option])

        let build = menu("Build")
        add(build, "Compile PDF", #selector(compile(_:)), "r", target: self)
        add(build, "Show Source in PDF", #selector(showSourceInPDF(_:)), "j", target: self, modifiers: [.command, .shift])
        add(build, "Auto Compile", #selector(toggleAutoCompile(_:)), target: self)
        add(build, "Toggle Build Log", #selector(toggleLog(_:)), "l", target: self)
        build.addItem(.separator())
        add(build, "Show Build Files in Finder", #selector(showBuildFiles(_:)), target: self)
        add(build, "Clean Build Files", #selector(cleanBuildFiles(_:)), target: self)
        build.addItem(.separator())
        add(build, "Choose Tectonic…", #selector(chooseEngine(_:)), target: self)
        add(build, "Find Tectonic Automatically", #selector(resetEngine(_:)), target: self)

        let view = menu("View")
        add(view, "Show Sidebar", #selector(toggleSidebar(_:)), "s", target: self, modifiers: [.command, .option])
        let appearanceMenu = NSMenu(title: "Appearance")
        for appearance in Appearance.allCases {
            let item = appearanceMenu.addItem(withTitle: appearance.rawValue, action: #selector(chooseAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = appearance.rawValue
            item.state = appearance == selectedAppearance ? .on : .off
        }
        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearance.submenu = appearanceMenu
        view.addItem(appearance)
        view.addItem(.separator())
        add(view, "Zoom In", #selector(zoomIn(_:)), "=", target: self)
        add(view, "Zoom Out", #selector(zoomOut(_:)), "-", target: self)
        add(view, "Fit PDF to Window", #selector(fitPDF(_:)), "0", target: self)
        view.addItem(.separator())
        add(view, "Toggle Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])

        let window = menu("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        add(window, "Select Next Tab", #selector(NSWindow.selectNextTab(_:)), "\t", modifiers: [.control])
        add(window, "Select Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "\t", modifiers: [.control, .shift])
        window.addItem(.separator())
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = window
    }
}
