import Foundation

final class BuildArtifactStore: @unchecked Sendable {
    struct SharedPreview: Equatable {
        let url: URL
        fileprivate let modifiedAt: Date?
        fileprivate let size: UInt64?
        fileprivate let fileNumber: UInt64?
    }

    static let shared = BuildArtifactStore()
    static let folderName = ".pagequoin-build"

    private static let markerName = ".pagequoin-owned"
    private static let marker = Data("PageQuoin Build Artifacts v1\n".utf8)
    private let files = FileManager.default
    private let lock = NSLock()

    private init() {}

    func sharedPreview(target: URL) -> SharedPreview? {
        guard let url = TectonicCompiler.siblingPDFURL(for: target),
              let attributes = try? files.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return SharedPreview(url: url, modifiedAt: attributes[.modificationDate] as? Date,
                             size: (attributes[.size] as? NSNumber)?.uint64Value,
                             fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    func existingDirectory(in root: URL) -> URL? {
        let folder = buildFolder(in: root)
        return (try? owns(folder)) == true ? folder : nil
    }

    func clear(in root: URL) throws {
        let folder = buildFolder(in: root)
        try lock.withLock {
            if try owns(folder) { try files.removeItem(at: folder) }
        }
    }

    private func buildFolder(in root: URL) -> URL {
        root.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(Self.folderName, isDirectory: true)
    }

    private func owns(_ folder: URL) throws -> Bool {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try files.attributesOfItem(atPath: folder.path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return false
        }
        let marker = folder.appendingPathComponent(Self.markerName)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let markerAttributes = try? files.attributesOfItem(atPath: marker.path),
              markerAttributes[.type] as? FileAttributeType == .typeRegular,
              (markerAttributes[.size] as? NSNumber)?.intValue == Self.marker.count,
              (try? Data(contentsOf: marker)) == Self.marker else {
            throw StorageError.unmanagedDirectory(folder)
        }
        return true
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
