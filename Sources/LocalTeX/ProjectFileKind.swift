import AppKit
import UniformTypeIdentifiers

enum ProjectFileKind: String {
    case latex = "org.tug.tex"
    case text = "public.plain-text"
    case image = "public.image"
    case pdf = "com.adobe.pdf"

    var isEditable: Bool { self == .latex || self == .text }

    var symbol: String {
        switch self {
        case .latex, .text: "doc.text"
        case .image: "photo"
        case .pdf: "doc.richtext"
        }
    }

    static func detect(for url: URL) -> Self? {
        guard url.isFileURL else { return nil }
        let ext = url.pathExtension.lowercased()
        if ext == "tex" || ext == "ltx" { return .latex }
        if ext.isEmpty { return .text }
        guard let type = UTType(filenameExtension: ext), !type.isDynamic else { return .text }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .text), !type.conforms(to: .rtf), !type.conforms(to: .rtfd) { return .text }
        return nil
    }
}

enum ProjectTextEncoding {
    case utf8, utf8WithBOM, utf16LittleEndian, utf16BigEndian, utf32LittleEndian, utf32BigEndian

    private var format: (encoding: String.Encoding, prefix: [UInt8]) {
        switch self {
        case .utf8: (.utf8, [])
        case .utf8WithBOM: (.utf8, [0xef, 0xbb, 0xbf])
        case .utf16LittleEndian: (.utf16LittleEndian, [0xff, 0xfe])
        case .utf16BigEndian: (.utf16BigEndian, [0xfe, 0xff])
        case .utf32LittleEndian: (.utf32LittleEndian, [0xff, 0xfe, 0x00, 0x00])
        case .utf32BigEndian: (.utf32BigEndian, [0x00, 0x00, 0xfe, 0xff])
        }
    }

    static func decode(_ data: Data) -> (text: String, encoding: Self)? {
        // Check UTF-32 first because its little-endian BOM also starts with the UTF-16 BOM.
        let tagged: [Self] = [.utf32LittleEndian, .utf32BigEndian, .utf16LittleEndian, .utf16BigEndian, .utf8WithBOM]
        let encoding = tagged.first { data.starts(with: $0.format.prefix) } ?? .utf8
        let format = encoding.format
        guard let text = String(data: data.dropFirst(format.prefix.count), encoding: format.encoding),
              !text.utf8.contains(0) else { return nil }
        return (text, encoding)
    }

    func encode(_ text: String) throws -> Data {
        let format = format
        guard let bytes = text.data(using: format.encoding) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return Data(format.prefix) + bytes
    }
}

@MainActor
final class ProjectDocumentController: NSDocumentController {
    override func typeForContents(of url: URL) throws -> String {
        if let kind = ProjectFileKind.detect(for: url),
           (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            return kind.rawValue
        }
        throw CocoaError(.fileReadUnknown, userInfo: [
            NSURLErrorKey: url,
            NSLocalizedDescriptionKey: "PageQuoin can open plain text, images, and PDF files."
        ])
    }
}

@MainActor
final class ProjectOpenPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        guard let attributes = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isRegularFileKey]) else {
            return false
        }
        if attributes.isDirectory == true { return attributes.isPackage != true }
        return attributes.isRegularFile == true && ProjectFileKind.detect(for: url) != nil
    }
}
