import Foundation

final class ProjectHistory {
    struct EditorPosition: Codable, Equatable {
        let caretOffset: Int
        let scrollY: CGFloat
        let caretWasVisible: Bool?
        let upstreamAffinity: Bool?
        var normalizedCaretOffset: Int?
    }

    struct PDFPosition: Codable, Equatable {
        let target: URL
        let viewport: PreviewPDFView.SavedViewport
    }

    struct WorkspaceState: Codable, Equatable {
        let layout: WorkspaceLayout
        let sidebarWidth: CGFloat?
        let sidebarCollapsed: Bool
        let editorFraction: CGFloat?
        let pdf: PDFPosition?
    }

    struct Project: Codable, Equatable {
        let directory: URL
        let activeFile: URL?
        let openFiles: [URL]
        let editorPositions: [String: EditorPosition]?
        let workspaceState: WorkspaceState?
    }

    private let defaults: UserDefaults
    private let shared = SharedProjectStore()
    @MainActor private var acceptedSessions: [String: SharedProjectStore.Session] = [:]
    private let key = "RecentProjects"
    private static let capacity = 12

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    @MainActor
    func recentProjects() -> [Project] {
        let sessions = shared.sessions().sorted { left, right in
            if left.updatedAt == right.updatedAt { return left.root < right.root }
            return left.updatedAt > right.updatedAt
        }
        var roots = Set<String>()
        var projects: [Project] = []
        for session in sessions {
            guard let project = restore(session) else { continue }
            let root = SharedProjectStore.canonicalPath(project.directory)
            guard roots.insert(root).inserted else { continue }
            projects.append(project)
        }
        let legacy = legacyProjects()
        for (index, project) in legacy.enumerated() {
            let root = SharedProjectStore.canonicalPath(project.directory)
            guard roots.insert(root).inserted, shared.removedAt(for: project.directory) == nil else { continue }
            projects.append(project)
            let timestamp = Int64(legacy.count - index)
            _ = writeShared(project, updatedAt: timestamp, ifMissing: true)
        }
        return Array(projects.prefix(Self.capacity))
    }

    private func legacyProjects() -> [Project] {
        guard shared.usesDefaultDirectory else { return [] }
        guard let data = defaults.data(forKey: key),
              let saved = try? PropertyListDecoder().decode([Project].self, from: data) else { return [] }
        let projects = saved.compactMap {
            snapshot(directory: $0.directory, activeFile: $0.activeFile, openFiles: $0.openFiles,
                     editorPositions: $0.editorPositions ?? [:], workspaceState: $0.workspaceState)
        }
        if saved != projects { save(projects) }
        return projects
    }

    func snapshot(directory: URL, activeFile: URL?, openFiles: [URL],
                  editorPositions: [String: EditorPosition] = [:], workspaceState: WorkspaceState? = nil) -> Project? {
        guard directory.isFileURL else { return nil }
        let directory = Self.normalized(directory)
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }

