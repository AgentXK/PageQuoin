import CoreGraphics
import Darwin
import Foundation

struct CompilationResult: Sendable {
    let pdfData: Data
    let log: String
    let diagnostics: [BuildDiagnostic]
    let syncTeX: SyncTeXMap?
    let exportedPDF: URL?
    let pdfExportWarning: String?
}

enum TectonicError: LocalizedError {
    case engineNotFound
    case invalidEngine(URL)
    case failed(status: Int32, log: String, diagnostics: [BuildDiagnostic])
    case missingPDF(log: String, diagnostics: [BuildDiagnostic])

    var errorDescription: String? {
        switch self {
        case .engineNotFound:
            "Tectonic was not found. Install it with brew install tectonic or choose its executable from the Build menu."
        case let .invalidEngine(url):
            "Could not run the selected Tectonic executable at \(url.path)."
        case let .failed(status, _, _):
            "Tectonic failed with exit code \(status)."
        case .missingPDF:
            "Tectonic finished without generating a PDF. Check that the document contains typeset material."
        }
    }

    var log: String? {
        switch self {
        case let .failed(_, log, _), let .missingPDF(log, _): log
        default: nil
        }
    }

    var diagnostics: [BuildDiagnostic] {
        switch self {
        case let .failed(_, _, diagnostics), let .missingPDF(_, diagnostics): diagnostics
        default: []
        }
    }
}

struct TectonicCompiler {
    static func siblingPDFURL(for target: URL) -> URL? {
        guard target.isFileURL, ["tex", "ltx"].contains(target.pathExtension.lowercased()) else { return nil }
        return target.deletingPathExtension().appendingPathExtension("pdf")
    }

    static func buildArtifactDirectory(in projectRoot: URL) -> URL? {
        BuildArtifactStore.shared.existingDirectory(in: projectRoot)
    }

    static func hasBuildArtifacts(in projectRoot: URL) -> Bool {
        buildArtifactDirectory(in: projectRoot) != nil
    }

    static func cleanBuildArtifacts(in projectRoot: URL) throws {
        try BuildArtifactStore.shared.clear(in: projectRoot)
    }

    static func findEngine() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["TECTONIC_PATH"], !path.isEmpty {
            let override = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if isExecutable(override) { return override }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        let installDirectories = [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/local/bin", isDirectory: true),
            home.appendingPathComponent(".cargo/bin", isDirectory: true),
            home.appendingPathComponent(".local/bin", isDirectory: true),
            home.appendingPathComponent("bin", isDirectory: true),
        ]
        return (pathDirectories + installDirectories)
            .map { $0.appendingPathComponent("tectonic", isDirectory: false) }
            .first(where: isExecutable)
    }

