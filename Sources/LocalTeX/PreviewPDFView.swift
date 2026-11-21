import AppKit
import CoreImage.CIFilterBuiltins
import PDFKit

@MainActor
final class PreviewPDFView: PDFView {
    fileprivate struct ReadingPosition: Codable, Equatable {
        let pageIndex: Int
        let pagePoint: CGPoint
        var offsetInViewport: CGPoint
        let line: String?
        let lineMidY: CGFloat
    }

    struct TabViewport {
        fileprivate let documentID: ObjectIdentifier?
        fileprivate let clipBounds: CGRect
        fileprivate let position: ReadingPosition
        fileprivate let autoScales: Bool
        fileprivate let scale: CGFloat
    }

    struct SavedViewport: Codable, Equatable {
        fileprivate let clipSize: CGSize
        fileprivate let position: ReadingPosition
        fileprivate let autoScales: Bool
        fileprivate let scale: CGFloat
    }

    private var eventMonitor: Any?
    private var clearHighlightTask: Task<Void, Never>?
    private var sourceHighlight: (page: PDFPage, bounds: CGRect, view: PDFSourceLineHighlightView)?
    private var pendingReadingPosition: ReadingPosition?
    private var pendingTabViewport: TabViewport?
    private lazy var darkPageFilter: CIFilter = {
        let filter = CIFilter.colorMatrix()
        // Reverse luminance while retaining some chroma so figures keep their hues.
        let chroma: CGFloat = 0.60
        let luminance = chroma + 0.70
        let red = -luminance * 0.2126
        let green = -luminance * 0.7152
        let blue = -luminance * 0.0722
        filter.rVector = CIVector(x: red + chroma, y: green, z: blue, w: 0)
        filter.gVector = CIVector(x: red, y: green + chroma, z: blue, w: 0)
        filter.bVector = CIVector(x: red, y: green, z: blue + chroma, w: 0)
        filter.biasVector = CIVector(x: 0.72, y: 0.727, z: 0.737, w: 0)
        return filter
    }()
    var onSourceJump: ((Int, CGPoint) -> Bool)?
    var usesDarkAppearance = false {
        didSet {
            guard oldValue != usesDarkAppearance else { return }
            if usesDarkAppearance { wantsLayer = true }
            // Use a dark scroll thumb as filter input so the result stays legible in either app theme.
            appearance = usesDarkAppearance ? NSAppearance(named: .aqua) : nil
            // Filter only the visible PDF viewport, which keeps PDFKit's rendering and navigation in place.
            contentFilters = usesDarkAppearance ? [darkPageFilter] : []
            sourceHighlight?.view.usesDarkAppearance = usesDarkAppearance
            updateBackgroundColor()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        guard window != nil else {
            clearSourceHighlight()
            return
        }

        // The inner PDFKit views normally receive these events first.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            let handled = event.type == .scrollWheel ? handleWheelZoom(event) : handleSourceJump(event)
            return handled ? nil : event
        }
    }

    override func layout() {
        super.layout()
        restoreTabViewportIfVisible()
        restoreReadingPositionIfVisible()
        updateSourceHighlightFrame()
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        clearHighlightTask?.cancel()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundColor()
    }

    private func updateBackgroundColor() {
        if usesDarkAppearance {
            // The same filter maps this neutral surround to a slightly lighter shade than the paper.
            backgroundColor = NSColor(srgbRed: 0.99, green: 0.99, blue: 0.99, alpha: 1)
            return
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            backgroundColor = AppPalette.preview.usingColorSpace(.sRGB) ?? AppPalette.preview
        }
    }