        let activeFile = activeFile.flatMap { Self.projectFile($0, in: directory) }
        var files: [URL] = []
        var paths = Set<String>()
        for file in openFiles {
            if let file = Self.projectFile(file, in: directory), paths.insert(file.path).inserted {
                files.append(file)
            }
        }
        if let activeFile, paths.insert(activeFile.path).inserted { files.append(activeFile) }
        let positions = editorPositions.filter { paths.contains($0.key) }
        return Project(directory: directory, activeFile: activeFile, openFiles: files,
                       editorPositions: positions.isEmpty ? nil : positions, workspaceState: workspaceState)
    }

    @MainActor
    func record(_ project: Project, replacingShared: Bool = false, reopeningAfter removal: Int64? = nil) {
        guard writeShared(project, replacingShared: replacingShared, reopeningAfter: removal) else { return }
        guard shared.usesDefaultDirectory else { return }
        var projects = legacyProjects().filter { $0.directory.path != project.directory.path }
        projects.insert(project, at: 0)
        save(Array(projects.prefix(Self.capacity)))
    }

    @MainActor
    func update(_ project: Project) {
        if shared.session(for: project.directory) != nil {
            guard writeShared(project, refreshRecency: false) else { return }
        } else if shared.removedAt(for: project.directory) != nil {
            return
        }
        guard shared.usesDefaultDirectory else { return }
        var projects = legacyProjects()
        guard let index = projects.firstIndex(where: { $0.directory == project.directory }) else { return }
        projects[index] = project
        save(projects)
    }

    func removedAt(for directory: URL) -> Int64? {
        shared.removedAt(for: directory)
    }

    @MainActor
    func remove(_ directory: URL) throws {
        try shared.removeFromHistory(directory)
        let root = SharedProjectStore.canonicalPath(directory)
        acceptedSessions.removeValue(forKey: root)
        if shared.usesDefaultDirectory {
            save(legacyProjects().filter { SharedProjectStore.canonicalPath($0.directory) != root })
        }
    }

    private func restore(_ session: SharedProjectStore.Session) -> Project? {
        let root = URL(fileURLWithPath: session.root, isDirectory: true)
        guard SharedProjectStore.canonicalPath(root) == session.root else { return nil }
        var files: [URL] = []
        var positions: [String: EditorPosition] = [:]
        for tab in session.tabs {
            guard let file = SharedProjectStore.fileURL(tab.file, in: root) else { continue }
            files.append(file)
            guard ProjectFileKind.detect(for: file)?.isEditable == true else { continue }
            if var position = tab.desktopPosition, (position.normalizedCaretOffset ?? position.caretOffset) == tab.cursor {
                position.normalizedCaretOffset = tab.cursor
                positions[file.path] = position
            } else {
                positions[file.path] = .init(caretOffset: tab.cursor, scrollY: 0, caretWasVisible: true,
                                             upstreamAffinity: nil, normalizedCaretOffset: tab.cursor)
            }
        }
        let active = session.active.flatMap { SharedProjectStore.fileURL($0, in: root) }
        return snapshot(directory: root, activeFile: active, openFiles: files, editorPositions: positions,
                        workspaceState: session.desktopWorkspace)
    }

    @MainActor
    private func writeShared(_ project: Project, updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
                             ifMissing: Bool = false, refreshRecency: Bool = true, replacingShared: Bool = false,
                             reopeningAfter observedRemoval: Int64? = nil) -> Bool {
        let directory = project.directory
        let root = SharedProjectStore.canonicalPath(directory)
        let removal = shared.removedAt(for: directory)
        let previous = shared.session(for: directory)
        if let removal, previous == nil, (ifMissing || observedRemoval != removal) { return false }
        // A still-open window must not erase a newer Terminal handoff when it becomes active again.
        if !ifMissing, !replacingShared, let previous, acceptedSessions[root] != previous { return false }
        let previousTabs = Dictionary((previous?.tabs ?? []).map { ($0.file, $0) }, uniquingKeysWith: { first, _ in first })
        let tabs = project.openFiles.compactMap { file -> SharedProjectStore.Tab? in
            guard let relative = SharedProjectStore.relativePath(file, in: directory) else { return nil }
            let old = previousTabs[relative]
            var position = project.editorPositions?[file.path]
            if ifMissing, let raw = position?.caretOffset, position?.normalizedCaretOffset == nil,
               let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.contains(13),
               let source = ProjectTextEncoding.decode(data)?.text {
                position?.normalizedCaretOffset = SharedProjectStore.normalizedCaretOffset(raw, in: source)
            }
            let cursor = position?.normalizedCaretOffset ?? position?.caretOffset ?? old?.cursor ?? 0
            let sameCursor = old?.cursor == cursor
            let desktopOnly = ProjectFileKind.detect(for: file)?.isEditable == false
            return .init(file: relative, cursor: cursor, top: sameCursor ? old?.top ?? 0 : 0,
                         left: sameCursor ? old?.left ?? 0 : 0, wrapStart: sameCursor ? old?.wrapStart : nil,
                         desktopPosition: position, desktopOnly: desktopOnly ? true : nil)
        }
        let main = ProjectBuildSession.mainFile(in: directory).flatMap { SharedProjectStore.relativePath($0, in: directory) }
        let active = project.activeFile.flatMap { SharedProjectStore.relativePath($0, in: directory) }
        if !refreshRecency, let previous, previous.main == main, previous.active == active, previous.tabs == tabs,
           previous.desktopWorkspace == project.workspaceState { return true }
        let timestamp = max(updatedAt, removal.map { $0 + 1 } ?? 0)
        let session = SharedProjectStore.Session(root: root, main: main, active: active, tabs: tabs,
                                                 pdf: previous?.pdf, updatedAt: timestamp,
                                                 desktopWorkspace: project.workspaceState)
        guard shared.removedAt(for: directory) == removal,
              (try? shared.save(session, ifMissing: ifMissing)) != nil else { return false }
        if !ifMissing { acceptedSessions[root] = session }
        return true
    }

    static func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func projectFile(_ url: URL, in directory: URL) -> URL? {
        guard ProjectFileKind.detect(for: url) != nil else { return nil }
        let file = normalized(url)
        let root = directory.pathComponents
        guard file.pathComponents.count > root.count, file.pathComponents.starts(with: root),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return file
    }

    static func firstDocument(in directory: URL) -> URL? {
        let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: [.isRegularFileKey],
                                                                 options: [.skipsHiddenFiles])
        let candidates = (files ?? []).compactMap { projectFile($0, in: directory) }
        return candidates.min { a, b in
            let aIsLaTeX = ProjectFileKind.detect(for: a) == .latex
            let bIsLaTeX = ProjectFileKind.detect(for: b) == .latex
            if aIsLaTeX != bIsLaTeX { return aIsLaTeX }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }

    private func save(_ projects: [Project]) {
        if let data = try? PropertyListEncoder().encode(projects), defaults.data(forKey: key) != data {
            defaults.set(data, forKey: key)
        }
    }
}
