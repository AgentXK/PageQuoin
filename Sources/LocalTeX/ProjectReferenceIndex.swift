import Foundation

enum ProjectReferenceKind: Sendable {
    case citation, label
}

actor ProjectReferenceIndex {
    struct Input: Sendable {
        let root: URL?
        let openSources: [URL: String]
        let untitledSource: String?
        let currentFile: URL?
    }

    struct Definition: Sendable {
        let file: URL?
        let range: NSRange
    }

    private struct Entry: Sendable {
        let kind: ProjectReferenceKind
        let key: String
        let detail: String
        let definition: Definition
        let foldedKey: String
        let searchableText: String

        init(kind: ProjectReferenceKind, key: String, detail: String, file: URL?, range: NSRange) {
            self.kind = kind
            self.key = key
            self.detail = detail
            definition = Definition(file: file, range: range)
            foldedKey = ProjectReferenceIndex.fold(key)
            searchableText = ProjectReferenceIndex.fold(key + " " + detail)
        }
    }

    private struct DiskFile {
        let modificationDate: Date?
        let size: Int
        let entries: [Entry]
    }

    private struct OpenFile {
        let source: String
        let entries: [Entry]
    }

    static let shared = ProjectReferenceIndex()
    private static let fileByteLimit = 2 * 1024 * 1024
    private static let projectByteLimit = 24 * 1024 * 1024
    private static let fileEntryLimit = 4_000
    private static let projectEntryLimit = 20_000
    private static let fileLimit = 1_024
    private static let scanInterval: Duration = .seconds(2)

    private var root: URL?
    private var diskFiles: [URL: DiskFile] = [:]
    private var openFiles: [URL: OpenFile] = [:]
    private var refreshTime: ContinuousClock.Instant?

    func candidates(for kind: ProjectReferenceKind, matching query: String, in input: Input) -> [LaTeXCompletion.Candidate] {
        let query = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let words = query.split(whereSeparator: \.isWhitespace)
        let entries = entries(in: input).filter { $0.kind == kind }
        guard !Task.isCancelled else { return [] }
        var matches = Array(repeating: [Entry](), count: 3)
        var keys = Set<String>()
        for entry in entries where keys.insert(entry.key).inserted {
            if entry.foldedKey == query {
                matches[0].append(entry)
            } else if entry.foldedKey.hasPrefix(query) {
                matches[1].append(entry)
            } else if words.allSatisfy({ entry.searchableText.contains($0) }) {
                matches[2].append(entry)
            }
        }
        return matches.flatMap { group in
            group.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.prefix(60)
        }.prefix(60).map {
            LaTeXCompletion.Candidate(insertion: $0.key, label: $0.key, detail: $0.detail)
        }
    }

    func definition(of label: String, in input: Input) -> Definition? {
        entries(in: input, refresh: true).first { $0.kind == .label && $0.key == label }?.definition
    }

    private func entries(in input: Input, refresh: Bool = false) -> [Entry] {
        if root != input.root {
            root = input.root
            diskFiles.removeAll()
            openFiles.removeAll()
            refreshTime = nil
        }
        if let root, refresh || (refreshTime.map { $0.duration(to: .now) >= Self.scanInterval } ?? true) {
            refreshDisk(in: root)
        }
        guard !Task.isCancelled else { return [] }

        var snapshots: [URL: OpenFile] = [:]
        var remainingBytes = Self.projectByteLimit
        let openPaths = input.openSources.keys.sorted { pathOrder($0, $1, preferred: input.currentFile) }
        for file in openPaths.prefix(Self.fileLimit) {
            guard let kind = Self.kind(for: file), let source = input.openSources[file],
                  source.utf8.count <= min(Self.fileByteLimit, remainingBytes) else { continue }
            remainingBytes -= source.utf8.count
            if let cached = openFiles[file], cached.source == source {
                snapshots[file] = cached
            } else {
                snapshots[file] = OpenFile(source: source, entries: Self.parse(source, kind: kind, file: file))
            }
        }
        openFiles = snapshots

        var entries: [Entry] = []
        if let source = input.untitledSource, source.utf8.count <= Self.fileByteLimit {
            entries = Self.parse(source, kind: .label, file: nil)
        }
        let files = Set(diskFiles.keys).union(openFiles.keys).sorted { pathOrder($0, $1, preferred: input.currentFile) }
        for file in files where entries.count < Self.projectEntryLimit {
            // An editor buffer replaces its disk snapshot, including labels the user removed.
            if let live = openFiles[file] {
                entries.append(contentsOf: live.entries.prefix(Self.projectEntryLimit - entries.count))
            } else if input.openSources[file] == nil, let disk = diskFiles[file] {
                entries.append(contentsOf: disk.entries.prefix(Self.projectEntryLimit - entries.count))
            }
        }
        return entries
    }

    private func refreshDisk(in root: URL) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let listing = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            diskFiles.removeAll()
            refreshTime = .now
            return
        }
        var files: [URL: DiskFile] = [:]
        var remainingBytes = Self.projectByteLimit
        var visited = 0
        var entryCount = 0
        for case let file as URL in listing {
            visited += 1
            guard visited <= 12_000, files.count < Self.fileLimit, entryCount < Self.projectEntryLimit else { break }
            guard let kind = Self.kind(for: file), let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= min(Self.fileByteLimit, remainingBytes) else { continue }
            let file = file.standardizedFileURL
            remainingBytes -= size
            let date = values.contentModificationDate
            if let cached = diskFiles[file], cached.modificationDate == date, cached.size == size, date != nil {
                files[file] = cached
            } else if let data = try? Data(contentsOf: file), data.count <= Self.fileByteLimit,
                      let decoded = ProjectTextEncoding.decode(data) {
                files[file] = DiskFile(modificationDate: date, size: size, entries: Self.parse(decoded.text, kind: kind, file: file))
            }
            entryCount += files[file]?.entries.count ?? 0
        }
        diskFiles = files
        refreshTime = .now
    }

    private func pathOrder(_ lhs: URL, _ rhs: URL, preferred: URL?) -> Bool {
        if lhs == preferred { return rhs != preferred }
        if rhs == preferred { return false }
        return lhs.path < rhs.path
    }

    private static func kind(for file: URL) -> ProjectReferenceKind? {
        switch file.pathExtension.lowercased() {
        case "bib": .citation
        case "tex", "ltx": .label
        default: nil
        }
    }

    private static func parse(_ source: String, kind: ProjectReferenceKind, file: URL?) -> [Entry] {
        if kind == .citation {
            var reader = BibTeXReader(source)
            var entries: [Entry] = []
            while entries.count < fileEntryLimit, let record = reader.next() {
                let detail = record.fields.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                entries.append(Entry(kind: .citation, key: record.key, detail: detail, file: file, range: record.range))
            }
            return entries
        }

        var scanner = TeXScanner(source)
        var entries: [Entry] = []
        while entries.count < fileEntryLimit, let command = scanner.nextCommand() {
            if command == "verb" || command == "lstinline" {
                scanner.skipInlineVerbatim(allowsOptions: command == "lstinline")
                continue
            }
            if command == "begin" {
                scanner.skipTrivia()
                if let range = scanner.readGroup() {
                    let environment = scanner.source.substring(with: range)
                    if verbatimEnvironments.contains(environment) { scanner.skipVerbatimEnvironment(environment) }
                }
                continue
            }
            guard command == "label" else { continue }
            scanner.skipTrivia()
            guard let group = scanner.readGroup() else { continue }
            let raw = scanner.source.substring(with: group)
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, key.utf16.count <= 300,
                  key.rangeOfCharacter(from: invalidLabelCharacters) == nil else { continue }
            let relativeRange = (raw as NSString).range(of: key)
            let position = NSRange(location: group.location + relativeRange.location, length: relativeRange.length)
            entries.append(Entry(kind: .label, key: key, detail: file?.lastPathComponent ?? "Current file",
                                 file: file, range: position))
        }
        return entries
    }

    private static let invalidLabelCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\\{}#%,"))
    private static let verbatimEnvironments: Set<String> = ["verbatim", "verbatim*", "Verbatim", "BVerbatim", "LVerbatim",
                                                              "lstlisting", "minted", "comment"]

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}

