import CoreGraphics
import Darwin
import Foundation
import zlib

/// Line-level source positions for the SyncTeX records emitted by Tectonic.
struct SyncTeXMap: Sendable {
    struct PDFLocation: Sendable {
        let pageIndex: Int
        /// PDF points measured from the top left of the page.
        let rect: CGRect
    }

    struct SourceLocation: Sendable {
        let file: URL?
        let line: Int
    }

    private struct Source {
        let file: URL?
        let key: String

        init(file: URL?) {
            self.file = file
            key = file.map(SyncTeXMap.canonicalPath) ?? ""
        }
    }

    private struct Marker: Sendable {
        let source: SourceLocation
        let kind: MarkerKind
        let location: PDFLocation

        func precedes(_ other: Self) -> Bool {
            if kind != other.kind { return kind.rawValue < other.kind.rawValue }
            if location.pageIndex != other.location.pageIndex {
                return location.pageIndex < other.location.pageIndex
            }
            if location.rect.minY != other.location.rect.minY {
                return location.rect.minY < other.location.rect.minY
            }
            return location.rect.minX < other.location.rect.minX
        }

        func distance(to point: CGPoint) -> CGFloat {
            let rect = location.rect
            let horizontal = max(0, rect.minX - point.x, point.x - rect.maxX)
            let vertical = max(0, rect.minY - point.y, point.y - rect.maxY)
            // Choose a typeset row before choosing the closest word boundary on it.
            // TeX may label the containing paragraph box with the paragraph's final line.
            return vertical * 8 + min(horizontal, 120) * 0.55 + kind.penalty
        }
    }

    fileprivate enum MarkerKind: Int, Sendable {
        case text, box, spacing

        var penalty: CGFloat {
            switch self {
            case .text: 0
            case .box: 33
            case .spacing: 50
            }
        }
    }

    private let byPage: [Int: [Marker]]
    private let bySource: [String: [Marker]]

    init?(data: Data, mainFile: URL?, workingDirectory: URL, stagedProjectRoot: URL? = nil,
          originalProjectRoot: URL? = nil) {
        guard let decoded = Self.decode(data) else { return nil }
        var parser = Parser()
        let text = String(decoding: decoded, as: UTF8.self)
        guard text.hasPrefix("SyncTeX Version:") else { return nil }
        text.enumerateLines { line, _ in parser.read(line) }
        let sources = parser.inputs.reduce(into: [Int: Source]()) { sources, input in
            let (tag, name) = input
            if tag == 1 && (name == "texput" || name == "texput.tex" || name == "-") {
                sources[tag] = Source(file: mainFile?.standardizedFileURL)
            } else if let source = Self.sourceURL(name, workingDirectory: workingDirectory,
                                                  stagedProjectRoot: stagedProjectRoot,
                                                  originalProjectRoot: originalProjectRoot) {
                sources[tag] = Source(file: source)
            }
        }

        var pages: [Int: [Marker]] = [:]
        var sourceLines: [String: [Int: Marker]] = [:]
        for record in parser.records {
            guard let source = sources[record.tag] else { continue }
            let location = PDFLocation(pageIndex: record.pageIndex, rect: parser.pdfRect(for: record))
            let marker = Marker(source: SourceLocation(file: source.file, line: record.line),
                                kind: record.kind, location: location)
            pages[record.pageIndex, default: []].append(marker)
            if let previous = sourceLines[source.key]?[record.line], !marker.precedes(previous) { continue }
            sourceLines[source.key, default: [:]][record.line] = marker
        }
        guard !pages.isEmpty else { return nil }
        byPage = pages
        bySource = sourceLines.mapValues { $0.values.sorted { $0.source.line < $1.source.line } }
    }

