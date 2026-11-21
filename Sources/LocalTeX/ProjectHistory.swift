import Foundation

struct ProjectHistory {
    struct EditorPosition: Codable, Equatable {
        let caretOffset: Int
        let scrollY: CGFloat
        let caretWasVisible: Bool?
        let upstreamAffinity: Bool?
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
    private let key = "RecentProjects"
    private static let capacity = 12

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func recentProjects() -> [Project] {
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

    func record(_ project: Project) {
        var projects = recentProjects().filter { $0.directory.path != project.directory.path }
        projects.insert(project, at: 0)
        save(Array(projects.prefix(Self.capacity)))
    }

    func update(_ project: Project) {
        var projects = recentProjects()
        guard let index = projects.firstIndex(where: { $0.directory == project.directory }) else { return }
        projects[index] = project
        save(projects)
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