private struct BibTeXReader {
    struct Record {
        let key: String
        let fields: [String?]
        let range: NSRange
    }

    private let source: NSString
    private var offset = 0
    private var current: UInt16? { offset < source.length ? source.character(at: offset) : nil }
    private static let metadata: Set = ["author", "editor", "year", "date", "title"]

    init(_ text: String) { source = text as NSString }

    mutating func next() -> Record? {
        while current != nil {
            skipTrivia()
            guard current != nil else { return nil }
            guard consume(0x40) else { offset += 1; continue }
            let type = word().lowercased()
            skipTrivia()
            let ending: UInt16
            if consume(0x7B) { ending = 0x7D }
            else if consume(0x28) { ending = 0x29 }
            else { continue }
            let start = offset
            guard let body = readDelimited(ending) else { return nil }
            if type.isEmpty || ["comment", "preamble", "string"].contains(type) { continue }
            var fields = BibTeXReader(body)
            fields.skipTrivia()
            let keyStart = fields.offset
            let key = fields.word()
            guard !key.isEmpty, key.utf16.count <= 300 else { continue }
            fields.skipTrivia()
            guard fields.consume(0x2C) || fields.current == nil else { continue }
            let metadata = fields.readFields()
            return Record(key: key, fields: [metadata["author"] ?? metadata["editor"],
                                             metadata["year"] ?? metadata["date"], metadata["title"]],
                          range: NSRange(location: start + keyStart, length: key.utf16.count))
        }
        return nil
    }