    static func compile(
        source: String, fileURL: URL?, engineURL: URL?,
        projectRoot: URL? = nil, unsavedSources: [URL: String] = [:]
    ) async throws -> CompilationResult {
        let run = CompilationRun()
        let result: CompilationResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try compileSnapshot(
                            source: source, fileURL: fileURL, engineURL: engineURL,
                            projectRoot: projectRoot, unsavedSources: unsavedSources, run: run
                        )
                    })
                }
            }
        } onCancel: {
            run.cancel()
        }
        try Task.checkCancellation()
        return result
    }

    private static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
            && (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func compileSnapshot(
        source: String, fileURL: URL?, engineURL: URL?,
        projectRoot: URL?, unsavedSources: [URL: String], run: CompilationRun
    ) throws -> CompilationResult {
        try run.checkCancellation()
        guard let engine = engineURL ?? findEngine() else { throw TectonicError.engineNotFound }
        guard isExecutable(engine) else { throw TectonicError.invalidEngine(engine) }

        let export = fileURL.flatMap(siblingPDFURL(for:)).map { destination in
            Result { try SiblingPDFExport(destination: destination) }
        }

        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("LocalTeX-\(UUID())", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }

        let resultDirectory = directory.appendingPathComponent("output", isDirectory: true)
        try files.createDirectory(at: resultDirectory, withIntermediateDirectories: false)
        let snapshot = directory.appendingPathComponent("source.tex")
        try Data(source.utf8).write(to: snapshot)
        let logURL = resultDirectory.appendingPathComponent("tectonic-output.log")
        try Data().write(to: logURL)
        let input = try FileHandle(forReadingFrom: snapshot)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: logURL)
        defer { try? output.close() }

        let stagedProject = directory.appendingPathComponent("project", isDirectory: true)
        let overlay = ProjectOverlay(source: source, fileURL: fileURL, root: projectRoot, unsavedSources: unsavedSources)
        let workingDirectory = try overlay?.stage(at: stagedProject, run: run)
            ?? fileURL?.deletingLastPathComponent() ?? directory

        // Standard input keeps the main buffer's job name independent of the working directory.
        let process = Process()
        process.executableURL = engine
        process.currentDirectoryURL = workingDirectory
        process.arguments = [
            "--untrusted", "--color", "never", "--keep-intermediates", "--keep-logs",
            "--synctex", "--outdir", resultDirectory.path, "-"
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try run.start(process)
        try run.waitForExit(process)

        let engineLog = String(decoding: try Data(contentsOf: logURL), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let log = overlay?.originalPaths(in: engineLog, stagedAt: stagedProject) ?? engineLog
        let transcript = readLog("texput.log", from: resultDirectory)
        let bibliographyLog = readLog("texput.blg", from: resultDirectory)
        var diagnostics = TectonicDiagnostics(target: fileURL, projectRoot: projectRoot).parse(
            output: log, transcript: overlay?.originalPaths(in: transcript, stagedAt: stagedProject) ?? transcript,
            bibliographyLog: bibliographyLog
        )
        let pdfURL = resultDirectory.appendingPathComponent("texput.pdf")
        guard process.terminationStatus == 0 else {
            throw TectonicError.failed(status: process.terminationStatus, log: log, diagnostics: diagnostics)
        }
        guard let pdf = try? Data(contentsOf: pdfURL), pdf.starts(with: "%PDF-".utf8),
              let document = CGPDFDocument(pdfURL as CFURL), document.numberOfPages > 0 else {
            throw TectonicError.missingPDF(log: log, diagnostics: diagnostics)
        }
        let syncTeX = ["texput.synctex.gz", "texput.synctex"].lazy
            .compactMap { try? Data(contentsOf: resultDirectory.appendingPathComponent($0), options: .mappedIfSafe) }
            .first.flatMap {
                SyncTeXMap(data: $0, mainFile: fileURL, workingDirectory: workingDirectory,
                           stagedProjectRoot: overlay == nil ? nil : stagedProject,
                           originalProjectRoot: overlay?.root ?? projectRoot)
            }
        var exportedPDF: URL?
        var pdfExportWarning: String?
        if let export {
            do {
                let destination = try export.get()
                try destination.publish(pdf, run: run)
                exportedPDF = destination.url
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let warning = "Could not save the PDF beside the main document. \(error.localizedDescription)"
                pdfExportWarning = warning
                diagnostics.append(BuildDiagnostic(severity: .warning, message: warning))
            }
        }
        return CompilationResult(pdfData: pdf, log: log, diagnostics: diagnostics, syncTeX: syncTeX,
                                 exportedPDF: exportedPDF, pdfExportWarning: pdfExportWarning)
    }

    private static func readLog(_ name: String, from directory: URL) -> String {
        let url = directory.appendingPathComponent(name)
        guard let reader = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? reader.close() }
        let data = (try? reader.read(upToCount: 8 * 1024 * 1024)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

private final class SiblingPDFExport {
    let url: URL
    private let folder: URL
    private let descriptor: Int32

    init(destination: URL) throws {
        url = destination
        folder = destination.deletingLastPathComponent()
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.posixError() }
        self.descriptor = descriptor
    }

    deinit {
        _ = close(descriptor)
    }

    func publish(_ pdf: Data, run: CompilationRun) throws {
        try run.checkCancellation()
        try requireOriginalFolder()
        let staged = ".pagequoin-pdf-\(UUID())"
        let output = openat(descriptor, staged, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o666))
        guard output >= 0 else { throw Self.posixError() }
        defer { _ = unlinkat(descriptor, staged, 0) }
        let handle = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        try handle.write(contentsOf: pdf)
        try handle.close()

        try run.commit {
            try requireOriginalFolder()
            let name = url.lastPathComponent
            var destination = stat()
            if fstatat(descriptor, name, &destination, AT_SYMLINK_NOFOLLOW) == 0 {
                guard destination.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [
                        NSLocalizedDescriptionKey: "The output path “\(name)” is occupied by a non-regular file."
                    ])
                }
                guard renameat(descriptor, staged, descriptor, name) == 0 else { throw Self.posixError() }
            } else {
                guard errno == ENOENT else { throw Self.posixError() }
                guard renameatx_np(descriptor, staged, descriptor, name, UInt32(RENAME_EXCL)) == 0 else {
                    throw Self.posixError()
                }
            }
        }
    }

    private func requireOriginalFolder() throws {
        // The descriptor keeps operations in the original folder if its path moves.
        var original = stat()
        var current = stat()
        guard fstat(descriptor, &original) == 0 else { throw Self.posixError() }
        guard lstat(folder.path, &current) == 0,
              original.st_dev == current.st_dev, original.st_ino == current.st_ino else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "The main document folder changed during compilation."
            ])
        }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private struct ProjectOverlay {
    let root: URL
    let mainPath: [String]
    let sources: [[String]: String]

    init?(source: String, fileURL: URL?, root: URL?, unsavedSources: [URL: String]) {
        guard !unsavedSources.isEmpty, let fileURL else { return nil }
        let root = (root ?? fileURL.deletingLastPathComponent()).resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.pathComponents

        func relativePath(_ url: URL) -> [String]? {
            guard url.isFileURL else { return nil }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard path.count > rootPath.count, path.starts(with: rootPath) else { return nil }
            return Array(path.dropFirst(rootPath.count))
        }

        guard let mainPath = relativePath(fileURL) else { return nil }
        var sources: [[String]: String] = [:]
        for (url, buffer) in unsavedSources {
            if let path = relativePath(url), path != mainPath {
                sources[path] = buffer
            }
        }
        guard !sources.isEmpty else { return nil }
        sources[mainPath] = source
        self.root = root
        self.mainPath = mainPath
        self.sources = sources
    }

    func stage(at destination: URL, run: CompilationRun) throws -> URL {
        let files = FileManager.default
        var directories: Set<[String]> = [[]]
        for path in sources.keys {
            for depth in 1..<path.count {
                directories.insert(Array(path.prefix(depth)))
            }
        }

        // Write the buffers before making links so writes never follow a link
        // back into the user's project, even on a case-insensitive volume.
        for path in directories {
            try run.checkCancellation()
            let staged = url(in: destination, path: path, isDirectory: true)
            try files.createDirectory(at: staged, withIntermediateDirectories: true)
        }
        for (path, source) in sources {
            try run.checkCancellation()
            try Data(source.utf8).write(to: url(in: destination, path: path, isDirectory: false), options: .withoutOverwriting)
        }

        // Paths that are not materialized stay accessible through links.
        for path in directories {
            try run.checkCancellation()
            let staged = url(in: destination, path: path, isDirectory: true)
            let original = url(in: root, path: path, isDirectory: true)
            let entries = try files.contentsOfDirectory(at: original, includingPropertiesForKeys: nil)
            for entry in entries {
                if path.isEmpty && entry.lastPathComponent == BuildArtifactStore.folderName { continue }
                try run.checkCancellation()
                let link = staged.appendingPathComponent(entry.lastPathComponent)
                do {
                    try files.createSymbolicLink(at: link, withDestinationURL: entry)
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    // This path is already represented by a buffer or a staged directory.
                }
            }
        }
        return url(in: destination, path: Array(mainPath.dropLast()), isDirectory: true)
    }

    func originalPaths(in log: String, stagedAt destination: URL) -> String {
        log.replacingOccurrences(of: destination.resolvingSymlinksInPath().path, with: root.path)
            .replacingOccurrences(of: destination.path, with: root.path)
    }

    private func url(in base: URL, path: [String], isDirectory: Bool) -> URL {
        guard !path.isEmpty else { return base }
        return base.appendingPathComponent(path.joined(separator: "/"), isDirectory: isDirectory)
    }
}

// Cancellation shares the lock with launch so a cancellation cannot miss a running child.
private final class CompilationRun: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func checkCancellation() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }

    func start(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
        self.process = process
    }

    func waitForExit(_ process: Process) throws {
        process.waitUntilExit()
        lock.lock()
        defer { lock.unlock() }
        self.process = nil
        if cancelled { throw CancellationError() }
    }

    func commit(_ operation: () throws -> Void) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try operation()
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}
