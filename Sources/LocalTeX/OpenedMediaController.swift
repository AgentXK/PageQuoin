import AppKit
import ImageIO
import PDFKit

@MainActor
final class OpenedMediaController: NSViewController {
    private let kind: ProjectFileKind
    private var data: Data
    private let name: String
    private weak var currentImageView: NSImageView?
    private weak var currentPDFView: PreviewPDFView?

    init(kind: ProjectFileKind, data: Data, name: String) {
        self.kind = kind
        self.data = data
        self.name = name
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    func replaceData(_ data: Data) {
        self.data = data
        if let currentImageView { currentImageView.image = NSImage(data: data) ?? decodedImage() }
        if let currentPDFView { currentPDFView.replaceDocument(PDFDocument(data: data)) }
    }

    override func loadView() {
        switch kind {
        case .pdf: view = makePDFView()
        case .image: view = makeImageView()
        case .latex, .text: view = NSView()
        }
    }

    private func makeImageView() -> NSView {
        let imageView = FittedImageView()
        currentImageView = imageView
        imageView.image = NSImage(data: data) ?? decodedImage()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.animates = true
        imageView.setAccessibilityLabel(name)

        let canvas = WorkspaceSurface(AppPalette.editor)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 12),
            imageView.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -12),
            imageView.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -12)
        ])
        return canvas
    }

    private func decodedImage() -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    private func makePDFView() -> NSView {
        let pdf = PreviewPDFView()
        currentPDFView = pdf
        pdf.displayMode = .singlePageContinuous
        pdf.backgroundColor = AppPalette.preview
        pdf.minScaleFactor = 0.15
        pdf.maxScaleFactor = 5
        pdf.setAccessibilityLabel(name)
        let navigator = PDFPageNavigator(pdfView: pdf)

        let canvas = WorkspaceSurface(AppPalette.chrome)
        for child in [navigator, pdf] {
            child.translatesAutoresizingMaskIntoConstraints = false
            canvas.addSubview(child)
        }
        NSLayoutConstraint.activate([
            navigator.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 3),
            navigator.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            navigator.leadingAnchor.constraint(greaterThanOrEqualTo: canvas.leadingAnchor, constant: 4),
            navigator.trailingAnchor.constraint(lessThanOrEqualTo: canvas.trailingAnchor, constant: -4),
            pdf.topAnchor.constraint(equalTo: navigator.bottomAnchor, constant: 3),
            pdf.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            pdf.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            pdf.trailingAnchor.constraint(equalTo: canvas.trailingAnchor)
        ])
        pdf.document = PDFDocument(data: data)
        pdf.autoScales = true
        return canvas
    }
}

private final class FittedImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}
