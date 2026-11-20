import CryptoKit
import Darwin
import Foundation

final class BuildArtifactStore: @unchecked Sendable {
    struct Ticket {
        fileprivate let folder: URL
        fileprivate let targetName: String
        fileprivate let id: UUID
    }

    static let shared = BuildArtifactStore()
    static let folderName = ".pagequoin-build"

    private static let markerName = ".pagequoin-owned"
    private static let marker = Data("PageQuoin Build Artifacts v1\n".utf8)
    private let files = FileManager.default
    private let lock = NSLock()
    private var active: [URL: [String: UUID]] = [:]

    private init() {}

    func begin(projectRoot: URL?, target: URL?) -> Ticket? {
        guard let target else { return nil }
        let root = projectRoot ?? target.deletingLastPathComponent()
        let folder = buildFolder(in: root)
        let source = target.resolvingSymlinksInPath().standardizedFileURL
        let prefix = folder.deletingLastPathComponent().pathComponents
        let path = source.pathComponents.starts(with: prefix)
            ? source.pathComponents.dropFirst(prefix.count).joined(separator: "/")
            : source.path
        let hash = SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let title = source.deletingPathExtension().lastPathComponent.prefix(40)
            .map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        let targetName = String(title) + "-" + hash
        let ticket = Ticket(folder: folder, targetName: targetName, id: UUID())
        lock.withLock { active[folder, default: [:]][targetName] = ticket.id }
        return ticket
    }

    func finish(_ ticket: Ticket) {
        lock.withLock {
            guard active[ticket.folder]?[ticket.targetName] == ticket.id else { return }
            active[ticket.folder]?.removeValue(forKey: ticket.targetName)
            if active[ticket.folder]?.isEmpty == true { active.removeValue(forKey: ticket.folder) }
        }
    }

    func publish(_ output: URL, for ticket: Ticket,
                 commit: (() throws -> Void) throws -> Void) throws -> URL? {
        try lock.withLock {
            guard active[ticket.folder]?[ticket.targetName] == ticket.id else { return nil }
            try prepare(ticket.folder)
            let staged = ticket.folder.appendingPathComponent(".incoming-\(ticket.id)", isDirectory: true)
            defer { try? files.removeItem(at: staged) }
            try files.copyItem(at: output, to: staged)
            let destination = ticket.folder.appendingPathComponent(ticket.targetName, isDirectory: true)
            try commit {
                if let type = try itemType(at: destination) {
                    guard type == .typeDirectory else { throw StorageError.unmanagedDirectory(destination) }
                    let result = staged.path.withCString { from in
                        destination.path.withCString { to in
                            renamex_np(from, to, UInt32(RENAME_SWAP))
                        }
                    }
                    if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                } else {
                    try files.moveItem(at: staged, to: destination)
                }
            }
            return destination
        }
    }

    func existingDirectory(in root: URL) -> URL? {
        let folder = buildFolder(in: root)
        return (try? owns(folder)) == true ? folder : nil
    }

    func clear(in root: URL) throws {
        let folder = buildFolder(in: root)
        try lock.withLock {
            if try owns(folder) { try files.removeItem(at: folder) }
            // Builds that are still running may update the preview, but cannot republish these files.
            active.removeValue(forKey: folder)
        }
    }

    private func buildFolder(in root: URL) -> URL {
        root.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(Self.folderName, isDirectory: true)
    }

    private func prepare(_ folder: URL) throws {
        if try owns(folder) { return }
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            if try owns(folder) { return }
            throw error
        }
        do {
            try Self.marker.write(to: folder.appendingPathComponent(Self.markerName), options: .withoutOverwriting)
        } catch {
            // Remove only an empty directory if ownership could not be recorded.
            _ = folder.path.withCString { rmdir($0) }
            throw error
        }
    }

    private func owns(_ folder: URL) throws -> Bool {
        guard let folderType = try itemType(at: folder) else { return false }
        guard folderType == .typeDirectory else { throw StorageError.unmanagedDirectory(folder) }
        let marker = folder.appendingPathComponent(Self.markerName)
        guard let attributes = try? files.attributesOfItem(atPath: marker.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue == Self.marker.count,
              (try? Data(contentsOf: marker)) == Self.marker else {
            throw StorageError.unmanagedDirectory(folder)
        }
        return true
    }

    private func itemType(at url: URL) throws -> FileAttributeType? {
        do {
            return try files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private enum StorageError: LocalizedError {
        case unmanagedDirectory(URL)

        var errorDescription: String? {
            switch self {
            case let .unmanagedDirectory(url):
                "PageQuoin does not own the folder “\(url.path)”."
            }
        }
    }
}
