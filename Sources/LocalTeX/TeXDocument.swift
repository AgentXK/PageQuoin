import AppKit
import CryptoKit
import ImageIO
import os

@objc(TeXDocument)
final class TeXDocument: NSDocument {
    private static let template = #"""
    \documentclass[11pt]{article}
    \usepackage{amsmath}
    \usepackage{graphicx}

    \begin{document}

    \section{Hello, LaTeX!}
    Edit the source, then compile to preview your PDF.

    \[
      \int_0^1 x^2\,\mathrm{d}x = \frac{1}{3}
    \]

    \end{document}
    """# + "\n"

    private enum Contents {
        case text(ProjectFileKind, String, ProjectTextEncoding)
        case media(ProjectFileKind, Data)

        var kind: ProjectFileKind {
            switch self {
            case let .text(kind, _, _), let .media(kind, _): kind
            }
        }
    }

    private let contents = OSAllocatedUnfairLock(initialState: Contents.text(.latex, template, .utf8))
    private let lastDiskBaseline = OSAllocatedUnfairLock(initialState: DocumentDiskBaseline?.none)
    private let approvedDiskBaseline = OSAllocatedUnfairLock(initialState: DocumentDiskBaseline?.none)
    private lazy var autosave = DocumentAutosave(document: self)
    private lazy var externalChanges = DocumentExternalChanges(document: self)
    private(set) var workspace: WorkspaceController?
    private(set) var tabs: DocumentTabGroup?

    override class var autosavesInPlace: Bool { false }

    var kind: ProjectFileKind { contents.withLock { $0.kind } }

    var mediaData: Data? {
        contents.withLock { contents in
            if case let .media(_, data) = contents { return data }
            return nil
        }
    }

    var source: String {
        get {
            contents.withLock { contents in
                if case let .text(_, text, _) = contents { return text }
                return ""
            }
        }
        set {
            let changed = contents.withLock { contents in
                guard case let .text(kind, current, encoding) = contents,
                      !current.utf8.elementsEqual(newValue.utf8) else { return false }
                contents = .text(kind, newValue, encoding)
                return true
            }
            if changed { autosave.sourceDidChange() }
        }
    }

    nonisolated override func read(from data: Data, ofType typeName: String) throws {
        let kind = ProjectFileKind(rawValue: typeName) ?? .text
        switch kind {
        case .latex, .text:
            guard let decoded = ProjectTextEncoding.decode(data) else {
                throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [
                    NSLocalizedDescriptionKey: "The file could not be read as UTF-8 or as UTF-16 or UTF-32 with a byte order mark."
                ])
            }
            contents.withLock { $0 = .text(kind, decoded.text, decoded.encoding) }
        case .image:
            let imageSource = CGImageSourceCreateWithData(data as CFData, nil)
            guard imageSource.map(CGImageSourceGetCount) ?? 0 > 0 || NSImage(data: data) != nil else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSLocalizedDescriptionKey: "This image could not be opened."
                ])
            }
            contents.withLock { $0 = .media(kind, data) }
        case .pdf:
            guard let provider = CGDataProvider(data: data as CFData), CGPDFDocument(provider) != nil else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSLocalizedDescriptionKey: "This PDF could not be opened."
                ])
            }
            contents.withLock { $0 = .media(kind, data) }
        }
    }

    nonisolated override func read(from url: URL, ofType typeName: String) throws {
        let snapshot = try DocumentDiskSnapshot.read(url)
        try read(from: snapshot.data, ofType: typeName)
        acceptExternalBaseline(snapshot.baseline)
    }

    override func data(ofType typeName: String) throws -> Data {
        try serializedContents()
    }

    private nonisolated func serializedContents() throws -> Data {
        try contents.withLock { contents in
            switch contents {
            case let .text(_, text, encoding): try encoding.encode(text)
            case let .media(_, data): data
            }
        }
    }

    nonisolated override func writeSafely(to url: URL, ofType typeName: String,
                                          for saveOperation: SaveOperationType) throws {
        guard saveOperation == .saveOperation || saveOperation == .saveAsOperation else {
            try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
            return
        }
        // Recheck inside AppKit's coordinated write, after any time spent in a save dialog.
        guard canWriteDocument(at: url) else { throw CocoaError(.userCancelled) }
        let expectedDigest = SHA256.hash(data: try serializedContents())
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
        if let snapshot = try? DocumentDiskSnapshot.read(url), snapshot.baseline.digest == expectedDigest {
            acceptExternalBaseline(snapshot.baseline)
        }
    }

    override func writableTypes(for saveOperation: SaveOperationType) -> [String] {
        kind.isEditable ? [kind.rawValue] : []
    }

    override func fileNameExtension(forType typeName: String, saveOperation: SaveOperationType) -> String? {
        fileURL?.pathExtension ?? (kind == .latex ? "tex" : "txt")
    }

    override func makeWindowControllers() {
        prepareWorkspace(in: DocumentTabGroup())
    }

    func prepareWorkspace(in tabs: DocumentTabGroup) {
        guard workspace == nil else { return }
        workspace = WorkspaceController(document: self)
        self.tabs = tabs
        addWindowController(NSWindowController(window: nil))
        tabs.add(self)
        checkForExternalFileChanges()
    }

    override func showWindows() {
        if tabs == nil { makeWindowControllers() }
        tabs?.show(self)
    }

    override func updateChangeCount(_ change: ChangeType) {
        super.updateChangeCount(change)
        tabs?.refresh()
    }

    override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: SaveOperationType) {
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        tabs?.refresh()
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        workspace?.endTypingGroup()
        guard saveOperation == .saveOperation || saveOperation == .saveAsOperation else {
            super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
            return
        }
        guard canWriteDocument(at: url) else {
            externalChanges.checkSoon(compareAgain: true)
            completionHandler(CocoaError(.userCancelled))
            return
        }
        autosave.willSave()
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            self?.autosave.didSave(error: error)
            self?.checkForExternalFileChanges()
            completionHandler(error)
        }
    }

    nonisolated override func presentedItemDidChange() {
        Task { @MainActor [weak self] in self?.checkForExternalFileChanges() }
    }

    var isSavingDocument: Bool { autosave.isSaving }

    func checkForExternalFileChanges() { externalChanges.checkSoon() }

    nonisolated func diskBaseline(at url: URL) -> DocumentDiskBaseline? {
        let file = url.standardizedFileURL
        return lastDiskBaseline.withLock { $0?.url == file ? $0 : nil }
    }

    nonisolated func acceptExternalBaseline(_ baseline: DocumentDiskBaseline) {
        lastDiskBaseline.withLock { $0 = baseline }
    }

    nonisolated func canWriteDocument(at url: URL) -> Bool {
        guard let baseline = diskBaseline(at: url) else { return true }
        let approved = approvedDiskBaseline.withLock { $0?.url == baseline.url ? $0 : nil }
        let expected = approved ?? baseline
        guard let version = DocumentDiskVersion.read(url) else { return false }
        if version == expected.version { return true }
        // AppKit can restore file attributes after saving. Verify the bytes before accepting a ctime-only change.
        guard version.matchesFileMetadata(of: expected.version), let snapshot = try? DocumentDiskSnapshot.read(url),
              version == snapshot.baseline.version, snapshot.baseline.digest == expected.digest else { return false }
        if approved == nil { acceptExternalBaseline(snapshot.baseline) }
        else { approvedDiskBaseline.withLock { $0 = snapshot.baseline } }
        return true
    }

    func hasLocalEdits(comparedWith baseline: DocumentDiskBaseline) -> Bool {
        guard kind.isEditable else { return false }
        if isDocumentEdited || workspace?.hasMarkedText == true { return true }
        guard let bytes = try? serializedContents() else { return true }
        return SHA256.hash(data: bytes) != baseline.digest
    }

    @discardableResult
    func reloadExternalSnapshot(_ snapshot: DocumentDiskSnapshot) -> Bool {
        guard let type = fileType else { return false }
        do { try read(from: snapshot.data, ofType: type) }
        catch { return false }
        acceptExternalBaseline(snapshot.baseline)
        fileModificationDate = snapshot.baseline.version.modificationDate
        undoManager?.removeAllActions()
        updateChangeCount(.changeCleared)
        workspace?.reloadExternalSource()
        return true
    }

    func saveVersionComparedWith(_ baseline: DocumentDiskBaseline) {
        guard let type = fileType else { return }
        let previousDate = fileModificationDate
        approvedDiskBaseline.withLock { $0 = baseline }
        fileModificationDate = baseline.version.modificationDate
        save(to: baseline.url, ofType: type, for: .saveOperation) { [weak self] error in
            guard let self else { return }
            approvedDiskBaseline.withLock { $0 = nil }
            if let error {
                fileModificationDate = previousDate
                if (error as? CocoaError)?.code != .userCancelled { presentError(error) }
            }
            checkForExternalFileChanges()
        }
    }

    override func close() {
        close(keepingProjectWindow: false)
    }

    func close(keepingProjectWindow: Bool) {
        autosave.stop()
        externalChanges.stop()
        tabs?.remove(self, keepingProjectWindow: keepingProjectWindow)
        workspace?.closeWorkspace()
        super.close()
        workspace = nil
        tabs = nil
    }
}
