import AppKit
import CryptoKit
import Darwin

struct DocumentDiskVersion: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    var modificationDate: Date {
        Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000)
    }

    func matchesFileMetadata(of other: Self) -> Bool {
        device == other.device && inode == other.inode && size == other.size
            && modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
    }

    static func read(_ url: URL) -> Self? {
        var info = stat()
        let status: Int32 = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.fstatat(AT_FDCWD, $0, &info, 0) } ?? -1
        }
        guard status == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Self(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                    modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                    changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
    }
}

struct DocumentDiskBaseline: Sendable {
    let url: URL
    let version: DocumentDiskVersion
    let digest: SHA256Digest
}

struct DocumentDiskSnapshot: Sendable {
    let data: Data
    let baseline: DocumentDiskBaseline

    static func read(_ url: URL) throws -> Self {
        let url = url.standardizedFileURL
        guard let version = DocumentDiskVersion.read(url) else { throw CocoaError(.fileReadNoSuchFile) }
        let data = try Data(contentsOf: url)
        guard version == DocumentDiskVersion.read(url) else { throw CocoaError(.fileReadUnknown) }
        return Self(data: data, baseline: DocumentDiskBaseline(url: url, version: version, digest: SHA256.hash(data: data)))
    }
}

@MainActor
final class DocumentExternalChanges: NSObject {
    private weak var document: TeXDocument?
    private var watchedURL: URL?
    private var watchedVersion: DocumentDiskVersion?
    private var fileWatch: DispatchSourceFileSystemObject?
    private var directoryWatch: DispatchSourceFileSystemObject?
    private var checkTask: Task<Void, Never>?
    private var comparedVersion: DocumentDiskVersion?
    private var comparisonOpen = false
    private var stopped = false

