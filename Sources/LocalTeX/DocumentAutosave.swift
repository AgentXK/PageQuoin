import AppKit

@MainActor
final class DocumentAutosave: NSObject {
    private weak var document: TeXDocument?
    private var timer: Task<Void, Never>?
    private var savesInProgress = 0
    private var changedDuringSave = false
    private var stopped = false
    var isSaving: Bool { savesInProgress > 0 }

    init(document: TeXDocument) {
        self.document = document
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged(_:)),
                                               name: EditorAutosaveSettings.didChange, object: nil)
    }

    deinit { timer?.cancel() }

    func sourceDidChange() {
        if savesInProgress > 0 { changedDuringSave = true }
        schedule()
    }

    func willSave() {
        cancelTimer()
        savesInProgress += 1
        changedDuringSave = false
    }

    func didSave(error: Error?) {
        savesInProgress -= 1
        if error == nil { document?.workspace?.setAutosaveWarning(nil) }
        if changedDuringSave && savesInProgress == 0 { schedule() }
    }

    func stop() {
        stopped = true
        cancelTimer()
    }

    @objc private func settingsChanged(_ notification: Notification) {
        if !EditorAutosaveSettings.current.enabled {
            document?.workspace?.setAutosaveWarning(nil)
        }
        if document?.isDocumentEdited == true { schedule() }
    }

    private func schedule() {
        cancelTimer()
        let settings = EditorAutosaveSettings.current
        guard !stopped, settings.enabled, savesInProgress == 0, document?.fileURL != nil else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(settings.delayMilliseconds))
            guard !Task.isCancelled, let self else { return }
            timer = nil
            saveIfReady()
        }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    private func saveIfReady() {
        guard !stopped, EditorAutosaveSettings.current.enabled, savesInProgress == 0,
              let document, document.isDocumentEdited, let url = document.fileURL,
              let type = document.fileType else { return }
        if document.tabs?.isReviewingClose(of: document) == true || document.workspace?.hasMarkedText == true
            || document.windowForSheet?.attachedSheet != nil
            || NSApp.modalWindow != nil {
            schedule()
            return
        }

        guard document.canWriteDocument(at: url) else {
            document.checkForExternalFileChanges()
            return
        }

        document.save(to: url, ofType: type, for: .saveOperation) { [weak document] error in
            if let error, (error as? CocoaError)?.code != .userCancelled {
                document?.workspace?.setAutosaveWarning(error.localizedDescription)
            }
        }
    }
}