    private mutating func readFields() -> [String: String] {
        var fields: [String: String] = [:]
        while current != nil {
            skipTrivia()
            if consume(0x2C) { continue }
            let field = word().lowercased()
            skipTrivia()
            guard !field.isEmpty, consume(0x3D) else { break }
            var atoms: [String] = []
            repeat {
                skipTrivia()
                let value: String?
                if consume(0x7B) { value = readDelimited(0x7D) }
                else if consume(0x22) { value = readDelimited(0x22) }
                else { value = word() }
                guard let value, !value.isEmpty else { break }
                if Self.metadata.contains(field) { atoms.append(value) }
                skipTrivia()
            } while consume(0x23)
            if !atoms.isEmpty { fields[field] = Self.plainText(atoms.joined()) }
        }
        return fields
    }

    private mutating func readDelimited(_ ending: UInt16) -> String? {
        let start = offset
        var braces = 0
        var quoted = false
        while let character = current {
            offset += 1
            if character == 0x5C {
                if current != nil { offset += 1 }
            } else if character == ending, braces == 0, !quoted {
                return source.substring(with: NSRange(location: start, length: offset - start - 1))
            } else if character == 0x7B {
                braces += 1
            } else if character == 0x7D, braces > 0 {
                braces -= 1
            } else if character == 0x22, ending == 0x29, braces == 0 {
                quoted.toggle()
            }
        }
        return nil
    }

    private mutating func word() -> String {
        let start = offset
        while let character = current, !Self.isWhitespace(character),
              character != 0x28 && character != 0x29 && character != 0x7B && character != 0x7D && character != 0x22,
              character != 0x2C && character != 0x3D && character != 0x23 && character != 0x25 && character != 0x40 {
            offset += 1
        }
        return source.substring(with: NSRange(location: start, length: offset - start))
    }

    private mutating func skipTrivia() {
        while let character = current {
            if Self.isWhitespace(character) {
                offset += 1
            } else if character == 0x25 {
                while let next = current, next != 0x0A, next != 0x0D { offset += 1 }
            } else {
                break
            }
        }
    }

    private mutating func consume(_ character: UInt16) -> Bool {
        guard current == character else { return false }
        offset += 1
        return true
    }

    private static func isWhitespace(_ character: UInt16) -> Bool {
        character == 0x20 || (0x09...0x0D).contains(character)
    }

    private static let accents = try! NSRegularExpression(pattern: #"\\['`"~^=.]|\\[cuvHkbd](?=[\s{])"#)

    private static func plainText(_ field: String) -> String {
        let value = accents.stringByReplacingMatches(in: field, range: NSRange(location: 0, length: field.utf16.count),
                                                     withTemplate: "")
        return value.filter { $0 != "{" && $0 != "}" }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
