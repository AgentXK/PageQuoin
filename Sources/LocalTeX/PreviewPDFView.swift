import AppKit
import PDFKit

@MainActor
final class PreviewPDFView: PDFView {
    private var eventMonitor: Any?
    private var clearHighlightTask: Task<Void, Never>?
    var onSourceJump: ((Int, CGPoint) -> Bool)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        guard window != nil else { return }

        // The inner PDFKit views normally receive these events first.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            let handled = event.type == .scrollWheel ? handleWheelZoom(event) : handleSourceJump(event)
            return handled ? nil : event
        }
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        clearHighlightTask?.cancel()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            backgroundColor = AppPalette.preview.usingColorSpace(.sRGB) ?? AppPalette.preview
        }
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

    func revealSourceLocation(pageIndex: Int, rect: CGRect) -> Bool {
        guard let document, (0..<document.pageCount).contains(pageIndex),
              let page = document.page(at: pageIndex) else { return false }
        let mediaBox = page.pageRef?.getBoxRect(.mediaBox) ?? page.bounds(for: .mediaBox)
        let pageRect = CGRect(x: mediaBox.minX + rect.minX, y: mediaBox.maxY - rect.maxY,
                              width: rect.width, height: rect.height)
        let displayBounds = page.bounds(for: displayBox)
        let destination = pageRect.insetBy(dx: -4, dy: -8).intersection(displayBounds)
        clearSourceHighlight()
        guard !destination.isEmpty else {
            go(to: page)
            return true
        }
        go(to: destination, on: page)
        if let selection = page.selection(for: pageRect.insetBy(dx: -2, dy: -2)) {
            selection.color = AppPalette.pdfHighlight
            highlightedSelections = [selection]
            clearHighlightTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.highlightedSelections = nil
            }
        }
        return true
    }

    func clearSourceHighlight() {
        clearHighlightTask?.cancel()
        clearHighlightTask = nil
        highlightedSelections = nil
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
