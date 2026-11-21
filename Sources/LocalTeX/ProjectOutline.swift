import Foundation

struct TeXOutlineHeading: Equatable, Sendable {
    let level: Int
    let title: String
    let range: NSRange
    let file: URL?
}

enum ProjectOutline: Sendable {
    case document(source: String, file: URL?)
    case project(main: URL, root: URL, openSources: [URL: String])

    func headings() -> [TeXOutlineHeading] {
        switch self {
        case let .document(source, file):
            return TeXOutlineParser.parse(source, file: file).compactMap { entry in
                if case let .heading(heading) = entry { return heading }
                return nil
            }
        case let .project(main, root, openSources):
            var loader = OutlineLoader(root: root, workingDirectory: main.deletingLastPathComponent(), openSources: openSources)
            loader.visit(main.standardizedFileURL.resolvingSymlinksInPath())
            return loader.headings
        }
    }
}

private enum OutlineEntry {
    case heading(TeXOutlineHeading)
    case include(String)
    case imported(file: String, directory: String, relative: Bool)
}

private struct OutlineLoader {
    private static let maxSourceBytes = 2 * 1024 * 1024
    let root: URL
    let workingDirectory: URL
    let openSources: [URL: String]
    private var activeFiles: Set<URL> = []
    private var parsed: [URL: [OutlineEntry]] = [:]
    private var remainingVisits = 512
    private(set) var headings: [TeXOutlineHeading] = []

    init(root: URL, workingDirectory: URL, openSources: [URL: String]) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.workingDirectory = workingDirectory
        self.openSources = openSources
    }

    mutating func visit(_ file: URL, importDirectory: URL? = nil) {
        guard !Task.isCancelled, remainingVisits > 0, activeFiles.count < 48,
              contains(file), activeFiles.insert(file).inserted else { return }
        remainingVisits -= 1
        defer { activeFiles.remove(file) }

        let entries: [OutlineEntry]
        if let cached = parsed[file] {
            entries = cached
        } else {
            entries = read(file).map { TeXOutlineParser.parse($0, file: file) } ?? []
            parsed[file] = entries
        }
        let containingDirectory = file.deletingLastPathComponent()
        for entry in entries {
            guard !Task.isCancelled, headings.count < 8_000 else { return }
            switch entry {
            case let .heading(heading):
                headings.append(heading)
            case let .include(path):
                let directories = [importDirectory, workingDirectory, containingDirectory].compactMap { $0 }
                if let included = resolve(path, in: directories) { visit(included, importDirectory: importDirectory) }
            case let .imported(path, directory, relative):
                let base = relative ? (importDirectory ?? containingDirectory) : workingDirectory
                let importedDirectory = URL(fileURLWithPath: directory, isDirectory: true, relativeTo: base).absoluteURL
                if let included = resolve(path, in: [importedDirectory]) { visit(included, importDirectory: importedDirectory) }
            }
        }
    }

    private func resolve(_ path: String, in directories: [URL]) -> URL? {
        for directory in directories {
            let file = URL(fileURLWithPath: path, isDirectory: false, relativeTo: directory).absoluteURL
            let candidates = file.pathExtension.isEmpty ? [file.appendingPathExtension("tex"), file] : [file]
            for candidate in candidates {
                let normalized = candidate.standardizedFileURL.resolvingSymlinksInPath()
                guard contains(normalized), ProjectFileKind.detect(for: normalized)?.isEditable == true else { continue }
                if openSources[normalized] != nil || (try? normalized.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    return normalized
                }
            }
        }
        return nil
    }

    private func contains(_ file: URL) -> Bool {
        let base = root.pathComponents
        let path = file.pathComponents
        return path.count > base.count && path.starts(with: base)
    }

    private func read(_ file: URL) -> String? {
        if let source = openSources[file] { return source.utf8.count <= Self.maxSourceBytes ? source : nil }
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= Self.maxSourceBytes,
              let data = try? Data(contentsOf: file), data.count <= Self.maxSourceBytes else { return nil }
        return ProjectTextEncoding.decode(data)?.text
    }
}

