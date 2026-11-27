import CryptoKit
import Darwin
import Foundation

struct SharedProjectStore {
    struct Tab: Codable, Equatable {
        let file: String
        let cursor: Int
        let top: Int
        let left: Int
        let wrapStart: Int?
        let desktopPosition: ProjectHistory.EditorPosition?
        let desktopOnly: Bool?
    }

    struct Session: Codable, Equatable {
        var version = 1
        let root: String
        let main: String?
        let active: String?
        let tabs: [Tab]
        let pdf: String?
        let updatedAt: Int64
        let desktopWorkspace: ProjectHistory.WorkspaceState?

        enum CodingKeys: String, CodingKey {
            case version, root, main, active, tabs, pdf, updatedAt, desktopWorkspace
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(version, forKey: .version)
            try values.encode(root, forKey: .root)
            try values.encode(main, forKey: .main)
            try values.encode(active, forKey: .active)
            try values.encode(tabs, forKey: .tabs)
            try values.encode(pdf, forKey: .pdf)
            try values.encode(updatedAt, forKey: .updatedAt)
            try values.encodeIfPresent(desktopWorkspace, forKey: .desktopWorkspace)
        }
    }

    struct MainSelection: Codable {
        var version = 1
        let root: String
        let selectedMain: String?

        enum CodingKeys: String, CodingKey { case version, root, selectedMain }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(version, forKey: .version)
            try values.encode(root, forKey: .root)
            try values.encode(selectedMain, forKey: .selectedMain)
        }
    }

    private struct HistoryRemoval: Codable {
        var version = 1
        let root: String
        let removedAt: Int64
    }

    private let directory: URL
    private let legacyTerminalDirectory: URL?
    private let files = FileManager.default
    var usesDefaultDirectory: Bool { legacyTerminalDirectory != nil }

    init() {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        if let override = ProcessInfo.processInfo.environment["PAGEQUOIN_STATE_DIR"], !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
            legacyTerminalDirectory = nil
        } else {
            directory = support.appendingPathComponent("PageQuoin/sessions", isDirectory: true)
            legacyTerminalDirectory = support.appendingPathComponent("PageQuoin Terminal/sessions", isDirectory: true)
        }
    }

    static func canonicalPath(_ url: URL) -> String {
        // Foundation shortens /private/var and /private/tmp on macOS. Node's realpath keeps /private.
        url.withUnsafeFileSystemRepresentation { input in
            guard let input, let output = realpath(input, nil) else { return url.standardizedFileURL.path }
            defer { free(output) }
            return String(cString: output)
        }
    }

    static func relativePath(_ file: URL, in directory: URL) -> String? {
        let root = ProjectHistory.normalized(directory).pathComponents
        let file = ProjectHistory.normalized(file).pathComponents
        guard file.count > root.count, file.starts(with: root) else { return nil }
        return file.dropFirst(root.count).joined(separator: "/")
    }

    static func fileURL(_ relative: String, in directory: URL) -> URL? {
        guard validRelativePath(relative) else { return nil }
        return ProjectHistory.projectFile(directory.appendingPathComponent(relative), in: ProjectHistory.normalized(directory))
    }

    static func normalizedCaretOffset(_ raw: Int, in text: String) -> Int {
        guard text.contains("\r\n") else { return raw }
        var normalized = 0
        var previous: UInt16 = 0
        for unit in text.utf16.prefix(raw) {
            if unit != 10 || previous != 13 { normalized += 1 }
            previous = unit
        }
        return normalized
    }

    static func rawCaretOffset(_ normalized: Int, in text: String) -> Int {
        guard text.contains("\r\n") else { return normalized }
        var logical = 0
        var raw = 0
        var previous: UInt16 = 0
        for unit in text.utf16 {
            if !(unit == 10 && previous == 13) {
                if logical == normalized { return raw }
                logical += 1
            }
            previous = unit
            raw += 1
        }
        return raw
    }

    func sessions() -> [Session] {
        let shared = readSessions(in: directory)
        var seen = Set(shared.map(\.root))
        let legacy = legacyTerminalDirectory.map(readSessions(in:)) ?? []
        return (shared + legacy.filter { seen.insert($0.root).inserted }).filter {
            $0.updatedAt > (removedAt(forPath: $0.root) ?? -1)
        }
    }

    func session(for root: URL) -> Session? {
        let path = Self.canonicalPath(root)
        guard let session = storedSession(forPath: path), session.updatedAt > (removedAt(forPath: path) ?? -1)
        else { return nil }
        return session
    }

    func save(_ session: Session, ifMissing: Bool = false) throws {
        try write(session, to: Self.recordName(session.root) + ".json", ifMissing: ifMissing)
    }

    func removedAt(for root: URL) -> Int64? {
        removedAt(forPath: Self.canonicalPath(root))
    }

    func removeFromHistory(_ root: URL) throws {
        let path = Self.canonicalPath(root)
        let previous = removedAt(forPath: path)
        let timestamp = max(Int64(Date().timeIntervalSince1970 * 1000),
                            previous.map { $0 + 1 } ?? 0, storedSession(forPath: path)?.updatedAt ?? 0)
        try write(HistoryRemoval(root: path, removedAt: timestamp),
                  to: Self.recordName(path) + ".removed.json", ifMissing: false)
    }

    private func removedAt(forPath path: String) -> Int64? {
        let url = directory.appendingPathComponent(Self.recordName(path) + ".removed.json")
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let data = try? Data(contentsOf: url),
              let removal = try? JSONDecoder().decode(HistoryRemoval.self, from: data),
              removal.version == 1, removal.root == path,
              (0..<Int64.max).contains(removal.removedAt) else { return nil }
        return removal.removedAt
    }

    private func storedSession(forPath path: String) -> Session? {
        let name = Self.recordName(path) + ".json"
        return readSession(at: directory.appendingPathComponent(name))
            ?? legacyTerminalDirectory.flatMap { readSession(at: $0.appendingPathComponent(name)) }
    }

    func mainSelection(for root: URL) -> MainSelection? {
        let canonical = Self.canonicalPath(root)
        let url = directory.appendingPathComponent(Self.recordName(canonical) + ".main.json")
        guard let data = try? Data(contentsOf: url),
              let selection = try? JSONDecoder().decode(MainSelection.self, from: data),
              selection.version == 1, selection.root == canonical,
              selection.selectedMain.map(Self.validRelativePath) != false else { return nil }
        return selection
    }

    func saveMain(_ file: URL?, in root: URL, ifMissing: Bool = false) throws {
        let canonical = Self.canonicalPath(root)
        let relative = file.flatMap { Self.relativePath($0, in: root) }
        guard file == nil || relative != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        try write(MainSelection(root: canonical, selectedMain: relative),
                  to: Self.recordName(canonical) + ".main.json", ifMissing: ifMissing)
    }

    private static func recordName(_ root: String) -> String {
        SHA256.hash(data: Data(root.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func validRelativePath(_ value: String) -> Bool {
        !value.contains("\0") && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private func readSessions(in directory: URL) -> [Session] {
        let entries = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles])
        return (entries ?? []).compactMap(readSession(at:))
    }

    private func readSession(at url: URL) -> Session? {
        let name = url.lastPathComponent
        guard name.utf8.count == 69, name.hasSuffix(".json"),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder().decode(Session.self, from: data),
              session.version == 1, session.root.hasPrefix("/"), !session.root.contains("\0"),
              session.updatedAt >= 0, name == Self.recordName(session.root) + ".json",
              [session.main, session.active, session.pdf].compactMap({ $0 }).allSatisfy(Self.validRelativePath),
              session.tabs.allSatisfy({ Self.validRelativePath($0.file) && $0.cursor >= 0 && $0.top >= 0
                  && $0.left >= 0 && ($0.wrapStart ?? 0) >= 0 }) else { return nil }
        return session
    }

    private func write<T: Encodable>(_ value: T, to name: String, ifMissing: Bool) throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(name)
        let data = try JSONEncoder().encode(value)
        if !ifMissing {
            try data.write(to: destination, options: .atomic)
        } else if !files.fileExists(atPath: destination.path) {
            let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            defer { try? files.removeItem(at: temporary) }
            try data.write(to: temporary, options: .withoutOverwriting)
            // Publish a migration only if a newer publisher has not created the destination meanwhile.
            do { try files.linkItem(at: temporary, to: destination) }
            catch where files.fileExists(atPath: destination.path) { return }
        }
    }
}
