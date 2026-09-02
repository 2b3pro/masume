import Foundation
import CoreGraphics
import AppKit
import AnnotationModel
import AnnotationRender

/// Holds the document, the loaded base image, the current tool/selection, and
/// a snapshot-based undo stack. The single source of truth for the UI.
@MainActor @Observable
final class CanvasController {
    var document: Document? {
        didSet { documentVersion &+= 1 }
    }
    /// Monotonic counter bumped on every write to `document`; a cheap
    /// change-detection key for the canvas's flatten cache. Bumps are
    /// conservative — equal-value writes also increment.
    @ObservationIgnored private(set) var documentVersion: Int = 0
    var baseImage: CGImage?
    var selection: ElementID? {
        didSet { syncToolStateFromSelection() }
    }
    var tool: Tool = .arrow {
        didSet {
            if !keepsSelectionOnToolChange { selection = nil }
            adoptStrokeWidthForTool()
            persistPreferences()
        }
    }
    /// Set around the automatic hand-back to Select after a placement so the
    /// just-placed element stays selected.
    @ObservationIgnored private var keepsSelectionOnToolChange = false
    /// One-shot tools locked to keep creating after each placement. Session
    /// only: every launch starts unlocked.
    private(set) var lockedTools: Set<Tool> = []

    func isLocked(_ tool: Tool) -> Bool { lockedTools.contains(tool) }

    /// Palette and shortcut entry point: picks the tool, or toggles its lock
    /// when it is already active and one-shot (OmniGraffle's double click).
    func selectTool(_ tool: Tool) {
        guard tool == self.tool, tool.isOneShot else {
            self.tool = tool
            return
        }
        if lockedTools.contains(tool) {
            lockedTools.remove(tool)
        } else {
            lockedTools.insert(tool)
        }
    }

    /// Called by the canvas once an annotation is placed (a shape on
    /// mouse-up, text when its editing ends). An unlocked one-shot tool hands
    /// back to Select so the next canvas click deselects instead of creating;
    /// the new element stays selected.
    func didPlaceAnnotation() {
        guard tool.isOneShot, !lockedTools.contains(tool) else { return }
        keepsSelectionOnToolChange = true
        tool = .select
        keepsSelectionOnToolChange = false
    }
    /// True while the inline text annotation editor is active; disables the
    /// unmodified single-letter tool shortcuts so they don't steal typing.
    var isEditingText = false
    var strokeColor: RGBAColor = .red {
        didSet {
            applyColorToSelection()
            persistPreferences()
        }
    }
    /// Opacity for new pen strokes (1 = pen, lower = highlighter); edits the
    /// selected pen stroke when one is selected (mirrors `strokeWidth`).
    var penOpacity: CGFloat = 1 {
        didSet {
            applyPenOpacityToSelection()
            persistPreferences()
        }
    }
    /// Treatment for new text elements; edits the selected text element when
    /// one is selected (mirrors `strokeColor`).
    var textStyle: TextStyle = .shadow {
        didSet {
            applyTextStyleToSelection()
            persistPreferences()
        }
    }
    /// Glyph for new stamps; edits the selected stamp when one is selected.
    var stampKind: StampKind = .check {
        didSet {
            applyStampKindToSelection()
            persistPreferences()
        }
    }

