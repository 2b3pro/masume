import SwiftUI
import AppKit
import CoreGraphics
import AnnotationModel
import AnnotationRender

// MARK: - SwiftUI bridge

struct CanvasView: NSViewRepresentable {
    var controller: CanvasController

    func makeNSView(context: Context) -> CanvasNSView {
        let view = CanvasNSView()
        view.controller = controller
        return view
    }

    func updateNSView(_ view: CanvasNSView, context: Context) {
        view.controller = controller
        view.refresh()
    }
}

// MARK: - AppKit canvas

final class CanvasNSView: NSView {
    weak var controller: CanvasController? {
        didSet {
            guard controller !== oldValue else { return }
            startObserving()
        }
    }

    enum Drag {
        case none
        case moving(ElementID, last: CGPoint)
        /// Option was held on the mouse-down over an element: the first
        /// movement duplicates it and the drag moves the copy (`moving`).
        /// A plain Option-click leaves the document alone.
        case cloning(ElementID, last: CGPoint)
        case handle(ElementID, HandleRole)
        case creating(ElementID, HandleRole)
        case cropping(anchor: CGPoint)
        case movingCrop(last: CGPoint)
        /// Pen straight line: the end point follows the pointer until mouse-up.
        case lining(ElementID, anchor: CGPoint)
        /// Callout creation: the tail tip is fixed at the mouse-down point and
        /// the bubble's center follows the pointer; mouse-up opens the editor.
        case placingCallout(ElementID)
        /// Dragging the zoom slider under a selected loupe; `track` is the
        /// slider's rect in view points.
        case magnifierZoom(track: CGRect)
        /// Spacebar hand tool: drags the zoomed image; `last` is in view points.
        case panning(last: CGPoint)
    }
    var drag: Drag = .none
    /// True while the spacebar is held: the next mouse-down pans instead of
    /// annotating (Photoshop's hand tool). Releasing space mid-drag keeps the
    /// pan going until mouse-up.
    private var isSpaceHeld = false
    /// Hand cursors pushed for the space gesture, so they can be popped in
    /// exact balance even if focus is lost mid-gesture.
    private var pushedHandCursors = 0
    /// First point of a pending pen straight line (model space), set by a
    /// Shift-click with the pen tool and consumed by the next Shift-click.
    /// Any other click abandons it.
    var penLineAnchor: CGPoint?
    /// Display mapping frozen for the duration of a drag. With expandToFit,
    /// dragging past the image edge grows the canvas, which would shift the
    /// mouse mapping mid-drag and feed the growth back on itself (runaway
    /// resize). Frozen, the drag stays 1:1 with the cursor; the view re-fits
    /// on mouseUp.
    private var dragDisplayInfo: DisplayInfo?
    /// Displacement of the image center from the viewport center, in view
    /// points. Only meaningful when the zoomed image overflows the viewport;
    /// re-clamped by `reconcileZoom()` whenever scale or bounds change.
    private var panOffset: CGVector = .zero
    /// Mapping computed by `reconcileZoom()` in `viewWillDraw()` and consumed
    /// by `draw(_:)` so draw needn't evaluate `displayInfo` (a Document copy
    /// plus an O(n) canvas-rect scan) a second time.
    private var reconciledInfo: DisplayInfo?
    private var flattened: CGImage?
    // Cache key for `flattened`: re-render only when the content it shows
    // (document sans crop + base image) actually changes, not on every redraw.
    private var flattenedKey: Document?
    private var flattenedBase: CGImage?
    private var flattenedBounds: ExportBounds?
    // Controller's documentVersion at the last cache check; lets draw() skip
    // the Document copy + equality entirely on redraws with no model change
    // (e.g. the 12Hz marching-ants ticks).
    private var flattenedVersion: Int = -1
    var textEditor: NSTextView?
    var editingTextID: ElementID?
    private var antsTimer: Timer?
    private var antsPhase: CGFloat = 0

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Selector-based observers are auto-unregistered on dealloc.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Pause the marching-ants timer while the app is inactive; the crop
    // outline freezes but stops burning CPU in the background.
    @objc private func appDidResignActive() {
        antsTimer?.invalidate()
        antsTimer = nil
        endSpaceGesture()
    }

