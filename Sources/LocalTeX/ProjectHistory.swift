import Foundation

struct ProjectHistory {
    struct Project: Codable, Equatable {
        let directory: URL
        let activeFile: URL?
        let openFiles: [URL]
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
        let projects = saved.compactMap { snapshot(directory: $0.directory, activeFile: $0.activeFile,
                                                     openFiles: $0.openFiles) }
        if saved != projects { save(projects) }
        return projects
    }

    func snapshot(directory: URL, activeFile: URL?, openFiles: [URL]) -> Project? {
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
        return Project(directory: directory, activeFile: activeFile, openFiles: files)
    }

    func record(_ project: Project) {
        var projects = recentProjects().filter { $0.directory.path != project.directory.path }
        projects.insert(project, at: 0)
        save(Array(projects.prefix(Self.capacity)))
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