    func replaceDocument(_ replacement: PDFDocument?) {
        let position = pendingReadingPosition ?? captureReadingPosition()
        let previousPage = currentPage.flatMap { document?.index(for: $0) } ?? 0
        let fitted = document == nil || autoScales
        let previousScale = scaleFactor
        pendingReadingPosition = nil
        clearSourceHighlight()
        document = replacement
        isHidden = replacement == nil
        guard let replacement, replacement.pageCount > 0 else {
            pendingTabViewport = nil
            return
        }

        if fitted { autoScales = true }
        else { scaleFactor = previousScale }
        if let position {
            pendingReadingPosition = position
            if pendingTabViewport == nil { restoreReadingPositionIfVisible() }
        } else if let page = replacement.page(at: min(previousPage, replacement.pageCount - 1)) {
            go(to: page)
        }
    }

    func captureTabViewport() -> TabViewport? {
        captureViewport(matchText: false)
    }

    func captureSavedViewport() -> SavedViewport? {
        guard let viewport = captureViewport(matchText: true) else { return nil }
        return SavedViewport(clipSize: viewport.clipBounds.size, position: viewport.position,
                             autoScales: viewport.autoScales, scale: viewport.scale)
    }

    func restoreSavedViewport(_ saved: SavedViewport) {
        let point = saved.position.pagePoint
        let offset = saved.position.offsetInViewport
        guard saved.scale.isFinite, saved.scale > 0, saved.position.pageIndex >= 0,
              point.x.isFinite, point.y.isFinite, offset.x.isFinite, offset.y.isFinite,
              saved.position.lineMidY.isFinite, saved.clipSize.width.isFinite, saved.clipSize.height.isFinite else { return }
        restoreTabViewport(TabViewport(documentID: nil, clipBounds: CGRect(origin: .zero, size: saved.clipSize),
                                       position: saved.position, autoScales: saved.autoScales, scale: saved.scale))
    }

    private func captureViewport(matchText: Bool) -> TabViewport? {
        if let pendingTabViewport { return pendingTabViewport }
        guard let document, let clip = documentView?.enclosingScrollView?.contentView,
              let position = pendingReadingPosition ?? captureReadingPosition(matchText: matchText) else { return nil }
        return TabViewport(documentID: ObjectIdentifier(document), clipBounds: clip.bounds,
                           position: position, autoScales: autoScales, scale: scaleFactor)
    }

    func restoreTabViewport(_ viewport: TabViewport) {
        pendingTabViewport = viewport
        restoreTabViewportIfVisible()
    }

    func discardPendingTabViewport() {
        pendingTabViewport = nil
    }

    private func restoreTabViewportIfVisible() {
        guard let viewport = pendingTabViewport, let document, window != nil,
              !isHiddenOrHasHiddenAncestor, !bounds.isEmpty else { return }
        pendingTabViewport = nil
        pendingReadingPosition = nil
        if autoScales != viewport.autoScales { autoScales = viewport.autoScales }
        if !viewport.autoScales && scaleFactor != viewport.scale { scaleFactor = viewport.scale }
        layoutSubtreeIfNeeded()
        if ObjectIdentifier(document) == viewport.documentID,
           abs(scaleFactor - viewport.scale) < 0.0001,
           let scrollView = documentView?.enclosingScrollView,
           scrollView.contentView.bounds.size == viewport.clipBounds.size {
            let clip = scrollView.contentView
            clip.scroll(to: clip.constrainBoundsRect(viewport.clipBounds).origin)
            scrollView.reflectScrolledClipView(clip)
        } else {
            var position = viewport.position
            // On relaunch the window may have a different size. Keep the reading anchor at the same relative spot.
            if viewport.documentID == nil, viewport.clipBounds.width > 0, viewport.clipBounds.height > 0,
               let clip = documentView?.enclosingScrollView?.contentView {
                let offset = position.offsetInViewport
                position.offsetInViewport = CGPoint(x: offset.x / viewport.clipBounds.width * clip.bounds.width,
                                                    y: offset.y / viewport.clipBounds.height * clip.bounds.height)
            }
            pendingReadingPosition = position
            restoreReadingPositionIfVisible()
        }
    }

