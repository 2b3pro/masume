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
    /// Character for new emoji stamps; edits the selected emoji stamp.
    var stampEmoji: String = StampElement.defaultEmoji {
        didSet {
            applyStampEmojiToSelection()
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
    /// Mask, border, and shadow for new image layers; each edits the selected
    /// image layer when one is selected.
    var imageMask: ImageMask = .rectangle {
        didSet {
            applyToSelection(\.imageMask, imageMask)
            persistPreferences()
        }
    }
    var imageBorder: Bool = false {
        didSet {
            applyImageBorderToSelection()
            persistPreferences()
        }
    }
    var imageShadow: Bool = true {
        didSet {
            applyToSelection(\.imageShadow, imageShadow)
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
    @ObservationIgnored let recoveryStore: RecoveryStore
    /// The document's durable identity, history, and recovery shadow; nil
    /// until an image is loaded.
    private(set) var project: ProjectSession?
    /// Who the next commits are attributed to when something other than the
    /// human is driving (the command service sets this around each call).
    /// Nil means the human user.
    @ObservationIgnored var commitAttribution: (actor: HistoryActor, reason: String?)?

    init(preferencesStore: ToolPreferencesStore = UserDefaultsToolPreferencesStore(),
         recoveryStore: RecoveryStore = .default) {
        self.preferencesStore = preferencesStore
        self.recoveryStore = recoveryStore
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
        stampEmoji = prefs.stampEmoji
        textAlignment = prefs.textAlignment
        calloutShape = prefs.calloutShape
        magnifierShape = prefs.magnifierShape
        magnifierZoom = prefs.magnifierZoom
        imageMask = prefs.imageMask
        imageBorder = prefs.imageBorder
        imageShadow = prefs.imageShadow
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
        prefs.stampEmoji = stampEmoji
        prefs.textAlignment = textAlignment
        prefs.calloutShape = calloutShape
        prefs.magnifierShape = magnifierShape
        prefs.magnifierZoom = magnifierZoom
        prefs.imageMask = imageMask
        prefs.imageBorder = imageBorder
        prefs.imageShadow = imageShadow
        return prefs
    }

    private func persistPreferences() {
        preferencesStore.save(toolPreferences)
    }
    private static let showsGridKey = "showsGrid"
    /// Whether the address grid is drawn over the canvas. Display only: the
    /// grid never exports and addresses resolve whether or not it shows.
    var showsGrid: Bool = UserDefaults.standard.bool(forKey: CanvasController.showsGridKey) {
        didSet { UserDefaults.standard.set(showsGrid, forKey: Self.showsGridKey) }
    }
    private static let exportBoundsKey = "exportBounds"
    var exportBounds: ExportBounds = UserDefaults.standard.rawRepresentable(
        forKey: CanvasController.exportBoundsKey, default: .expandToFit
    ) {
        didSet {
            UserDefaults.standard.set(exportBounds.rawValue, forKey: Self.exportBoundsKey)
        }
    }
    var sourceURL: URL?

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
    @ObservationIgnored var isSyncing = false

    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private var interactionSnapshot: State?
    @ObservationIgnored private var pendingCommitTask: Task<Void, Never>?

    var hasDocument: Bool { document != nil }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - Loading

    /// A multi-page PDF awaiting a page choice; the canvas pane shows the
    /// page picker while this is set.
    var pendingPDF: PDFPageSource?
    /// Set by Replace Image so the chosen page replaces the document instead
    /// of landing on it as a layer.
    @ObservationIgnored var pendingPDFReplaces = false

    /// A freshly imported image: a new document with a new project session,
    /// shadowed into recovery at once.
    func load(image: CGImage, sourceURL: URL?) {
        let size = CGSize(width: image.width, height: image.height)
        let ref: ImageRef = sourceURL.map { .file(path: $0.path) } ?? .pngData(Data())
        let session = ProjectSession(baseImagePNG: Renderer.encode(image, as: .png) ?? Data(), recovery: recoveryStore)
        install(image: image, document: Document(baseImage: ref, canvasSize: size), sourceURL: sourceURL, session: session)
        autosave()
    }

    /// Makes `document` the open document: resets selection, tool sizing,
    /// undo, and zoom for the new canvas. Shared by import, open, and recovery.
    func install(image: CGImage, document: Document, sourceURL: URL?, session: ProjectSession) {
        let size = document.canvasSize
        baseImage = image
        self.document = document
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
        project = session
    }

    // MARK: - Project commits

    /// The one place a committed change becomes durable: revision, history
    /// entry, recovery autosave. Every path that registers undo ends here.
    private func didCommit(before: State, after: Document) {
        guard let project else { return }
        if let image = baseImage, before.image !== image, let png = Renderer.encode(image, as: .png) {
            project.replaceBaseImage(png)
        }
        project.record(before: before.document, after: after,
                       actor: commitAttribution?.actor, reason: commitAttribution?.reason)
        autosave()
    }

    /// Writes the recovery package. A failure is shown in the toast; the
    /// document is dirty either way, so nothing is reported as saved.
    func autosave() {
        guard let project, let document else { return }
        let base = baseImage
        let assets = project.assetImages
        project.autosave(document: document) { ProjectSession.previewPNG(document: document, baseImage: base, assets: assets) }
        if let error = project.autosaveError { flashToast("Recovery autosave failed: \(error)") }
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
        guard let pre = interactionSnapshot, let document, pre.document != document else { return }
        undoStack.append(pre)
        redoStack.removeAll()
        didCommit(before: pre, after: document)
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
        didCommit(before: pre, after: doc)
    }

    func undo() {
        flushPendingCommit()
        guard let pre = undoStack.popLast(), let current = document else { return }
        let now = State(document: current, image: baseImage)
        redoStack.append(now)
        document = pre.document
        baseImage = pre.image
        clampSelection()
        didCommit(before: now, after: pre.document)
    }

    func redo() {
        flushPendingCommit()
        guard let next = redoStack.popLast(), let current = document else { return }
        let now = State(document: current, image: baseImage)
        undoStack.append(now)
        document = next.document
        baseImage = next.image
        clampSelection()
        didCommit(before: now, after: next.document)
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
    func rememberWidth(_ width: CGFloat, for group: StrokeWidthGroup?) {
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
    /// Return key: applies a pending crop; false when there is none.
    @discardableResult
    func applyPendingCrop() -> Bool {
        guard document?.crop != nil else { return false }
        applyCrop()
        return true
    }

    func applyCrop() {
        guard let doc = document, let base = baseImage,
              let clamped = doc.integralCrop,
              let croppedBase = base.cropping(to: clamped) else { return }

        var newDoc = doc
        newDoc.crop = nil
        newDoc.canvasSize = clamped.size
        // A different image now: the default grid for its size, new version.
        newDoc.grid = GridDefinition.preset(doc.grid.matchingPreset(for: doc.canvasSize)
                                            ?? GridDefinition.tier(forLongSide: max(clamped.width, clamped.height)),
                                            for: clamped.size, version: doc.grid.version + 1)
        let delta = CGVector(dx: -clamped.minX, dy: -clamped.minY)
        for i in newDoc.elements.indices { newDoc.elements[i].translate(by: delta) }

        let pre = State(document: doc, image: base)
        undoStack.append(pre)
        redoStack.removeAll()
        baseImage = croppedBase
        document = newDoc
        didCommit(before: pre, after: newDoc)
    }

    /// Cancels the pending crop without touching the image.
    func cancelCrop() {
        guard document?.crop != nil else { return }
        perform { $0.crop = nil }
    }
}