    /// Halo/outline color for new text (white or black); edits the selected
    /// text element when one is selected.
    var textOutlineColor: RGBAColor = .white {
        didSet {
            applyTextOutlineColorToSelection()
            persistPreferences()
        }
    }
    /// Line alignment for new text and callouts; edits the selected text
    /// element when one is selected.
    var textAlignment: LineAlignment = .left {
        didSet {
            applyTextAlignmentToSelection()
            persistPreferences()
        }
    }
    /// Bubble shape for new callouts; edits the selected callout when one is
    /// selected. Plain text is untouched (wrapping it is `setSelectedBubble`).
    var calloutShape: CalloutShape = .speech {
        didSet {
            applyCalloutShapeToSelection()
            persistPreferences()
        }
    }
    /// Outline for new loupes; edits the selected loupe when one is selected.
    var magnifierShape: MagnifierShape = .circle {
        didSet {
            applyMagnifierShapeToSelection()
            persistPreferences()
        }
    }
    /// Zoom for new loupes; edits the selected loupe when one is selected.
    /// Undo boundaries are the caller's job (the canvas slider wraps drags in
    /// begin/commitInteraction), like `strokeWidth`.
    var magnifierZoom: CGFloat = MagnifierElement.defaultZoom {
        didSet {
            applyMagnifierZoomToSelection()
            persistPreferences()
        }
    }
    var strokeWidth: CGFloat = DefaultStrokeWidth.segmentReferenceWidth {
        didSet {
            rememberStrokeWidth()
            applyStrokeWidthToSelection()
        }
    }
    /// Pixel block size for new pixelate elements; edits the selected pixelate
    /// element when one is selected (mirrors `strokeWidth`).
    var pixelateAmount: CGFloat = RedactionElement.defaultPixelateAmount {
        didSet {
            applyPixelateAmountToSelection()
            rememberPixelateAmount()
        }
    }
    /// Per-group stroke width memory: each tool family keeps its own width so
    /// thick arrows don't force thick shape outlines. `strokeWidth` mirrors
    /// the active group's value. These are the widths for the current canvas;
    /// `referenceWidths` holds the same memory relative to the reference
    /// canvas, which is what gets persisted and rescaled for the next image.
    private var groupWidths: [StrokeWidthGroup: CGFloat]
    private var referenceWidths: [StrokeWidthGroup: CGFloat]
    private var referencePixelateAmount: CGFloat
    @ObservationIgnored private let preferencesStore: ToolPreferencesStore

    init(preferencesStore: ToolPreferencesStore = UserDefaultsToolPreferencesStore()) {
        self.preferencesStore = preferencesStore
        let prefs = preferencesStore.load() ?? ToolPreferences()
        referenceWidths = prefs.referenceWidths
        referencePixelateAmount = prefs.referencePixelateAmount
        groupWidths = Self.scaledWidths(prefs.referenceWidths, forCanvasSize: DefaultSizeScale.referenceCanvasSize)
        tool = prefs.tool
        strokeColor = prefs.strokeColor
        penOpacity = prefs.penOpacity
        textStyle = prefs.textStyle
        textOutlineColor = prefs.textOutlineColor
        stampKind = prefs.stampKind
        textAlignment = prefs.textAlignment
        calloutShape = prefs.calloutShape
        magnifierShape = prefs.magnifierShape
        magnifierZoom = prefs.magnifierZoom
        pixelateAmount = prefs.referencePixelateAmount
        strokeWidth = groupWidths[prefs.tool.strokeWidthGroup ?? .segment] ?? DefaultStrokeWidth.segmentReferenceWidth
    }

    /// The reference widths scaled and clamped to the canvas; at the reference
    /// canvas size these are the reference widths themselves.
    private static func scaledWidths(_ references: [StrokeWidthGroup: CGFloat],
                                     forCanvasSize size: CGSize) -> [StrokeWidthGroup: CGFloat] {
        references.mapValues { DefaultStrokeWidth.width(reference: $0, forCanvasSize: size) }
    }

    /// Size factor of the current canvas relative to the reference canvas.
    private var canvasFactor: CGFloat {
        DefaultSizeScale.factor(forCanvasSize: document?.canvasSize ?? DefaultSizeScale.referenceCanvasSize)
    }

    /// Snapshot of the persisted tool state.
    var toolPreferences: ToolPreferences {
        var prefs = ToolPreferences()
        prefs.tool = tool
        prefs.strokeColor = strokeColor
        prefs.referenceWidths = referenceWidths
        prefs.referencePixelateAmount = referencePixelateAmount
        prefs.penOpacity = penOpacity
        prefs.textStyle = textStyle
        prefs.textOutlineColor = textOutlineColor
        prefs.stampKind = stampKind
        prefs.textAlignment = textAlignment
        prefs.calloutShape = calloutShape
        prefs.magnifierShape = magnifierShape
        prefs.magnifierZoom = magnifierZoom
        return prefs
    }