    private func captureReadingPosition(matchText: Bool = true) -> ReadingPosition? {
        guard let document, let page = currentPage, let clip = documentView?.enclosingScrollView?.contentView,
              !clip.bounds.isEmpty else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex < document.pageCount else { return nil }
        let viewport = clip.bounds
        let center = convert(CGPoint(x: viewport.midX, y: viewport.midY), from: clip)
        let pagePoint = clampToPage(convert(center, to: page), page: page)
        let reference = clip.convert(convert(pagePoint, from: page), from: self)
        let offset = CGPoint(x: reference.x - viewport.minX, y: reference.y - viewport.minY)

        guard matchText else {
            return ReadingPosition(pageIndex: pageIndex, pagePoint: pagePoint, offsetInViewport: offset,
                                   line: nil, lineMidY: pagePoint.y)
        }

        let pageBounds = page.bounds(for: displayBox)
        let stripe = CGRect(x: pageBounds.minX, y: pagePoint.y - 6, width: pageBounds.width, height: 12)
        let selection = page.selectionForLine(at: pagePoint) ?? page.selection(for: stripe)?.selectionsByLine().min {
            abs($0.bounds(for: page).midY - pagePoint.y) < abs($1.bounds(for: page).midY - pagePoint.y)
        }
        let text = selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = text.flatMap { (24...240).contains($0.utf16.count) ? $0 : nil }
        let lineMidY = selection?.bounds(for: page).midY ?? pagePoint.y
        return ReadingPosition(pageIndex: pageIndex, pagePoint: pagePoint, offsetInViewport: offset,
                               line: line, lineMidY: lineMidY)
    }

