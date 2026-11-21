import CryptoKit
import Foundation

struct ProjectReplacementFile: Sendable {
    struct Version: Equatable, Sendable {
        let disk: DocumentDiskVersion
        let digest: SHA256.Digest
    }

    static let fileSizeLimit = 2 * 1024 * 1024

    let url: URL
    let path: String
    let version: Version
    let sourceDigest: SHA256.Digest
    let ranges: [NSRange]

    static func read(_ url: URL, in root: URL) throws -> (Data, Version) {
        // Use the same canonical path used in the preview and reject redirected paths.
        let file = url.standardizedFileURL
        guard file.path == file.resolvingSymlinksInPath().path,
              file.pathComponents.count > root.pathComponents.count,
              file.pathComponents.starts(with: root.pathComponents),
              ProjectFileKind.detect(for: file)?.isEditable == true else { throw ReplacementError.changed }
        guard let disk = DocumentDiskVersion.read(file), disk.size <= Int64(fileSizeLimit) else {
            throw ReplacementError.changed
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: fileSizeLimit + 1) ?? Data()
        guard data.count == Int(disk.size), DocumentDiskVersion.read(file) == disk else { throw ReplacementError.changed }
        return (data, Version(disk: disk, digest: SHA256.hash(data: data)))
    }

    static func sourceDigest(_ source: String) -> SHA256.Digest {
        SHA256.hash(data: Data(source.utf8))
    }

    func validateDisk(in root: URL) throws -> Data {
        let (data, currentVersion) = try Self.read(url, in: root)
        guard version == currentVersion else { throw ReplacementError.changed }
        return data
    }

    func write(toClosedFileIn root: URL, replacement: String) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing,
                                                         error: &coordinationError) { file in
            result = Result {
                guard file.standardizedFileURL.path == url.path else { throw ReplacementError.changed }
                let data = try validateDisk(in: root)
                guard let decoded = ProjectTextEncoding.decode(data),
                      Self.sourceDigest(decoded.text) == sourceDigest else { throw ReplacementError.changed }
                let updated = NSMutableString(string: decoded.text)
                for range in ranges.reversed() { updated.replaceCharacters(in: range, with: replacement) }
                let output = try decoded.encoding.encode(updated as String)
                _ = try validateDisk(in: root)
                try output.write(to: file, options: .atomic)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ReplacementError.changed }
        try result.get()
    }
}

enum ReplacementError: LocalizedError {
    case changed
    case editorUnavailable

    var errorDescription: String? {
        switch self {
        case .changed: "The file changed since the preview. Search again to review its latest contents."
        case .editorUnavailable: "The open editor could not safely accept changes. Finish editing or saving, then search again."
        }
    }
}