    private func persistPreferences() {
        preferencesStore.save(toolPreferences)
    }
    private static let exportBoundsKey = "exportBounds"
    var exportBounds: ExportBounds = UserDefaults.standard.rawRepresentable(
        forKey: CanvasController.exportBoundsKey, default: .expandToFit
    ) {
        didSet {
            UserDefaults.standard.set(exportBounds.rawValue, forKey: Self.exportBoundsKey)
        }
    }
    private(set) var sourceURL: URL?

    /// Transient view state — deliberately outside the undo stack.
    var zoomMode: ZoomMode = .fit
    /// Scale the canvas actually drew with last (fit mode included); written
    /// back by CanvasNSView so the zoom button can show a live percentage.
    private(set) var effectiveZoomScale: CGFloat = 1

    /// Transient toast text shown by ContentView; auto-cleared by flashToast.
    private(set) var toastMessage: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// Shows `message` in the bottom-center toast, restarting the dismiss
    /// timer if a toast is already visible.
    func flashToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            toastMessage = nil
        }
    }

    /// Undo unit: the document plus the base image (destructive crop swaps the
    /// image, so document snapshots alone can't restore it).
    private struct State {
        var document: Document
        var image: CGImage?
    }

    /// True while `syncToolStateFromSelection()` writes the tool state, so the
    /// setters' `didSet` apply hooks don't re-fire back into the document.
    @ObservationIgnored private var isSyncing = false

    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private var interactionSnapshot: State?
    @ObservationIgnored private var pendingCommitTask: Task<Void, Never>?

    var hasDocument: Bool { document != nil }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - Loading

    func loadImage(at url: URL) {
        if PDFPageSource.isPDF(url) {
            guard let source = PDFPageSource(url: url) else {
                NSSound.beep()
                return
            }
            loadPDF(source)
            return
        }
        guard let image = ImageLoader.cgImage(from: url) else {
            NSSound.beep()
            return
        }
        load(image: image, sourceURL: url)
    }

    // MARK: PDF import

    /// A multi-page PDF awaiting a page choice; the canvas pane shows the
    /// page picker while this is set.
    var pendingPDF: PDFPageSource?

    /// Imports a one-page PDF straight away; a longer one waits for a page.
    func loadPDF(_ source: PDFPageSource) {
        if source.pageCount == 1 {
            choosePDFPage(1, from: source)
        } else {
            pendingPDF = source
        }
    }

    /// Rasterizes `page` of `source` (or of the pending PDF) at the import
    /// scale and makes it the base image. Beeps and keeps the current
    /// document when the page cannot be rendered.
    func choosePDFPage(_ page: Int, from source: PDFPageSource? = nil) {
        guard let source = source ?? pendingPDF else { return }
        pendingPDF = nil
        guard let image = source.render(page: page) else {
            NSSound.beep()
            return
        }
        load(image: image, sourceURL: source.sourceURL)
    }

    func cancelPDFImport() {
        pendingPDF = nil
    }

    func loadImage(_ image: CGImage, sourceURL: URL? = nil) {
        load(image: image, sourceURL: sourceURL)
    }

    /// Loads the first readable image among dropped payloads; beeps if none.
    @discardableResult
    func loadDroppedImage(_ items: [DroppedImage]) -> Bool {
        for item in items {
            if let pdf = item.pdfSource {
                loadPDF(pdf)
                return true
            }
            guard let image = item.cgImage else { continue }
            load(image: image, sourceURL: item.sourceURL)
            return true
        }
        NSSound.beep()
        return false
    }

    private func load(image: CGImage, sourceURL: URL?) {
        let size = CGSize(width: image.width, height: image.height)
        let ref: ImageRef
        if let sourceURL { ref = .file(path: sourceURL.path) } else { ref = .pngData(Data()) }
        baseImage = image
        document = Document(baseImage: ref, canvasSize: size)
        self.sourceURL = sourceURL
        selection = nil
        groupWidths = Self.scaledWidths(referenceWidths, forCanvasSize: size)
        // Rescaling the remembered pixel size is not a user change: keep the
        // reference as is (dividing a clamped value back would drift it).
        isSyncing = true
        pixelateAmount = DefaultSizeScale.scaledDefault(reference: referencePixelateAmount,
                                                        clampedTo: RedactionElement.amountRange, forCanvasSize: size)
        isSyncing = false
        adoptStrokeWidthForTool()
        undoStack.removeAll()
        redoStack.removeAll()
        pendingCommitTask?.cancel()
        pendingCommitTask = nil
        interactionSnapshot = nil
        zoomMode = .fit
    }

    // MARK: - Zoom

    var zoomPercentText: String { ZoomMath.percentLabel(for: effectiveZoomScale) }

    func setZoom(_ scale: CGFloat) { zoomMode = .percent(scale) }
    func zoomToFit() { zoomMode = .fit }
    func zoomIn() { zoomMode = .percent(ZoomMath.zoomInScale(from: effectiveZoomScale)) }
    func zoomOut() { zoomMode = .percent(ZoomMath.zoomOutScale(from: effectiveZoomScale)) }

    func reportEffectiveZoomScale(_ scale: CGFloat) {
        guard scale != effectiveZoomScale else { return }
        effectiveZoomScale = scale
    }

    /// Loads an image from the pasteboard, if present. PDF data is imported
    /// through the page path (2×, page picker) rather than as a blurry
    /// first-page NSImage.
    @discardableResult
    func pasteImage(from pb: NSPasteboard = .general) -> Bool {
        if let data = pb.data(forType: .pdf), let source = PDFPageSource(data: data) {
            loadPDF(source)
            return true
        }
        if let objs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let nsImage = objs.first,
           let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            load(image: cg, sourceURL: nil)
            return true
        }
        return false
    }

    // MARK: - Undo

    /// Capture state at the start of an interaction (e.g. mouseDown).
    func beginInteraction() {
        flushPendingCommit()
        guard let document else { return }
        interactionSnapshot = State(document: document, image: baseImage)
    }

    /// Commit an interaction; pushes the pre-state if the document changed.
    func commitInteraction() {
        defer { interactionSnapshot = nil }
        guard let pre = interactionSnapshot, pre.document != document else { return }
        undoStack.append(pre)
        redoStack.removeAll()
    }

    /// One-shot mutation with undo registration.
    func perform(_ change: (inout Document) -> Void) {
        flushPendingCommit()
        guard var doc = document else { return }
        let pre = State(document: doc, image: baseImage)
        change(&doc)
        guard doc != pre.document else { return }
        undoStack.append(pre)
        redoStack.removeAll()
        document = doc
    }

    func undo() {
        flushPendingCommit()
        guard let pre = undoStack.popLast(), let current = document else { return }
        redoStack.append(State(document: current, image: baseImage))
        document = pre.document
        baseImage = pre.image
        clampSelection()
    }

    func redo() {
        flushPendingCommit()
        guard let next = redoStack.popLast(), let current = document else { return }
        undoStack.append(State(document: current, image: baseImage))
        document = next.document
        baseImage = next.image
        clampSelection()
    }

    private func clampSelection() {
        if let sel = selection, document?.index(of: sel) == nil { selection = nil }
        syncToolStateFromSelection()
    }

    // MARK: - Tool state ↔ selection

    /// Swaps in the new tool's remembered stroke width. Runs under `isSyncing`
    /// so switching tools neither edits a still-selected element nor writes
    /// the adopted value back into a group.
    private func adoptStrokeWidthForTool() {
        guard let group = tool.strokeWidthGroup,
              let width = groupWidths[group], width != strokeWidth else { return }
        isSyncing = true
        defer { isSyncing = false }
        strokeWidth = width
    }

    /// Remembers a user-driven slider change in the width group it targets:
    /// the selected element's group if there is a selection, else the current
    /// tool's. Skipped while syncing (the value came *from* a group or an
    /// element, not from the user).
    private func rememberStrokeWidth() {
        guard !isSyncing else { return }
        if let sel = selection, let doc = document, let i = doc.index(of: sel) {
            rememberWidth(strokeWidth, for: doc.elements[i].strokeWidthGroup ?? tool.strokeWidthGroup)
        } else {
            rememberWidth(strokeWidth, for: tool.strokeWidthGroup)
        }
    }

    /// The single write path into `groupWidths`; also records the width
    /// relative to the reference canvas and persists it.
    private func rememberWidth(_ width: CGFloat, for group: StrokeWidthGroup?) {
        guard let group else { return }
        groupWidths[group] = width
        referenceWidths[group] = width / canvasFactor
        persistPreferences()
    }

    /// Records a user-driven pixel size relative to the reference canvas.
    /// Skipped while syncing (the value came from an image load or a selected
    /// element, not the slider).
    private func rememberPixelateAmount() {
        guard !isSyncing else { return }
        referencePixelateAmount = pixelateAmount / canvasFactor
        persistPreferences()
    }

    /// True when the size slider edits the pixelate block size instead of the
    /// stroke width: the pixelate tool is active or a pixelate element is
    /// selected.
    var sliderEditsPixelateAmount: Bool {
        if tool == .pixelate { return true }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel) else { return false }
        return doc.elements[i].pixelateAmount != nil
    }

    /// True when the size slider edits a font size: the text or callout tool
    /// is active or a text element is selected. Lets the palette show a
    /// text-size icon instead of the stroke-weight one.
    var sliderEditsTextSize: Bool {
        if tool.strokeWidthGroup == .text { return true }
        return selectionIsText
    }

    /// True when the opacity control applies: the pen tool is active or a
    /// pen stroke is selected.
    var editsPenOpacity: Bool {
        if tool == .pen { return true }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel) else { return false }
        return doc.elements[i].opacity != nil
    }

    /// True when the text-style control applies: the text tool is active or a
    /// plain text element is selected. Halo and outline do not apply to
    /// callouts, whose bubble supplies the contrast.
    var editsTextStyle: Bool {
        if tool == .text { return true }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel) else { return false }
        return doc.elements[i].textStyle != nil && !doc.elements[i].isCallout
    }

    /// True when the alignment control applies: the text or callout tool is
    /// active or a text element (plain or callout) is selected.
    var editsTextAlignment: Bool {
        if tool == .text || tool == .callout { return true }
        return selectionIsText
    }

    /// True when the bubble-shape control applies: the callout tool is active
    /// or a callout is selected.
    var editsCalloutShape: Bool {
        if tool == .callout { return true }
        return selectedBubble != nil
    }

    /// True when the selection is a text element of either kind.
    var selectionIsText: Bool {
        guard let sel = selection, let doc = document, let i = doc.index(of: sel) else { return false }
        return doc.elements[i].textAlignment != nil
    }

    /// Bubble shape of the selected text element; nil for plain text or when
    /// nothing text-like is selected.
    var selectedBubble: CalloutShape? {
        guard let sel = selection, let doc = document, let i = doc.index(of: sel) else { return nil }
        return doc.elements[i].calloutShape
    }

    /// Wraps the selected text in a bubble, or unwraps it for nil, as one
    /// undo step. The box is re-measured for the changed padding.
    func setSelectedBubble(_ shape: CalloutShape?) {
        guard let sel = selection, let doc = document, let i = doc.index(of: sel),
              case .text(var t) = doc.elements[i], t.container?.shape != shape else { return }
        if let shape { t.makeCallout(shape) } else { t.removeCallout() }
        t.size = Renderer.suggestedSize(for: t)
        perform { $0.elements[i] = .text(t) }
        if let shape { calloutShape = shape }
    }

    /// True when the loupe-shape control applies: the magnifier tool is
    /// active or a loupe is selected.
    var editsMagnifierShape: Bool {
        if tool == .magnifier { return true }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel) else { return false }
        return doc.elements[i].magnifierShape != nil
    }

    /// The tool whose flyout (glyph, bubble, or loupe shape) is showing, if any.
    var flyoutTool: Tool? {
        if editsStampKind { return .stamp }
        if editsCalloutShape { return .callout }
        if editsMagnifierShape { return .magnifier }
        return nil
    }

    /// True when the stamp-kind control applies: the stamp tool is active or
    /// a stamp element is selected.
    var editsStampKind: Bool {
        if tool == .stamp { return true }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel) else { return false }
        return doc.elements[i].stampKind != nil
    }

    /// Adopts the selected element's stroke width and color so the controls
    /// start from the current values (and new elements of its group inherit
    /// them).
    private func syncToolStateFromSelection() {
        guard let sel = selection, let doc = document, let i = doc.index(of: sel) else { return }
        isSyncing = true
        defer { isSyncing = false }
        let element = doc.elements[i]
        if case .text(let t) = element {
            let width = FontSpec.strokeWidth(forPointSize: t.font.pointSize)
            if width != strokeWidth { strokeWidth = width }
        } else if let width = element.strokeWidth, width != strokeWidth {
            strokeWidth = width
        }
        rememberWidth(strokeWidth, for: element.strokeWidthGroup)
        if let color = element.color, color != strokeColor { strokeColor = color }
        if let amount = element.pixelateAmount, amount != pixelateAmount { pixelateAmount = amount }
        if let style = element.textStyle, style != textStyle { textStyle = style }
        if let kind = element.stampKind, kind != stampKind { stampKind = kind }
        if let opacity = element.opacity, opacity != penOpacity { penOpacity = opacity }
        if let outline = element.textOutlineColor, outline != textOutlineColor { textOutlineColor = outline }
        if let alignment = element.textAlignment, alignment != textAlignment { textAlignment = alignment }
        if let shape = element.calloutShape, shape != calloutShape { calloutShape = shape }
        if let shape = element.magnifierShape, shape != magnifierShape { magnifierShape = shape }
        if let zoom = element.magnifierZoom, zoom != magnifierZoom { magnifierZoom = zoom }
    }

    /// Shared `didSet` hook for the tool-state properties (stroke width /
    /// pixelate amount / color): writes `value` into the selected element
    /// through `keyPath`, returning whether a write happened. No-op while
    /// syncing (breaks the sync → apply feedback loop), without a selection,
    /// when the element lacks the property (`nil` current), or when the value
    /// is unchanged. `beforeWrite` runs after the guards pass and before the
    /// document write (the color path opens its undo snapshot there).
    @discardableResult
    private func applyToSelection<Value: Equatable>(_ keyPath: WritableKeyPath<Annotation, Value?>,
                                                    _ value: Value,
                                                    beforeWrite: () -> Void = {}) -> Bool {
        guard !isSyncing else { return false }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel),
              let current = doc.elements[i][keyPath: keyPath],
              current != value else { return false }
        beforeWrite()
        document?.elements[i][keyPath: keyPath] = value
        return true
    }

    /// Applies the global stroke width to the selected element. For text the
    /// width maps to the font point size (same mapping as creation) and the
    /// box height is re-measured so wrapped text doesn't get clipped. Undo
    /// boundaries are the caller's job (the slider wraps drags in
    /// begin/commitInteraction).
    private func applyStrokeWidthToSelection() {
        guard !isSyncing else { return }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel) else { return }
        if case .text(var t) = doc.elements[i] {
            let pointSize = FontSpec.suggestedPointSize(forStrokeWidth: strokeWidth)
            guard t.font.pointSize != pointSize else { return }
            t.font.pointSize = pointSize
            t.size = Renderer.suggestedSize(for: t)
            document?.elements[i] = .text(t)
        } else {
            applyToSelection(\.strokeWidth, strokeWidth)
        }
    }

    /// Applies the global text style to the selected text element as one undo
    /// step; the picker is discrete, so there is no drag to coalesce.
    private func applyTextStyleToSelection() {
        guard !isSyncing else { return }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel),
              let current = doc.elements[i].textStyle, current != textStyle else { return }
        let style = textStyle
        perform { $0.elements[i].textStyle = style }
    }

    /// Applies the global alignment to the selected text element as one undo
    /// step.
    private func applyTextAlignmentToSelection() {
        guard !isSyncing else { return }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel),
              let current = doc.elements[i].textAlignment, current != textAlignment else { return }
        let alignment = textAlignment
        perform { $0.elements[i].textAlignment = alignment }
    }

    /// Applies the global bubble shape to the selected callout as one undo
    /// step; plain text has no shape and is left alone.
    private func applyCalloutShapeToSelection() {
        guard !isSyncing else { return }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel),
              let current = doc.elements[i].calloutShape, current != calloutShape else { return }
        let shape = calloutShape
        perform { $0.elements[i].calloutShape = shape }
    }

    /// Applies the global loupe shape to the selected loupe as one undo step.
    private func applyMagnifierShapeToSelection() {
        guard !isSyncing else { return }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel),
              let current = doc.elements[i].magnifierShape, current != magnifierShape else { return }
        let shape = magnifierShape
        perform { $0.elements[i].magnifierShape = shape }
    }

    /// Applies the global loupe zoom to the selected loupe. Undo boundaries
    /// are the caller's job (the canvas slider wraps drags).
    private func applyMagnifierZoomToSelection() {
        applyToSelection(\.magnifierZoom, magnifierZoom)
    }

    /// Applies the global stamp kind to the selected stamp as one undo step.
    private func applyStampKindToSelection() {
        guard !isSyncing else { return }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel),
              let current = doc.elements[i].stampKind, current != stampKind else { return }
        let kind = stampKind
        perform { $0.elements[i].stampKind = kind }
    }

    /// Applies the global pen opacity to the selected stroke. Undo boundaries
    /// are the caller's job (the slider wraps drags in begin/commitInteraction).
    private func applyPenOpacityToSelection() {
        applyToSelection(\.opacity, penOpacity)
    }

    /// Applies the global text outline color to the selected text element as
    /// one undo step.
    private func applyTextOutlineColorToSelection() {
        guard !isSyncing else { return }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel),
              let current = doc.elements[i].textOutlineColor, current != textOutlineColor else { return }
        let color = textOutlineColor
        perform { $0.elements[i].textOutlineColor = color }
    }

    /// Applies the global pixelate amount to the selected element. Undo
    /// boundaries are the caller's job (the slider wraps drags in
    /// begin/commitInteraction).
    private func applyPixelateAmountToSelection() {
        applyToSelection(\.pixelateAmount, pixelateAmount)
    }

    /// Applies the global stroke color to the selected element. The color
    /// picker has no drag begin/end events, so the undo boundary is debounced:
    /// changes within 500ms coalesce into one undo step.
    private func applyColorToSelection() {
        let applied = applyToSelection(\.color, strokeColor) {
            if pendingCommitTask == nil { beginInteraction() }
        }
        guard applied else { return }
        pendingCommitTask?.cancel()
        pendingCommitTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            pendingCommitTask = nil
            commitInteraction()
        }
    }

    /// Discrete color choice (preset swatch tap): applies through the normal
    /// `didSet` path, then flushes the debounce so the tap is one undo step
    /// instead of coalescing with neighboring changes.
    func selectStrokeColor(_ color: RGBAColor) {
        flushPendingCommit()
        strokeColor = color
        flushPendingCommit()
    }

    /// Commits a debounce-pending change immediately so a following
    /// interaction or undo/redo doesn't clobber its snapshot.
    private func flushPendingCommit() {
        guard pendingCommitTask != nil else { return }
        pendingCommitTask?.cancel()
        pendingCommitTask = nil
        commitInteraction()
    }

    func deleteSelection() {
        guard let sel = selection else { return }
        perform { $0.remove(sel) }
        selection = nil
    }

    // MARK: - Crop

    /// Destructively applies the pending crop: trims the base image, shifts
    /// elements into the new origin, and shrinks the canvas. Undoable; the
    /// crop stays non-destructive (re-editable) until this is called.
    func applyCrop() {
        guard let doc = document, let base = baseImage,
              let clamped = doc.integralCrop,
              let croppedBase = base.cropping(to: clamped) else { return }

        var newDoc = doc
        newDoc.crop = nil
        newDoc.canvasSize = clamped.size
        let delta = CGVector(dx: -clamped.minX, dy: -clamped.minY)
        for i in newDoc.elements.indices { newDoc.elements[i].translate(by: delta) }

        undoStack.append(State(document: doc, image: base))
        redoStack.removeAll()
        baseImage = croppedBase
        document = newDoc
    }

    /// Cancels the pending crop without touching the image.
    func cancelCrop() {
        guard document?.crop != nil else { return }
        perform { $0.crop = nil }
    }
}