    func forward(file: URL?, line: Int) -> PDFLocation? {
        guard line > 0, let targets = bySource[file.map(Self.canonicalPath) ?? ""], !targets.isEmpty else { return nil }
        var lower = 0
        var upper = targets.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if targets[middle].source.line < line { lower = middle + 1 }
            else { upper = middle }
        }
        let after = lower < targets.count ? targets[lower] : nil
        let before = lower > 0 ? targets[lower - 1] : nil
        if let after, let before, line - before.source.line <= after.source.line - line {
            return before.location
        }
        return (after ?? before)?.location
    }

    /// Finds the source line nearest a point measured from the top left of the page.
    func inverse(pageIndex: Int, point: CGPoint) -> SourceLocation? {
        guard point.x.isFinite, point.y.isFinite, let markers = byPage[pageIndex] else { return nil }
        var best: Marker?
        var bestDistance: CGFloat = .infinity
        for marker in markers {
            let distance = marker.distance(to: point)
            if distance < bestDistance {
                best = marker
                bestDistance = distance
            }
        }
        return best?.source
    }

    private static func sourceURL(_ name: String, workingDirectory: URL, stagedProjectRoot: URL?,
                                  originalProjectRoot: URL?) -> URL? {
        guard !name.isEmpty, !name.utf8.contains(0) else { return nil }
        let file = (name.hasPrefix("/") ? URL(fileURLWithPath: name) :
            workingDirectory.appendingPathComponent(name)).standardizedFileURL
        if let staged = stagedProjectRoot?.standardizedFileURL, let root = originalProjectRoot {
            // Map recorded paths before resolving links back to the original project.
            let recorded = file.pathComponents
            let canonicalStage = URL(fileURLWithPath: canonicalPath(staged), isDirectory: true).pathComponents
            for prefix in [staged.pathComponents, canonicalStage] where recorded.starts(with: prefix) {
                return root.appendingPathComponent(recorded.dropFirst(prefix.count).joined(separator: "/"))
                    .standardizedFileURL
            }
        }
        // Keep paths handed back to the editor in the spelling used by its project.
        // Tectonic may report /private/var/... for a project opened at /var/....
        let root = originalProjectRoot ?? workingDirectory
        let rootPath = URL(fileURLWithPath: canonicalPath(root), isDirectory: true).pathComponents
        let filePath = URL(fileURLWithPath: canonicalPath(file)).pathComponents
        if filePath.count > rootPath.count, filePath.starts(with: rootPath) {
            return root.appendingPathComponent(filePath.dropFirst(rootPath.count).joined(separator: "/"))
                .standardizedFileURL
        }
        return file
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { path in
            // Foundation may preserve the /var or /tmp spelling even for an existing path.
            guard let path, let resolved = realpath(path, nil) else { return url.standardizedFileURL.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    private static func decode(_ data: Data) -> Data? {
        let limit = 64 * 1024 * 1024
        guard data.count <= limit else { return nil }
        guard data.starts(with: [0x1f, 0x8b]) else { return data }
        return data.withUnsafeBytes { input -> Data? in
            guard let input = input.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer(mutating: input)
            stream.avail_in = uInt(data.count)
            guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
            else { return nil }
            defer { inflateEnd(&stream) }

            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let size = buffer.count
            repeat {
                let status = buffer.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = size - Int(stream.avail_out)
                guard result.count + produced <= limit else { return nil }
                result.append(contentsOf: buffer.prefix(produced))
                if status == Z_STREAM_END { return result }
                guard status == Z_OK, produced > 0 else { return nil }
            } while true
        }
    }
}

private extension SyncTeXMap {
    struct Record {
        let pageIndex: Int
        let tag: Int
        let line: Int
        let kind: MarkerKind
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
        let depth: CGFloat
    }

    struct Parser {
        private static let scaledPointsPerPDFPoint: CGFloat = 65_781.76
        var inputs: [Int: String] = [:]
        var records: [Record] = []
        private var pageIndex: Int?
        private var unit: CGFloat = 1
        private var magnification: CGFloat = 1000
        private var xOffset: CGFloat = 0
        private var yOffset: CGFloat = 0
        private var postMagnification: CGFloat = 1
        private var postXOffset: CGFloat?
        private var postYOffset: CGFloat?
        private var isPostscript = false

        mutating func read(_ line: String) {
            if line.hasPrefix("Input:") {
                let fields = line.dropFirst(6).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                if fields.count == 2, let tag = Int(fields[0]) { inputs[tag] = String(fields[1]) }
                return
            }
            guard let first = line.first else { return }
            let payload = line.dropFirst()
            switch first {
            case "{":
                pageIndex = Int(payload).flatMap { $0 > 0 ? $0 - 1 : nil }
            case "}":
                pageIndex = nil
            case "(", "h", "r", "g", "x", "$", "k":
                readRecord(payload, prefix: first)
            default:
                readSettings(line)
            }
        }

        private mutating func readRecord(_ payload: Substring, prefix: Character) {
            guard let pageIndex else { return }
            let fields = payload.split(separator: ":", maxSplits: 2)
            guard fields.count >= 2 else { return }
            let source = fields[0].split(separator: ",", maxSplits: 2)
            let coordinate = fields[1].split(separator: ",", maxSplits: 1)
            guard source.count >= 2, let tag = Int(source[0]), tag > 0,
                  let line = Int(source[1]), line > 0, coordinate.count == 2,
                  let x = scalar(coordinate[0]), let y = scalar(coordinate[1]) else { return }

            let sizes = fields.count == 3 ? fields[2].split(separator: ",", maxSplits: 2) : []
            if prefix == "(" || prefix == "h" || prefix == "r" {
                guard sizes.count == 3, let width = scalar(sizes[0]), let height = scalar(sizes[1]),
                      let depth = scalar(sizes[2]), height > 0 || depth > 0 else { return }
                records.append(Record(pageIndex: pageIndex, tag: tag, line: line, kind: .box, x: x, y: y,
                                      width: width, height: height, depth: depth))
            } else {
                let previous = records.last
                let rightMarginGlue = prefix == "g" && previous?.kind == .spacing
                    && previous?.pageIndex == pageIndex && previous?.x == x && previous?.y == y
                let kind: MarkerKind = prefix == "k" || rightMarginGlue ? .spacing : .text
                records.append(Record(pageIndex: pageIndex, tag: tag, line: line, kind: kind, x: x, y: y,
                                      width: 0, height: 0, depth: 0))
            }
        }

        private mutating func readSettings(_ line: String) {
            if line == "Post scriptum:" {
                isPostscript = true
                return
            }
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2 else { return }
            let value = fields[1].trimmingCharacters(in: .whitespaces)
            switch (fields[0], isPostscript) {
            case ("Unit", false): if let value = scalar(value[...]), value > 0 { unit = value }
            case ("Magnification", false): if let value = scalar(value[...]), value > 0 { magnification = value }
            case ("X Offset", false): xOffset = scalar(value[...]) ?? xOffset
            case ("Y Offset", false): yOffset = scalar(value[...]) ?? yOffset
            case ("Magnification", true): if let value = scalar(value[...]), value > 0 { postMagnification = value }
            case ("X Offset", true): postXOffset = postOffset(value)
            case ("Y Offset", true): postYOffset = postOffset(value)
            default: break
            }
        }

        private func scalar(_ value: Substring) -> CGFloat? {
            guard let number = Double(value), number.isFinite, abs(number) <= 1e12 else { return nil }
            return CGFloat(number)
        }

        private func postOffset(_ value: String) -> CGFloat? {
            let units: [(String, CGFloat)] = [("sp", 1 / Self.scaledPointsPerPDFPoint), ("pt", 72 / 72.27),
                                             ("bp", 1), ("in", 72), ("cm", 72 / 2.54), ("mm", 72 / 25.4)]
            for (name, factor) in units where value.hasSuffix(name) {
                return scalar(value.dropLast(name.count)).map { $0 * factor }
            }
            return scalar(value[...]).map { $0 / Self.scaledPointsPerPDFPoint }
        }

        func pdfRect(for record: Record) -> CGRect {
            let unitScale = unit / Self.scaledPointsPerPDFPoint
            let scale = unitScale * magnification / 1000 * postMagnification
            let x = record.x * scale + (postXOffset ?? xOffset * unitScale)
            let y = record.y * scale + (postYOffset ?? yOffset * unitScale)
            let width = record.width * scale
            let height = max(7, record.height * scale)
            let depth = max(2, record.depth * scale)
            return CGRect(x: x + min(0, width), y: y - height, width: max(2, abs(width)), height: height + depth)
        }
    }
}
