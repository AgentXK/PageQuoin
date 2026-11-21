import AppKit
import PDFKit

@MainActor
final class ProjectBuildSession {
    enum Phase {
        case ready
        case building
        case stopping
        case stopped
        case complete
        case outdated
        case failed
    }

    struct Preview {
        let data: Data
        let document: PDFDocument
        let syncTeX: SyncTeXMap?
    }

    private static let sessions = NSMapTable<NSString, ProjectBuildSession>(keyOptions: .strongMemory,
                                                                           valueOptions: .weakMemory)
    private static let mainKey = "ProjectMainDocuments"
    private static let autoKey = "AutomaticBuildTargets"
    private let workspaces = NSHashTable<WorkspaceController>.weakObjects()
    private weak var untitledDocument: TeXDocument?
    private let root: URL?
    let target: URL?

    private var compileTask: Task<Void, Never>?
    private var automaticTask: Task<Void, Never>?
    private var compileAgain = false
    private var revision = 0
    private(set) var phase = Phase.ready
    private(set) var preview: Preview?
    private(set) var log = "No build log yet."
    private(set) var artifactWarning: String?
    private(set) var diagnostics: [BuildDiagnostic] = []
    private(set) var automatic = false
    var isBuilding: Bool { phase == .building || phase == .stopping }

    private init(root: URL?, target: URL?, untitledDocument: TeXDocument? = nil) {
        self.root = root
        self.target = target
        if let target {
            automatic = UserDefaults.standard.dictionary(forKey: Self.autoKey)?[target.path] as? Bool ?? false
        } else {
            self.untitledDocument = untitledDocument
        }
    }

    deinit {
        automaticTask?.cancel()
        compileTask?.cancel()
    }

    static func shared(root: URL?, target: URL) -> ProjectBuildSession {
        let root = root.map(normalized)
        let target = normalized(target)
        let key = "\(root?.path ?? "")\u{0}\(target.path)" as NSString
        if let existing = sessions.object(forKey: key) { return existing }
        let session = ProjectBuildSession(root: root, target: target)
        sessions.setObject(session, forKey: key)
        return session
    }

    static func untitled(document: TeXDocument) -> ProjectBuildSession {
        ProjectBuildSession(root: nil, target: nil, untitledDocument: document)
    }

    static func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func contains(_ file: URL, in root: URL) -> Bool {
        let components = root.pathComponents
        return file.pathComponents.count > components.count && file.pathComponents.starts(with: components)
    }

    static func mainFile(in folder: URL?) -> URL? {
        guard let folder else { return nil }
        return selectedMainFile(in: folder) ?? automaticMainFile(in: folder)
    }

    static func selectedMainFile(in folder: URL) -> URL? {
        let root = normalized(folder)
        guard let saved = UserDefaults.standard.dictionary(forKey: mainKey)?[root.path] as? String else { return nil }
        return texFile(URL(fileURLWithPath: saved), in: root)
    }

    static func automaticMainFile(in folder: URL) -> URL? {
        let root = normalized(folder)
        return texFile(root.appendingPathComponent("main.tex"), in: root)
            ?? topLevelTeXFiles(in: root).first(where: declaresDocumentClass)
    }

    static func topLevelTeXFiles(in folder: URL) -> [URL] {
        let root = normalized(folder)
        let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                                 options: .skipsHiddenFiles)
        let sources = Set((files ?? []).compactMap { texFile($0, in: root) })
        return sources.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    @discardableResult
    static func setMainFile(_ file: URL?, in folder: URL) -> Bool {
        let root = normalized(folder)
        let selected = file.flatMap { texFile($0, in: root) }
        guard file == nil || selected != nil else { return false }
        var settings = UserDefaults.standard.dictionary(forKey: mainKey) ?? [:]
        settings[root.path] = selected?.path
        UserDefaults.standard.set(settings, forKey: mainKey)
        return true
    }

    private static func texFile(_ url: URL, in root: URL) -> URL? {
        guard ProjectFileKind.detect(for: url) == .latex else { return nil }
        let file = normalized(url)
        guard contains(file, in: root), ProjectFileKind.detect(for: file) == .latex,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return file
    }

