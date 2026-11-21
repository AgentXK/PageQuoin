import Foundation

enum ProjectImageImport {
    struct Result: Sendable {
        let paths: [String]
        let failures: [String]
    }

    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "pdf"]
    private static let fileNameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    private static let pathCharacters = fileNameCharacters.union(CharacterSet.nonBaseCharacters)
        .union(CharacterSet(charactersIn: "/ ()+"))

    static func supports(_ file: URL) -> Bool {
        file.isFileURL && extensions.contains(file.pathExtension.lowercased())
    }

    static func add(_ dropped: [URL], to directory: URL, relativeTo workingDirectory: URL) -> Result {
        let root = normalized(directory)
        let workingDirectory = normalized(workingDirectory)
        let buildFolder = root.appendingPathComponent(BuildArtifactStore.folderName, isDirectory: true)
        var paths: [String] = []
        var failures: [String] = []
        var seen: Set<URL> = []
        for droppedFile in dropped {
            let file = normalized(droppedFile)
            guard seen.insert(file).inserted else { continue }
            do {
                guard supports(file), (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                    throw ImportError.invalidImage
                }
                let path = relativePath(to: file, from: workingDirectory)
                if isInside(file, directory: root), !isInside(file, directory: buildFolder), isUsablePath(path) {
                    paths.append(path)
                } else {
                    paths.append(try copy(file, toFiguresIn: root, relativeTo: workingDirectory))
                }
            } catch {
                failures.append("\(droppedFile.lastPathComponent) — \(error.localizedDescription)")
            }
        }
        return Result(paths: paths, failures: failures)
    }

    private static func copy(_ file: URL, toFiguresIn root: URL, relativeTo workingDirectory: URL) throws -> String {
        let manager = FileManager.default
        let location = root.appendingPathComponent("figures", isDirectory: true)
        do {
            try manager.createDirectory(at: location, withIntermediateDirectories: false)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // Use the existing folder after validating it below.
        }
        let figures = normalized(location)
        guard isInside(figures, directory: root),
              (try figures.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw ImportError.invalidFiguresFolder
        }

        let stem = safeStem(file.deletingPathExtension().lastPathComponent)
        let ext = file.pathExtension.lowercased()
        for index in 1...1000 {
            let name = index == 1 ? stem : "\(stem)-\(index)"
            let destination = figures.appendingPathComponent("\(name).\(ext)")
            let path = relativePath(to: destination, from: workingDirectory)
            guard isUsablePath(path) else { throw ImportError.unsupportedPath }
            do {
                try manager.copyItem(at: file, to: destination)
                return path
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw ImportError.tooManyCopies
    }

    private static func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isInside(_ file: URL, directory: URL) -> Bool {
        let root = directory.pathComponents
        return file.pathComponents.count > root.count && file.pathComponents.starts(with: root)
    }

    private static func relativePath(to file: URL, from directory: URL) -> String {
        let base = directory.pathComponents
        let target = file.pathComponents
        let shared = zip(base, target).prefix { $0.0 == $0.1 }.count
        return (Array(repeating: "..", count: base.count - shared) + target.dropFirst(shared)).joined(separator: "/")
    }

    private static func isUsablePath(_ path: String) -> Bool {
        path.unicodeScalars.allSatisfy(pathCharacters.contains)
            && !path.split(separator: "/").contains { $0.first == " " || $0.last == " " }
    }

    private static func safeStem(_ name: String) -> String {
        let parts = name.components(separatedBy: fileNameCharacters.inverted).filter { !$0.isEmpty }
        let limited = String(String.UnicodeScalarView(parts.joined(separator: "-").unicodeScalars.prefix(56)))
        let stem = limited.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return stem.isEmpty ? "figure" : stem
    }

    private enum ImportError: LocalizedError {
        case invalidImage, invalidFiguresFolder, unsupportedPath, tooManyCopies

        var errorDescription: String? {
            switch self {
            case .invalidImage: "Choose a regular PNG, JPEG, or PDF file."
            case .invalidFiguresFolder: "The figures folder must be a directory inside the project."
            case .unsupportedPath: "The project path contains characters that cannot be inserted into a LaTeX filename."
            case .tooManyCopies: "No unused name was found in the figures folder."
            }
        }
    }
}
