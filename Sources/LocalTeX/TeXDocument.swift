import AppKit
import ImageIO
import os

@objc(TeXDocument)
final class TeXDocument: NSDocument {
    private static let template = #"""
    \documentclass[11pt]{article}
    \usepackage{amsmath}

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
    private lazy var autosave = DocumentAutosave(document: self)
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

    override func data(ofType typeName: String) throws -> Data {
        try contents.withLock { contents in
            switch contents {
            case let .text(_, text, encoding): try encoding.encode(text)
            case let .media(_, data): data
            }
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
        autosave.willSave()
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            self?.autosave.didSave(error: error)
            completionHandler(error)
        }
    }

    override func close() {
        close(keepingProjectWindow: false)
    }

    func close(keepingProjectWindow: Bool) {
        autosave.stop()
        workspace?.closeWorkspace()
        tabs?.remove(self, keepingProjectWindow: keepingProjectWindow)
        super.close()
        workspace = nil
        tabs = nil
    }
}