private enum TeXOutlineParser {
    private static let levels = [
        "part": 0, "chapter": 1, "section": 2, "subsection": 3,
        "subsubsection": 4, "paragraph": 5, "subparagraph": 6
    ]
    private static let verbatimEnvironments: Set = [
        "verbatim", "verbatim*", "Verbatim", "BVerbatim", "LVerbatim", "lstlisting", "minted", "comment"
    ]
    private static let textFormatting: Set = [
        "emph", "textbf", "textit", "textup", "textsl", "textsc",
        "textrm", "textsf", "texttt", "textnormal", "underline", "mbox"
    ]

    static func parse(_ text: String, file: URL?) -> [OutlineEntry] {
        var scanner = TeXScanner(text)
        var entries: [OutlineEntry] = []
        var insideDocument = false
        while let command = scanner.nextCommand() {
            if Task.isCancelled { return [] }
            if command == "verb" || command == "lstinline" {
                scanner.skipInlineVerbatim(allowsOptions: command == "lstinline")
                continue
            }
            if command == "begin" || command == "end" {
                scanner.skipTrivia()
                guard let range = scanner.readGroup() else { continue }
                let environment = scanner.source.substring(with: range)
                if command == "begin" && verbatimEnvironments.contains(environment) {
                    scanner.skipVerbatimEnvironment(environment)
                } else if environment == "document" {
                    if command == "end" && insideDocument { break }
                    if command == "begin" && !insideDocument {
                        entries.removeAll()
                        insideDocument = true
                    }
                }
                continue
            }
            if command == "input" || command == "include" {
                if let path = scanner.readPath(allowsUngrouped: command == "input") { entries.append(.include(path)) }
                continue
            }
            if command == "import" || command == "subimport" || command == "inputfrom" || command == "subinputfrom"
                || command == "includefrom" || command == "subincludefrom" {
                _ = scanner.consume(TeXScanner.star)
                if let directory = scanner.readPath(), let path = scanner.readPath() {
                    entries.append(.imported(file: path, directory: directory, relative: command.hasPrefix("sub")))
                }
                continue
            }
            guard let level = levels[command] else { continue }
            scanner.skipTrivia()
            _ = scanner.consume(TeXScanner.star)
            scanner.skipTrivia()
            if scanner.current == TeXScanner.leftBracket {
                guard scanner.readGroup(optional: true) != nil else { continue }
                scanner.skipTrivia()
            }
            guard let range = scanner.readGroup() else { continue }
            let title = displayTitle(scanner.source.substring(with: range))
            entries.append(.heading(TeXOutlineHeading(level: level, title: title.isEmpty ? "Untitled" : title,
                                                    range: range, file: file)))
        }
        return entries
    }