    override func resignFirstResponder() -> Bool {
        endSpaceGesture()
        return super.resignFirstResponder()
    }

    private func pushHandCursor(_ cursor: NSCursor) {
        cursor.push()
        pushedHandCursors += 1
    }

    /// Drops the space flag and any hand cursors; a pan in progress finishes
    /// on its own mouse-up.
    private func endSpaceGesture() {
        isSpaceHeld = false
        while pushedHandCursors > 0 {
            NSCursor.pop()
            pushedHandCursors -= 1
        }
    }

    @objc private func appDidBecomeActive() {
        needsDisplay = true // draw() restarts the timer via updateAntsTimer
    }

    func refresh() {
        needsDisplay = true
    }

    private func startObserving() {
        guard let controller else { return }
        withObservationTracking {
            _ = controller.document
            _ = controller.baseImage
            _ = controller.selection
            _ = controller.exportBounds
            _ = controller.showsGrid
            // effectiveZoomScale is deliberately NOT tracked: this view writes
            // it, so reading it here would loop redraws.
            _ = controller.zoomMode
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.startObserving()
            }
        }
    }

    // MARK: Coordinate mapping

    struct DisplayInfo {
        let canvas: CGRect
        let scale: CGFloat
        let rect: CGRect

        func modelToView(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + (p.x - canvas.origin.x) * scale,
                    y: rect.minY + (canvas.height - (p.y - canvas.origin.y)) * scale)
        }

        func viewToModel(_ p: CGPoint) -> CGPoint {
            guard scale > 0 else { return .zero }
            return CGPoint(x: canvas.origin.x + (p.x - rect.minX) / scale,
                           y: canvas.origin.y + canvas.height - (p.y - rect.minY) / scale)
        }

        var modelTolerance: CGFloat { 8 / max(scale, 0.0001) }

        func viewRect(forModelRect box: CGRect) -> CGRect {
            CGRect(corner: modelToView(CGPoint(x: box.minX, y: box.minY)),
                   modelToView(CGPoint(x: box.maxX, y: box.maxY)))
        }
    }

    private var displayDocument: Document? {
        guard var doc = controller?.document else { return nil }
        doc.crop = nil
        return doc
    }

    var displayInfo: DisplayInfo {
        let canvas: CGRect
        if let controller, let doc = displayDocument {
            canvas = doc.outputRect(for: controller.exportBounds)
        } else {
            canvas = CGRect(origin: .zero, size: .zero)
        }
        guard canvas.width > 0, canvas.height > 0 else {
            return DisplayInfo(canvas: canvas, scale: 1, rect: .zero)
        }
        let scale: CGFloat
        switch controller?.zoomMode ?? .fit {
        case .fit:
            scale = ZoomMath.fittedScale(canvas: canvas.size, viewport: bounds.size)
        case .percent(let percent):
            scale = percent
        }
        // imageRect clamps the pan defensively; the stored panOffset itself is
        // re-clamped in reconcileZoom() (a computed property must stay pure).
        let rect = ZoomMath.imageRect(canvas: canvas.size, viewport: bounds.size,
                                      scale: scale, pan: panOffset)
        return DisplayInfo(canvas: canvas, scale: scale, rect: rect)
    }

    private var displayScale: CGFloat { displayInfo.scale }
    private var displayRect: CGRect { displayInfo.rect }

    private func modelToView(_ p: CGPoint) -> CGPoint { displayInfo.modelToView(p) }
    private func viewToModel(_ p: CGPoint) -> CGPoint { displayInfo.viewToModel(p) }
    private var modelTolerance: CGFloat { displayInfo.modelTolerance }
    private func viewRect(forModelRect box: CGRect) -> CGRect { displayInfo.viewRect(forModelRect: box) }

    // MARK: Drawing

    /// Brings the stored pan state in line with the current zoom mode and
    /// bounds — the one funnel that sees both zoom changes (via observation-
    /// triggered redraws) and window resizes. Runs from viewWillDraw, which
    /// unlike draw may freely mutate view and controller state.
    private func reconcileZoom() {
        guard let controller else { reconciledInfo = nil; return }
        // Mid-drag the mapping is frozen (draw uses dragDisplayInfo) and pan/
        // zoom input is blocked, so there is nothing to reconcile.
        guard dragDisplayInfo == nil else { return }
        if case .fit = controller.zoomMode {
            panOffset = .zero
        }
        var info = displayInfo
        // effectiveZoomScale doubles as the last-applied scale: it is written
        // exactly when the drawn scale changes (here and in magnify).
        let old = controller.effectiveZoomScale
        if old != info.scale {
            if case .percent = controller.zoomMode {
                panOffset = ZoomMath.panPreservingCenter(oldPan: panOffset,
                                                         oldScale: old, newScale: info.scale)
                // The rect above was built from the pre-adjustment pan; rebuild
                // it (cheap arithmetic, the canvas rect is unchanged).
                info = DisplayInfo(canvas: info.canvas, scale: info.scale,
                                   rect: ZoomMath.imageRect(canvas: info.canvas.size,
                                                            viewport: bounds.size,
                                                            scale: info.scale, pan: panOffset))
            }
            // The inline editor's font has the old scale baked in; commit it,
            // matching what a mouseDown does.
            if textEditor != nil { commitTextEditing() }
            controller.reportEffectiveZoomScale(info.scale)
        }
        panOffset = ZoomMath.clampedPan(panOffset, content: info.rect.size, viewport: bounds.size)
        reconciledInfo = info
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        reconcileZoom()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let controller, let doc = controller.document else { return }
        let exportBounds = controller.exportBounds
        let version = controller.documentVersion
        if flattened == nil || flattenedVersion != version
            || flattenedBase !== controller.baseImage || flattenedBounds != exportBounds {
            var displayDoc = doc
            displayDoc.crop = nil
            // Crop-rect drags bump the version but don't change flattened
            // content; the equality keeps them from re-flattening.
            if flattened == nil || flattenedKey != displayDoc
                || flattenedBase !== controller.baseImage || flattenedBounds != exportBounds {
                flattened = Renderer.flatten(displayDoc, baseImage: controller.baseImage, scale: 1,
                                            bounds: exportBounds, assets: controller.project?.assetImages ?? [:])
                flattenedKey = displayDoc
                flattenedBase = controller.baseImage
                flattenedBounds = exportBounds
            }
            flattenedVersion = version
        }
        let info = dragDisplayInfo ?? reconciledInfo ?? displayInfo
        // Model rect the cached image covers (`flattenedKey` is the document it
        // was rendered from), mapped through `info`: with a frozen transform,
        // grown content draws outside the fitted rect instead of being squeezed
        // into it. Equals info.rect when info is live.
        let imageRect = flattenedKey.map { info.viewRect(forModelRect: $0.outputRect(for: exportBounds)) }
            ?? info.rect
        if let img = flattened {
            ctx.interpolationQuality = .high
            ctx.draw(img, in: imageRect)
        }

        // Crop dimming + outline.
        if let crop = doc.crop {
            drawCropOverlay(crop, info: info, imageRect: imageRect, in: ctx)
        }
        updateAntsTimer(cropVisible: doc.crop != nil)

        // The address grid: chrome over the image, under the selection.
        if controller.showsGrid {
            drawGrid(doc, info: info, in: ctx)
        }

        // Selection handles.
        if let sel = controller.selection, let element = doc.elements.first(where: { $0.id == sel }) {
            drawSelection(element, info: info, in: ctx)
        }

        // Pending pen straight-line anchor: a dot in the stroke's own look.
        if controller.tool == .pen, let anchor = penLineAnchor {
            let center = info.modelToView(anchor)
            let d = max(4, controller.strokeWidth * info.scale)
            let dot = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
            ctx.setFillColor(nsColor(controller.strokeColor).withAlphaComponent(controller.penOpacity).cgColor)
            ctx.fillEllipse(in: dot)
            ctx.setStrokeColor(NSColor.miroBlue.cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: dot.insetBy(dx: -2, dy: -2))
        }
    }

    private func drawCropOverlay(_ crop: CGRect, info: DisplayInfo, imageRect: CGRect, in ctx: CGContext) {
        let viewCrop = info.viewRect(forModelRect: crop)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fill(imageRect)
        ctx.clear(viewCrop)
        if let img = flattened {
            ctx.saveGState()
            ctx.clip(to: viewCrop)
            ctx.draw(img, in: imageRect)
            ctx.restoreGState()
        }
        // Marching ants (phase advanced by `antsTimer`); dark underlay keeps
        // the white dashes visible over light image regions.
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(viewCrop)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineDash(phase: antsPhase, lengths: [5, 4])
        ctx.stroke(viewCrop)
        ctx.setLineDash(phase: 0, lengths: [])

        // Corner handles so the crop rect is re-editable with the crop tool.
        for handle in viewCrop.cornerHandles() {
            drawHandle(at: handle.position,
                       stroke: NSColor.miroBlue, lineWidth: 1, in: ctx)
        }
    }

    private func updateAntsTimer(cropVisible: Bool) {
        if cropVisible, antsTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.antsPhase += 1
                    // Only the crop outline animates; keep the invalidated
                    // region there (-8 covers the 9pt corner handles).
                    if let crop = self.controller?.document?.crop {
                        let info = self.dragDisplayInfo ?? self.displayInfo
                        self.setNeedsDisplay(info.viewRect(forModelRect: crop)
                            .insetBy(dx: -8, dy: -8))
                    } else {
                        self.needsDisplay = true
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            antsTimer = timer
        } else if !cropVisible, let timer = antsTimer {
            timer.invalidate()
            antsTimer = nil
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            antsTimer?.invalidate()
            antsTimer = nil
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        commitTextEditing()
        guard let controller, controller.document != nil else { return }
        let info = displayInfo
        let viewPoint = convert(event.locationInWindow, from: nil)
        if isSpaceHeld {
            commitTextEditing()
            drag = .panning(last: viewPoint)
            pushHandCursor(.closedHand)
            return
        }
        // Floating controls of the selection (text style button, loupe zoom
        // slider) take the click before any canvas interaction starts.
        if handleOverlayControlMouseDown(at: viewPoint, info: info) { return }
        let p = info.viewToModel(viewPoint)
        controller.beginInteraction()

        // Double-click a text element (in any tool) to edit it.
        if event.clickCount == 2,
           let id = controller.document?.hitTest(p, tolerance: info.modelTolerance),
           case .text = controller.document?.elements.first(where: { $0.id == id }) {
            controller.selection = id
            drag = .none
            beginTextEditing(for: id)
            return
        }

        if controller.tool == .pen, event.modifierFlags.contains(.shift) {
            handlePenLineClick(at: p)
        } else {
            penLineAnchor = nil
            switch controller.tool {
            case .select:
                handlePointerMouseDown(at: p, creationTool: nil, info: info, event: event)
            case .crop:
                handleCropMouseDown(at: p, viewPoint: viewPoint, info: info)
            default:
                handlePointerMouseDown(at: p, creationTool: controller.tool, info: info, event: event)
            }
        }
        // Only actual drags freeze the mapping; click paths (text creation,
        // double-click edit) must keep using the live one.
        switch drag {
        case .none: break
        default: dragDisplayInfo = info
        }
        refresh()
    }

    /// Shared pointer handling for `select` and creation tools. A handle on the
    /// current selection resizes; a body hit selects and moves, or with Option
    /// held duplicates and moves the copy. On empty space `select` clears the
    /// selection, while a creation tool creates a new element. The active tool
    /// is never changed.
    private func handlePointerMouseDown(at p: CGPoint, creationTool: Tool?, info: DisplayInfo, event: NSEvent) {
        guard let controller, let doc = controller.document else { return }
        switch doc.resolvePointer(at: p, selection: controller.selection,
                                  bodyTolerance: info.modelTolerance, handleTolerance: info.modelTolerance) {
        case .handle(let id, let role):
            drag = .handle(id, role)
        case .body(let id):
            controller.selection = id
            drag = event.modifierFlags.contains(.option) ? .cloning(id, last: p) : .moving(id, last: p)
        case .empty:
            guard let tool = creationTool else {
                controller.selection = nil
                drag = .none
                return
            }
            switch tool {
            case .text: createText(at: p)
            case .callout: createCallout(at: p)
            default: createElement(tool: tool, at: p)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            return
        case .magnifierZoom(let track):
            controller.magnifierZoom = Self.magnifierZoom(forX: viewPoint.x, in: track)
        case .panning(let last):
            pan(by: CGVector(dx: viewPoint.x - last.x, dy: viewPoint.y - last.y))
            drag = .panning(last: viewPoint)
        default:
            // Model-space drags use the mapping frozen at mouse-down.
            let info = dragDisplayInfo ?? displayInfo
            dragModel(to: info.viewToModel(viewPoint), controller: controller,
                      snapping: event.modifierFlags.contains(.shift))
        }
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        dragDisplayInfo = nil
        guard let controller else { return }
        let finished = drag
        finishDrag(finished, controller: controller)
        if case .panning = finished, pushedHandCursors > 0 {
            NSCursor.pop()
            pushedHandCursors -= 1
        }
        drag = .none
        controller.commitInteraction()
        refresh()
        // Placement follow-ups run after the commit: a bubble's typing is a
        // separate undo step, like text created by a click, and an unlocked
        // one-shot tool hands back to Select. Text and callouts count as
        // placed when their editing ends (see commitTextEditing).
        switch finished {
        case .placingCallout(let id): beginTextEditing(for: id)
        case .creating, .lining: controller.didPlaceAnnotation()
        default: break
        }
    }

    // MARK: Pan

    /// Zoom factor per unit of Cmd+scroll: a mouse-wheel notch (delta ±1)
    /// is about 10%; precise trackpad deltas are larger, so they get a
    /// gentler exponent.
    private static func zoomFactor(forScroll event: NSEvent) -> CGFloat {
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 0.005 : 0.1
        return exp(event.scrollingDeltaY * k)
    }

    override func scrollWheel(with event: NSEvent) {
        // Cmd+scroll zooms about the pointer, in fit mode too.
        if event.modifierFlags.contains(.command) {
            guard let controller, controller.hasDocument, case .none = drag else { return }
            zoom(by: Self.zoomFactor(forScroll: event), anchoredAt: convert(event.locationInWindow, from: nil))
            return
        }
        // Fit mode never overflows the viewport; bail before paying for
        // displayInfo (a Document copy + O(n) scan) on every scroll tick.
        guard let controller, controller.hasDocument,
              case .percent = controller.zoomMode,
              case .none = drag else {  // never pan mid-annotation-drag
            super.scrollWheel(with: event)
            return
        }
        // Non-flipped view: scrolling "down" moves the content up.
        if !pan(by: CGVector(dx: event.scrollingDeltaX, dy: -event.scrollingDeltaY)) {
            super.scrollWheel(with: event)  // fits entirely: stay centered
        }
    }

    /// Moves the zoomed image by `delta` view points, clamped so it never
    /// leaves the viewport. Returns false when the image fits entirely (or
    /// zoom is fit mode), in which case nothing moves.
    @discardableResult
    private func pan(by delta: CGVector) -> Bool {
        guard let controller, case .percent = controller.zoomMode else { return false }
        let info = displayInfo
        let content = info.rect.size
        guard content.width > bounds.width || content.height > bounds.height else { return false }
        var pan = panOffset
        pan.dx += delta.dx
        pan.dy += delta.dy
        panOffset = ZoomMath.clampedPan(pan, content: content, viewport: bounds.size)
        syncTextEditorFrame()
        needsDisplay = true
        return true
    }

    /// Pinch zoom, anchored at the cursor. Continuous scale — the label shows
    /// the live percentage and ⌘+/⌘- step to presets from wherever this lands.
    override func magnify(with event: NSEvent) {
        guard let controller, controller.hasDocument,
              case .none = drag else {  // never zoom mid-annotation-drag
            super.magnify(with: event)
            return
        }
        zoom(by: 1 + event.magnification, anchoredAt: convert(event.locationInWindow, from: nil))
    }

    /// Scales the zoom by `factor` (clamped) keeping the image point under
    /// `anchor` (view coordinates) fixed on screen. Shared by pinch and
    /// Cmd+scroll.
    private func zoom(by factor: CGFloat, anchoredAt anchor: CGPoint) {
        guard let controller else { return }
        let info = displayInfo
        let oldScale = info.scale
        let newScale = ZoomMath.clampedScale(oldScale * factor,
                                             canvas: info.canvas.size, viewport: bounds.size)
        guard newScale != oldScale else { return }
        if textEditor != nil { commitTextEditing() }  // editor font has the old scale baked in
        let pan = ZoomMath.panPreservingPoint(anchor, oldPan: panOffset,
                                              oldScale: oldScale, newScale: newScale,
                                              canvas: info.canvas.size, viewport: bounds.size)
        let content = ZoomMath.contentSize(canvas: info.canvas.size, scale: newScale)
        panOffset = ZoomMath.clampedPan(pan, content: content, viewport: bounds.size)
        controller.setZoom(newScale)
        // reconcileZoom() treats effectiveZoomScale as the last-applied scale;
        // reporting now keeps it from re-anchoring the just-anchored pan at
        // the view center.
        controller.reportEffectiveZoomScale(newScale)
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let controller else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 49: // space — hold for the hand tool
            guard !event.isARepeat, !isSpaceHeld else { return }
            isSpaceHeld = true
            pushHandCursor(.openHand)
        case 51, 117: // delete / forward-delete
            controller.deleteSelection()
            refresh()
        case 36, 76: // return / keypad enter — apply pending crop
            consume(controller.applyPendingCrop(), else: event)
        case 48: // tab — a selected flag switches between digits and letters
            consume(controller.toggleSelectedStampLettering(), else: event)
        case 53: // escape
            handleEscape(controller)
        default:
            consume(stepStamp(controller, event), else: event)
        }
    }

    /// Redraws when a key did something; otherwise lets the key travel on.
    private func consume(_ handled: Bool, else event: NSEvent) {
        if handled { refresh() } else { super.keyDown(with: event) }
    }

    /// Cancels a pending crop or line anchor, else clears the selection.
    private func handleEscape(_ controller: CanvasController) {
        if controller.document?.crop != nil {
            controller.cancelCrop()
        } else if penLineAnchor != nil {
            penLineAnchor = nil
        } else {
            controller.selection = nil
        }
        refresh()
    }

    /// A selected numbered stamp counts up and down from an unmodified
    /// `+` or `-`; true when the key was consumed.
    private func stepStamp(_ controller: CanvasController, _ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              let delta = Self.stampStep(for: event.charactersIgnoringModifiers) else { return false }
        return controller.stepSelectedStamp(by: delta)
    }

    /// `+` (or `=`, its unshifted key) counts up; `-` counts down.
    static func stampStep(for characters: String?) -> Int? {
        switch characters {
        case "+", "=": return 1
        case "-", "_": return -1
        default: return nil
        }
    }

    override func keyUp(with event: NSEvent) {
        guard event.keyCode == 49, isSpaceHeld else { return super.keyUp(with: event) }
        // Keep the closed hand for a pan still in progress; drop the rest.
        isSpaceHeld = false
        let keep: Int
        if case .panning = drag { keep = 1 } else { keep = 0 }
        while pushedHandCursors > keep {
            NSCursor.pop()
            pushedHandCursors -= 1
        }
    }
}

// MARK: - Inline text editing