    private static func declaresDocumentClass(_ file: URL) -> Bool {
        guard let input = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? input.close() }
        // The declaration normally appears at the top. Bound I/O when auto-detecting large projects.
        guard let data = try? input.read(upToCount: 64 * 1024) else { return false }
        let source = ProjectTextEncoding.decode(data)?.text ?? String(decoding: data, as: UTF8.self)
        var scanner = TeXScanner(source)
        while let command = scanner.nextCommand() {
            if command == "documentclass" { return true }
            if command == "begin" {
                scanner.skipTrivia()
                if let range = scanner.readGroup(), scanner.source.substring(with: range) == "document" { return false }
            }
        }
        return false
    }

    static func openSources(in folder: URL, editedOnly: Bool = false) -> [URL: String] {
        let root = normalized(folder)
        var sources: [URL: String] = [:]
        for case let document as TeXDocument in NSDocumentController.shared.documents {
            guard document.kind.isEditable, !editedOnly || document.isDocumentEdited,
                  let location = document.fileURL else { continue }
            let file = normalized(location)
            if contains(file, in: root) { sources[file] = document.source }
        }
        return sources
    }

    static func sourceDidChange(in document: TeXDocument?, primary: ProjectBuildSession?) {
        primary?.sourceDidChange()
        guard let url = document?.fileURL, let sessions = sessions.objectEnumerator() else { return }
        let file = normalized(url)
        for case let session as ProjectBuildSession in sessions.allObjects {
            if session !== primary, let root = session.root, contains(file, in: root) {
                session.sourceDidChange()
            }
        }
    }

    static func sourcesDidChange(in folder: URL) {
        let root = normalized(folder)
        for case let session as ProjectBuildSession in sessions.objectEnumerator()?.allObjects ?? [] {
            if session.root == root { session.sourceDidChange() }
        }
    }

    func attach(_ workspace: WorkspaceController) {
        workspaces.add(workspace)
        workspace.buildDidChange(self)
    }

    func detach(_ workspace: WorkspaceController) {
        workspaces.remove(workspace)
    }

    func keepPreview(from previous: ProjectBuildSession) {
        guard phase == .ready, let published = previous.preview else { return }
        preview = Preview(data: published.data, document: published.document, syncTeX: nil)
        log = "The source file moved. Compile again to update the preview."
        phase = .outdated
        publish()
    }

    private func sourceDidChange() {
        revision += 1
        if phase == .complete {
            phase = .outdated
            publish()
        }
        if automatic { scheduleBuild() }
    }

    func toggleAutomatic() {
        automatic.toggle()
        if let target {
            var settings = UserDefaults.standard.dictionary(forKey: Self.autoKey) ?? [:]
            settings[target.path] = automatic ? true : nil
            UserDefaults.standard.set(settings, forKey: Self.autoKey)
        }
        if automatic {
            scheduleBuild()
        } else {
            automaticTask?.cancel()
            automaticTask = nil
            compileAgain = false
        }
        publish()
    }

    private func scheduleBuild() {
        automaticTask?.cancel()
        compileAgain = false
        automaticTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled, let self else { return }
            automaticTask = nil
            if compileTask == nil { compile() }
            else { compileAgain = true }
        }
    }

    func stopCompilation() {
        guard phase == .building, let compileTask else { return }
        automaticTask?.cancel()
        automaticTask = nil
        compileAgain = false
        phase = .stopping
        log = "Stopping Tectonic…"
        compileTask.cancel()
        publish()
    }

    func compile() {
        guard compileTask == nil else { return }
        automaticTask?.cancel()
        automaticTask = nil
        compileAgain = false

        let target = target
        let root = root
        let unsavedSources = root.map { Self.openSources(in: $0, editedOnly: true) } ?? [:]
        let source = NSDocumentController.shared.documents
            .compactMap { $0 as? TeXDocument }
            .first { $0.fileURL.map(Self.normalized) == target && target != nil }?.source ?? untitledDocument?.source
        let engine = UserDefaults.standard.string(forKey: AppDelegate.enginePathKey)
            .map { URL(fileURLWithPath: $0) }
        let startRevision = revision
        phase = .building
        diagnostics = []
        artifactWarning = nil
        log = "Running Tectonic…"
        compileTask = Task { [weak self] in
            do {
                let buffer: String
                if let source {
                    buffer = source
                } else if let target {
                    buffer = try await Task.detached {
                        guard let decoded = ProjectTextEncoding.decode(try Data(contentsOf: target)) else {
                            throw CocoaError(.fileReadInapplicableStringEncoding)
                        }
                        return decoded.text
                    }.value
                } else {
                    throw CocoaError(.fileNoSuchFile)
                }
                try Task.checkCancellation()
                let result = try await TectonicCompiler.compile(source: buffer, fileURL: target, engineURL: engine,
                                                               projectRoot: root, unsavedSources: unsavedSources)
                try Task.checkCancellation()
                self?.finish(result, revision: startRevision)
            } catch {
                if Task.isCancelled || error is CancellationError { self?.finishStoppedBuild() }
                else { self?.fail(error) }
            }
        }
        publish()
    }

    private func finishStoppedBuild() {
        phase = .stopped
        log = "Compilation stopped."
        finishBuild()
    }

    private func finish(_ result: CompilationResult, revision builtRevision: Int) {
        artifactWarning = result.artifactWarning
        diagnostics = result.diagnostics
        guard let document = PDFDocument(data: result.pdfData), document.pageCount > 0 else {
            phase = .failed
            diagnostics.insert(BuildDiagnostic(severity: .error, message: "Could not open the PDF generated by Tectonic."), at: 0)
            log = "Could not open the PDF generated by Tectonic.\n\n" + result.log
            finishBuild()
            return
        }
        preview = Preview(data: result.pdfData, document: document, syncTeX: result.syncTeX)
        log = result.log.isEmpty ? "Build succeeded." : result.log
        if let warning = artifactWarning { log += "\n\n\(warning)" }
        phase = builtRevision == revision ? .complete : .outdated
        finishBuild()
    }

    private func fail(_ error: Error) {
        let tectonic = error as? TectonicError
        let detail = tectonic?.log ?? ""
        diagnostics = tectonic?.diagnostics ?? []
        if !diagnostics.contains(where: { $0.severity == .error }) {
            diagnostics.insert(BuildDiagnostic(severity: .error, message: error.localizedDescription), at: 0)
        }
        log = detail.isEmpty ? error.localizedDescription : "\(error.localizedDescription)\n\n\(detail)"
        phase = .failed
        finishBuild()
    }

    private func finishBuild() {
        compileTask = nil
        publish()
        if compileAgain && automatic { compile() }
    }

    private func publish() {
        for workspace in workspaces.allObjects { workspace.buildDidChange(self) }
    }

}