    private func restoreReadingPositionIfVisible() {
        guard pendingTabViewport == nil, let position = pendingReadingPosition, let document, document.pageCount > 0,
              window != nil, !isHiddenOrHasHiddenAncestor, !bounds.isEmpty else { return }
        pendingReadingPosition = nil
        let pageIndex = min(position.pageIndex, document.pageCount - 1)
        guard var page = document.page(at: pageIndex) else { return }
        var point = position.pagePoint
        if let line = position.line {
            // A small edit may push the reading line onto an adjacent page.
            for index in [pageIndex, pageIndex - 1, pageIndex + 1] where (0..<document.pageCount).contains(index) {
                guard let candidate = document.page(at: index),
                      let lineY = nearestLineY(matching: line, to: position.lineMidY, on: candidate) else { continue }
                point.y += lineY - position.lineMidY
                page = candidate
                break
            }
        }
        point = clampToPage(point, page: page)
        go(to: page)
        layoutSubtreeIfNeeded()
        guard let scrollView = documentView?.enclosingScrollView else { return }
        let clip = scrollView.contentView
        let target = clip.convert(convert(point, from: page), from: self)
        var viewport = clip.bounds
        viewport.origin = CGPoint(x: target.x - position.offsetInViewport.x, y: target.y - position.offsetInViewport.y)
        clip.scroll(to: clip.constrainBoundsRect(viewport).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func nearestLineY(matching line: String, to previousY: CGFloat, on page: PDFPage) -> CGFloat? {
        guard let text = page.string as NSString? else { return nil }
        var nearest: CGFloat?
        var remaining = NSRange(location: 0, length: text.length)
        while remaining.length > 0 {
            let match = text.range(of: line, range: remaining)
            guard match.location != NSNotFound else { break }
            if let selection = page.selection(for: match) {
                let bounds = selection.bounds(for: page)
                if !bounds.isEmpty, nearest.map({ abs(bounds.midY - previousY) < abs($0 - previousY) }) ?? true {
                    nearest = bounds.midY
                }
            }
            let next = NSMaxRange(match)
            remaining = NSRange(location: next, length: text.length - next)
        }
        return nearest
    }

    private func clampToPage(_ point: CGPoint, page: PDFPage) -> CGPoint {
        let bounds = page.bounds(for: displayBox)
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                       y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private func localPoint(for event: NSEvent) -> NSPoint? {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor, document != nil else { return nil }
        let windowPoint: NSPoint
        if let eventWindow = event.window {
            guard window === eventWindow else { return nil }
            windowPoint = event.locationInWindow
        } else {
            let location = event.locationInWindow
            guard NSWindow.windowNumber(at: location, belowWindowWithWindowNumber: 0) == window.windowNumber else {
                return nil
            }
            windowPoint = window.convertPoint(fromScreen: location)
        }
        let point = convert(windowPoint, from: nil)
        return bounds.contains(point) && visibleRect.contains(point) ? point : nil
    }

    private func handleSourceJump(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let isDoubleClick = event.clickCount == 2 && modifiers.isEmpty
        guard isDoubleClick || modifiers.contains(.command), let onSourceJump,
              let document, let point = localPoint(for: event), let content = window?.contentView else {
            return false
        }
        let windowPoint = convert(point, to: nil)
        let hitPoint = content.superview?.convert(windowPoint, from: nil) ?? windowPoint
        guard let hit = content.hitTest(hitPoint), hit === self || hit.isDescendant(of: self),
              let page = page(for: point, nearest: false) else {
            return false
        }
        let pageIndex = document.index(for: page)
        guard pageIndex < document.pageCount else { return false }
        let mediaBox = page.pageRef?.getBoxRect(.mediaBox) ?? page.bounds(for: .mediaBox)
        let pagePoint = convert(point, to: page)
        let syncPoint = CGPoint(x: pagePoint.x - mediaBox.minX, y: mediaBox.maxY - pagePoint.y)
        return onSourceJump(pageIndex, syncPoint)
    }

    func revealSourceLocation(pageIndex: Int, rect: CGRect, highlightLine: Bool = true) -> Bool {
        guard let document, (0..<document.pageCount).contains(pageIndex),
              let page = document.page(at: pageIndex) else { return false }
        let mediaBox = page.pageRef?.getBoxRect(.mediaBox) ?? page.bounds(for: .mediaBox)
        let pageRect = CGRect(x: mediaBox.minX + rect.minX, y: mediaBox.maxY - rect.maxY,
                              width: rect.width, height: rect.height)
        let displayBounds = page.bounds(for: displayBox)
        let destination = pageRect.insetBy(dx: -4, dy: -8).intersection(displayBounds)
        pendingTabViewport = nil
        pendingReadingPosition = nil
        clearSourceHighlight()
        guard !destination.isEmpty else {
            go(to: page)
            return true
        }
        if highlightLine || !visibleRect.intersects(convert(pageRect, from: page)) {
            go(to: destination, on: page)
        }
        if highlightLine { showSourceHighlight(on: page, near: pageRect) }
        return true
    }

    private func showSourceHighlight(on page: PDFPage, near location: CGRect) {
        guard let container = superview else { return }
        let bounds = sourceLineBounds(on: page, near: location).intersection(page.bounds(for: displayBox))
        guard !bounds.isEmpty else { return }

        // Paint above the PDF viewport so the preview's dark filter leaves the marker legible.
        let marker = PDFSourceLineHighlightView(frame: .zero)
        marker.usesDarkAppearance = usesDarkAppearance
        marker.setAccessibilityIdentifier("PDFSourceLineHighlight")
        sourceHighlight = (page, bounds, marker)
        container.addSubview(marker, positioned: .above, relativeTo: self)
        let center = NotificationCenter.default
        if let clip = documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(updateSourceHighlightFrame(_:)),
                               name: NSView.boundsDidChangeNotification, object: clip)
        }
        center.addObserver(self, selector: #selector(updateSourceHighlightFrame(_:)),
                           name: .PDFViewScaleChanged, object: self)
        updateSourceHighlightFrame()
        clearHighlightTask = Task { [weak self, weak marker] in
            try? await Task.sleep(for: .milliseconds(2700))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                marker?.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            self?.clearSourceHighlight()
        }
    }

    private func sourceLineBounds(on page: PDFPage, near location: CGRect) -> CGRect {
        let point = CGPoint(x: location.midX, y: location.midY)
        if let bounds = page.selectionForLine(at: point)?.bounds(for: page), !bounds.isEmpty {
            return bounds
        }

        // SyncTeX often points to the end of a word, just outside the selectable glyphs.
        let probe = page.selection(for: location.insetBy(dx: -8, dy: -2))
        let closest = probe?.selectionsByLine().map { $0.bounds(for: page) }.filter { !$0.isEmpty }.min {
            abs($0.midY - point.y) < abs($1.midY - point.y)
        }
        guard let closest else { return location }
        let inside = CGPoint(x: closest.midX, y: closest.midY)
        if let bounds = page.selectionForLine(at: inside)?.bounds(for: page), !bounds.isEmpty {
            return bounds
        }
        return closest
    }

    @objc private func updateSourceHighlightFrame(_ notification: Notification? = nil) {
        guard let sourceHighlight, let container = sourceHighlight.view.superview else { return }
        let row = convert(sourceHighlight.bounds, from: sourceHighlight.page)
        let band = row.insetBy(dx: -min(4, row.height * 0.32), dy: -min(1.25, row.height * 0.1))
        let gap = min(6, row.height * 0.6)
        let marker = CGRect(x: band.minX - gap, y: band.minY, width: min(2.5, gap * 0.55), height: band.height)
        let rect = band.union(marker).intersection(visibleRect)
        let view = sourceHighlight.view
        view.isHidden = rect.isEmpty || isHiddenOrHasHiddenAncestor
        guard !rect.isEmpty else { return }
        view.frame = container.convert(rect, from: self)
        view.update(band: view.convert(band, from: self), marker: view.convert(marker, from: self))
    }

    func clearSourceHighlight() {
        clearHighlightTask?.cancel()
        clearHighlightTask = nil
        guard let sourceHighlight else { return }
        self.sourceHighlight = nil
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        center.removeObserver(self, name: .PDFViewScaleChanged, object: self)
        sourceHighlight.view.removeFromSuperview()
    }

    private func handleWheelZoom(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.control) else { return false }
        let delta = event.scrollingDeltaY
        guard delta != 0, abs(delta) >= abs(event.scrollingDeltaX),
              let point = localPoint(for: event) else { return false }
        guard event.momentumPhase.isEmpty else { return true }

        let units = delta / (event.hasPreciseScrollingDeltas ? 24 : 1)
        let multiplier = pow(1.14, min(4, max(-4, units)))
        let next = min(maxScaleFactor, max(minScaleFactor, scaleFactor * multiplier))
        if next != scaleFactor { zoom(to: next, around: point) }
        return true
    }