    private static func displayTitle(_ text: String) -> String {
        var scanner = TeXScanner(text)
        var title = ""
        while let character = scanner.current {
            switch character {
            case TeXScanner.comment:
                scanner.skipComment()
            case TeXScanner.backslash:
                let start = scanner.offset
                let command = scanner.readCommand()
                switch command {
                case "%", "#", "_", "{", "}", "$", "&": title += command
                case "\\", " ", "\n", "\r": title += " "
                case "LaTeX", "TeX": title += command
                case _ where textFormatting.contains(command): break
                default:
                    title += scanner.source.substring(with: NSRange(location: start, length: scanner.offset - start))
                }
            case TeXScanner.leftBrace, TeXScanner.rightBrace:
                scanner.offset += 1
            case TeXScanner.tilde:
                scanner.offset += 1
                title += " "
            default:
                let start = scanner.offset
                scanner.offset += 1
                while let next = scanner.current,
                      next != TeXScanner.comment && next != TeXScanner.backslash &&
                      next != TeXScanner.leftBrace && next != TeXScanner.rightBrace && next != TeXScanner.tilde {
                    scanner.offset += 1
                }
                title += scanner.source.substring(with: NSRange(location: start, length: scanner.offset - start))
            }
        }
        return title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

struct TeXScanner {
    static let backslash: UInt16 = 0x5C
    static let comment: UInt16 = 0x25
    static let leftBrace: UInt16 = 0x7B
    static let rightBrace: UInt16 = 0x7D
    static let leftBracket: UInt16 = 0x5B
    static let rightBracket: UInt16 = 0x5D
    static let star: UInt16 = 0x2A
    static let tilde: UInt16 = 0x7E

    let source: NSString
    private let length: Int
    var offset = 0
    var current: UInt16? { offset < length ? source.character(at: offset) : nil }

    init(_ text: String) {
        source = text as NSString
        length = source.length
    }

    mutating func nextCommand() -> String? {
        while let character = current {
            switch character {
            case Self.backslash: return readCommand()
            case Self.comment: skipComment()
            default: offset += 1
            }
        }
        return nil
    }

    mutating func readCommand() -> String {
        offset += 1
        let start = offset
        while let character = current, Self.isCommandLetter(character) {
            offset += 1
        }
        if offset == start && offset < length {
            offset = NSMaxRange(source.rangeOfComposedCharacterSequence(at: offset))
        }
        return source.substring(with: NSRange(location: start, length: offset - start))
    }

    mutating func consume(_ character: UInt16) -> Bool {
        guard current == character else { return false }
        offset += 1
        return true
    }

    mutating func skipTrivia() {
        while let character = current {
            if character == Self.comment {
                skipComment()
            } else if Self.isWhitespace(character) {
                offset += 1
            } else {
                break
            }
        }
    }

    mutating func skipComment() {
        while let character = current, !Self.isNewline(character) {
            offset += 1
        }
        _ = consume(0x0D)
        _ = consume(0x0A)
    }

    mutating func readGroup(optional: Bool = false) -> NSRange? {
        let opening = optional ? Self.leftBracket : Self.leftBrace
        let closing = optional ? Self.rightBracket : Self.rightBrace
        guard consume(opening) else { return nil }
        let start = offset
        var depth = 1
        var braces = 0
        while let character = current {
            if character == Self.backslash {
                _ = readCommand()
            } else if character == Self.comment {
                skipComment()
            } else {
                offset += 1
                if optional && character == Self.leftBrace {
                    braces += 1
                } else if optional && character == Self.rightBrace && braces > 0 {
                    braces -= 1
                } else if braces == 0 && character == opening {
                    depth += 1
                } else if braces == 0 && character == closing {
                    depth -= 1
                    if depth == 0 {
                        return NSRange(location: start, length: offset - start - 1)
                    }
                }
            }
        }
        return nil
    }

    mutating func readPath(allowsUngrouped: Bool = false) -> String? {
        skipTrivia()
        let range: NSRange
        if current == Self.leftBrace, let group = readGroup() {
            range = group
        } else if allowsUngrouped {
            let quoted = consume(0x22)
            let start = offset
            while let character = current, character != Self.comment, character != Self.backslash,
                  character != Self.leftBrace, character != Self.rightBrace,
                  quoted ? character != 0x22 && !Self.isNewline(character) : !Self.isWhitespace(character) {
                offset += 1
            }
            range = NSRange(location: start, length: offset - start)
            if quoted && !consume(0x22) { return nil }
        } else {
            return nil
        }
        let path = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.rangeOfCharacter(from: CharacterSet(charactersIn: "\\{}#%\n\r\0")) == nil else { return nil }
        return path
    }

    mutating func skipInlineVerbatim(allowsOptions: Bool) {
        _ = consume(Self.star)
        if allowsOptions && current == Self.leftBracket {
            _ = readGroup(optional: true)
        }
        guard let marker = current, !Self.isWhitespace(marker) else { return }
        let terminator = marker == Self.leftBrace && allowsOptions ? Self.rightBrace : marker
        offset += 1
        while let character = current, !Self.isNewline(character) {
            offset += 1
            if character == terminator { return }
        }
    }

    mutating func skipVerbatimEnvironment(_ name: String) {
        let range = source.range(of: "\\end{\(name)}", range: NSRange(location: offset, length: length - offset))
        offset = range.location == NSNotFound ? length : NSMaxRange(range)
    }

    private static func isCommandLetter(_ character: UInt16) -> Bool {
        (0x41...0x5A).contains(character) || (0x61...0x7A).contains(character) || character == 0x40
    }

    private static func isWhitespace(_ character: UInt16) -> Bool {
        character == 0x20 || (0x09...0x0D).contains(character)
    }

    private static func isNewline(_ character: UInt16) -> Bool {
        character == 0x0A || character == 0x0D
    }
}