    init(document: TeXDocument) {
        self.document = document
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationActivated(_:)),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameAvailable(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameAvailable(_:)),
                                               name: NSWindow.didEndSheetNotification, object: nil)
    }

    deinit {
        checkTask?.cancel()
        fileWatch?.cancel()
        directoryWatch?.cancel()
    }

    func checkSoon(compareAgain: Bool = false) {
        guard !stopped else { return }
        if compareAgain { comparedVersion = nil }
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            await checkDisk()
        }
    }

    func stop() {
        stopped = true
        checkTask?.cancel()
        fileWatch?.cancel()
        directoryWatch?.cancel()
        fileWatch = nil
        directoryWatch = nil
    }

    @objc private func applicationActivated(_ notification: Notification) { checkSoon() }

    @objc private func windowBecameAvailable(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window.contentViewController === document?.workspace {
            checkSoon()
        }
    }

    private func checkDisk() async {
        guard let document, let file = document.fileURL?.standardizedFileURL,
              let baseline = document.diskBaseline(at: file), !document.isSavingDocument else { return }
        let version = DocumentDiskVersion.read(file)
        updateWatches(file: file, version: version)
        guard let version else {
            document.workspace?.setExternalFileNotice("File unavailable on disk. Save As can preserve your edits.")
            return
        }
        guard version != baseline.version else {
            document.workspace?.setExternalFileNotice(nil)
            return
        }
        if document.workspace?.hasMarkedText == true {
            checkSoon()
            return
        }

        let snapshot = await Task.detached { try? DocumentDiskSnapshot.read(file) }.value
        guard !stopped, !Task.isCancelled, document.fileURL?.standardizedFileURL == file,
              document.diskBaseline(at: file)?.version == baseline.version,
              !document.isSavingDocument else { return }
        guard DocumentDiskVersion.read(file) == version else {
            checkSoon()
            return
        }
        guard let snapshot, snapshot.baseline.version == version else {
            document.workspace?.setExternalFileNotice("File changed on disk and could not be read.")
            return
        }
        if snapshot.baseline.digest == baseline.digest {
            document.acceptExternalBaseline(snapshot.baseline)
            document.fileModificationDate = snapshot.baseline.version.modificationDate
        } else if document.hasLocalEdits(comparedWith: baseline) {
            guard let diskSource = ProjectTextEncoding.decode(snapshot.data)?.text else {
                document.workspace?.setExternalFileNotice("File changed on disk and uses an unsupported text encoding. Save As can preserve your edits.")
                return
            }
            document.workspace?.setExternalFileNotice("File changed on disk. Save to review both versions.")
            presentComparison(snapshot, source: diskSource, for: document)
            return
        } else if !document.reloadExternalSnapshot(snapshot) {
            document.workspace?.setExternalFileNotice("File changed on disk and could not be opened.")
            return
        }
        document.workspace?.setExternalFileNotice(nil)
    }

    private func updateWatches(file: URL, version: DocumentDiskVersion?) {
        if watchedURL != file || directoryWatch == nil {
            watchedURL = file
            watchedVersion = nil
            fileWatch?.cancel()
            fileWatch = nil
            directoryWatch?.cancel()
            directoryWatch = watch(file.deletingLastPathComponent()) { [weak self] event in
                guard let self else { return }
                if !event.intersection([.rename, .delete, .revoke]).isEmpty {
                    directoryWatch?.cancel()
                    directoryWatch = nil
                }
                checkSoon()
            }
        }
        guard watchedVersion?.device != version?.device || watchedVersion?.inode != version?.inode
                || fileWatch == nil else { return }
        watchedVersion = version
        fileWatch?.cancel()
        fileWatch = version == nil ? nil : watch(file) { [weak self] _ in self?.checkSoon() }
    }

    private func watch(_ url: URL, handler: @escaping (DispatchSource.FileSystemEvent) -> Void) -> DispatchSourceFileSystemObject? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in path.map { open($0, O_EVTONLY | O_CLOEXEC) } ?? -1 }
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
                                                               queue: .main)
        source.setCancelHandler { Darwin.close(descriptor) }
        source.setEventHandler { [weak self] in
            guard self != nil else { return }
            handler(source.data)
        }
        source.activate()
        return source
    }

    private func presentComparison(_ snapshot: DocumentDiskSnapshot, source diskSource: String, for document: TeXDocument) {
        let version = snapshot.baseline.version
        guard !comparisonOpen, comparedVersion != version,
              let workspace = document.workspace, workspace.isViewLoaded, let window = workspace.view.window,
              window.contentViewController === workspace, window.isKeyWindow, window.attachedSheet == nil,
              document.tabs?.isReviewingClose(of: document) != true, NSApp.modalWindow == nil,
              workspace.hasMarkedText == false else { return }

        comparisonOpen = true
        comparedVersion = version
        let localSource = document.source
        let alert = NSAlert()
        alert.messageText = "\(snapshot.baseline.url.lastPathComponent) Changed on Disk"
        alert.informativeText = "Compare your edits with the version on disk, then choose which version to use."
        alert.accessoryView = ExternalSourceComparison(local: localSource, disk: diskSource)
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Reload from Disk")
        alert.addButton(withTitle: "Save My Version")
        alert.buttons[0].keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self, weak document] response in
            guard let self, !stopped, let document else { return }
            comparisonOpen = false
            guard document.fileURL?.standardizedFileURL == snapshot.baseline.url,
                  DocumentDiskVersion.read(snapshot.baseline.url) == snapshot.baseline.version else {
                checkSoon()
                return
            }
            guard response == .alertSecondButtonReturn || response == .alertThirdButtonReturn else { return }
            guard document.source.utf8.elementsEqual(localSource.utf8) else {
                checkSoon(compareAgain: true)
                return
            }
            if response == .alertSecondButtonReturn {
                if document.reloadExternalSnapshot(snapshot) { document.workspace?.setExternalFileNotice(nil) }
            } else {
                document.saveVersionComparedWith(snapshot.baseline)
            }
        }
    }
}

@MainActor
private final class ExternalSourceComparison: NSView {
    init(local: String, disk: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 620, height: 206))
        let left = local as NSString
        let right = disk as NSString
        var difference = 0
        while difference < min(left.length, right.length), left.character(at: difference) == right.character(at: difference) {
            difference += 1
        }
        let columns = NSStackView(views: [column("Your Unsaved Edits", text: left, difference: difference),
                                          column("On Disk", text: right, difference: difference)])
        columns.distribution = .fillEqually
        columns.alignment = .top
        columns.spacing = 10
        columns.translatesAutoresizingMaskIntoConstraints = false
        addSubview(columns)
        NSLayoutConstraint.activate([
            columns.leadingAnchor.constraint(equalTo: leadingAnchor), columns.trailingAnchor.constraint(equalTo: trailingAnchor),
            columns.topAnchor.constraint(equalTo: topAnchor), columns.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    private func column(_ title: String, text: NSString, difference: Int) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        let editor = NSTextView(frame: scroll.bounds)
        editor.isEditable = false
        editor.isRichText = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = .width
        editor.textContainer?.widthTracksTextView = true
        editor.layoutManager?.allowsNonContiguousLayout = true
        editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        editor.string = text as String
        editor.setAccessibilityLabel(title)
        scroll.documentView = editor
        if difference < text.length {
            let range = text.lineRange(for: NSRange(location: difference, length: 1))
            editor.textStorage?.addAttribute(.backgroundColor, value: AppPalette.selection, range: range)
            Task { [weak editor] in editor?.scrollRangeToVisible(range) }
        }
        let column = NSStackView(views: [label, scroll])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        scroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 182).isActive = true
        return column
    }
}