    private func zoom(to scale: CGFloat, around point: NSPoint) {
        let anchorPage = page(for: point, nearest: true)
        let anchor = anchorPage.map { convert(point, to: $0) }

        autoScales = false
        scaleFactor = scale
        layoutSubtreeIfNeeded()

        guard let anchorPage, let anchor,
              let scrollView = documentView?.enclosingScrollView else { return }
        let clip = scrollView.contentView
        let anchorAfterZoom = clip.convert(convert(anchor, from: anchorPage), from: self)
        let pointer = clip.convert(point, from: self)
        var bounds = clip.bounds
        bounds.origin.x += anchorAfterZoom.x - pointer.x
        bounds.origin.y += anchorAfterZoom.y - pointer.y
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
    }
}

private final class PDFSourceLineHighlightView: NSView {
    private var band = CGRect.zero
    private var marker = CGRect.zero
    var usesDarkAppearance = false {
        didSet { needsDisplay = true }
    }

    func update(band: CGRect, marker: CGRect) {
        self.band = band
        self.marker = marker
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let colors = usesDarkAppearance ? AppPalette.pdfDarkHighlight : AppPalette.pdfLightHighlight
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        colors.fill.setFill()
        NSBezierPath(roundedRect: band, xRadius: 2, yRadius: 2).fill()
        colors.accent.setFill()
        let radius = marker.width / 2
        NSBezierPath(roundedRect: marker, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
