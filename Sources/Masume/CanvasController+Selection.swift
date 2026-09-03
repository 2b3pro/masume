import Foundation
import CoreGraphics
import AnnotationModel
import AnnotationRender

// Tool state <-> selection for CanvasController: adopting the selected
// element's values into the controls, and writing a changed control back
// into the selected element. Split from CanvasController.swift for size.

extension CanvasController {
    /// Adopts the selected element's values so the controls start from the
    /// current ones (and new elements of its group inherit them).
    func syncToolStateFromSelection() {
        guard let sel = selection, let doc = document, let i = doc.index(of: sel) else { return }
        isSyncing = true
        defer { isSyncing = false }
        let element = doc.elements[i]
        syncSizeAndColor(from: element)
        syncStyles(from: element)
    }

    func syncSizeAndColor(from element: Annotation) {
        if case .text(let t) = element {
            let width = FontSpec.strokeWidth(forPointSize: t.font.pointSize)
            if width != strokeWidth { strokeWidth = width }
        } else if let width = element.strokeWidth, width != strokeWidth {
            strokeWidth = width
        }
        rememberWidth(strokeWidth, for: element.strokeWidthGroup)
        if let color = element.color, color != strokeColor { strokeColor = color }
        if let amount = element.pixelateAmount, amount != pixelateAmount { pixelateAmount = amount }
        if let opacity = element.opacity, opacity != penOpacity { penOpacity = opacity }
    }

    func syncStyles(from element: Annotation) {
        syncStampStyles(from: element)
        if let style = element.textStyle, style != textStyle { textStyle = style }
        if let outline = element.textOutlineColor, outline != textOutlineColor { textOutlineColor = outline }
        if let alignment = element.textAlignment, alignment != textAlignment { textAlignment = alignment }
        if let shape = element.calloutShape, shape != calloutShape { calloutShape = shape }
        if let shape = element.magnifierShape, shape != magnifierShape { magnifierShape = shape }
        if let zoom = element.magnifierZoom, zoom != magnifierZoom { magnifierZoom = zoom }
        if let mask = element.imageMask, mask != imageMask { imageMask = mask }
        if let shadow = element.imageShadow, shadow != imageShadow { imageShadow = shadow }
        if case .image(let e) = element, (e.borderWidth > 0) != imageBorder { imageBorder = e.borderWidth > 0 }
    }

    private func syncStampStyles(from element: Annotation) {
        if let kind = element.stampKind, kind != stampKind { stampKind = kind }
        if let emoji = element.stampEmoji, emoji != stampEmoji { stampEmoji = emoji }
    }

    /// Border on: the layer takes the shared shape width; off: zero.
    func applyImageBorderToSelection() {
        guard !isSyncing, let sel = selection, let doc = document, let i = doc.index(of: sel),
              case .image(let e) = doc.elements[i] else { return }
        let width: CGFloat = imageBorder ? max(strokeWidth, 1) : 0
        guard e.borderWidth != width else { return }
        perform { $0.elements[i].strokeWidth = width }
    }

    /// Shared `didSet` hook for the tool-state properties (stroke width /
    /// pixelate amount / color): writes `value` into the selected element
    /// through `keyPath`, returning whether a write happened. No-op while
    /// syncing (breaks the sync → apply feedback loop), without a selection,
    /// when the element lacks the property (`nil` current), or when the value
    /// is unchanged. `beforeWrite` runs after the guards pass and before the
    /// document write (the color path opens its undo snapshot there).
    @discardableResult
    func applyToSelection<Value: Equatable>(_ keyPath: WritableKeyPath<Annotation, Value?>,
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
    func applyStrokeWidthToSelection() {
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
    func applyTextStyleToSelection() {
        guard !isSyncing else { return }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel),
              let current = doc.elements[i].textStyle, current != textStyle else { return }
        let style = textStyle
        perform { $0.elements[i].textStyle = style }
    }

    /// Applies the global alignment to the selected text element as one undo
    /// step.
    func applyTextAlignmentToSelection() {
        guard !isSyncing else { return }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel),
              let current = doc.elements[i].textAlignment, current != textAlignment else { return }
        let alignment = textAlignment
        perform { $0.elements[i].textAlignment = alignment }
    }

    /// Applies the global bubble shape to the selected callout as one undo
    /// step; plain text has no shape and is left alone.
    func applyCalloutShapeToSelection() {
        guard !isSyncing else { return }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel),
              let current = doc.elements[i].calloutShape, current != calloutShape else { return }
        let shape = calloutShape
        perform { $0.elements[i].calloutShape = shape }
    }

    /// Applies the global loupe shape to the selected loupe as one undo step.
    func applyMagnifierShapeToSelection() {
        guard !isSyncing else { return }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel),
              let current = doc.elements[i].magnifierShape, current != magnifierShape else { return }
        let shape = magnifierShape
        perform { $0.elements[i].magnifierShape = shape }
    }

    /// Applies the global loupe zoom to the selected loupe. Undo boundaries
    /// are the caller's job (the canvas slider wraps drags).
    func applyMagnifierZoomToSelection() {
        applyToSelection(\.magnifierZoom, magnifierZoom)
    }

    /// Applies the global stamp kind to the selected stamp as one undo step.
    func applyStampKindToSelection() {
        guard !isSyncing else { return }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel),
              let current = doc.elements[i].stampKind, current != stampKind else { return }
        let kind = stampKind
        // A glyph stamp that becomes a counted one joins the sequence at
        // the end; a counted stamp switching between digits and letters
        // keeps its place.
        let ordinal = current.isOrdinal ? nil : doc.nextStampOrdinal(for: kind)
        perform { document in
            document.elements[i].stampKind = kind
            if let ordinal, case .stamp(var e) = document.elements[i] {
                e.ordinal = ordinal
                document.elements[i] = .stamp(e)
            }
        }
    }

    /// Applies the chosen emoji to the selected emoji stamp as one undo step.
    func applyStampEmojiToSelection() {
        guard !isSyncing else { return }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel),
              let current = doc.elements[i].stampEmoji, current != stampEmoji else { return }
        let emoji = stampEmoji
        perform { $0.elements[i].stampEmoji = emoji }
    }

    /// Switches the selected flag between digits and letters, keeping its
    /// count. Goes through `stampKind` so the palette follows. False when
    /// the selection is not a flag.
    @discardableResult
    func toggleSelectedStampLettering() -> Bool {
        guard let sel = selection, let doc = document, let i = doc.index(of: sel),
              let kind = doc.elements[i].stampKind, kind.isOrdinal else { return false }
        stampKind = kind == .number ? .letter : .number
        return true
    }

    /// Counts the selected numbered or lettered stamp up or down as one
    /// undo step. False when the selection is not such a stamp or the count
    /// is already at its limit.
    @discardableResult
    func stepSelectedStamp(by delta: Int) -> Bool {
        guard let sel = selection, let doc = document, let i = doc.index(of: sel),
              case .stamp(var e) = doc.elements[i], e.kind.isOrdinal else { return false }
        e.step(by: delta)
        guard e.ordinal != (doc.elements[i].stampOrdinal ?? e.ordinal) else { return false }
        perform { $0.elements[i] = .stamp(e) }
        return true
    }

    /// Applies the global pen opacity to the selected stroke. Undo boundaries
    /// are the caller's job (the slider wraps drags in begin/commitInteraction).
    func applyPenOpacityToSelection() {
        applyToSelection(\.opacity, penOpacity)
    }

    /// Applies the global text outline color to the selected text element as
    /// one undo step.
    func applyTextOutlineColorToSelection() {
        guard !isSyncing else { return }
        guard let sel = selection, let doc = document, let i = doc.index(of: sel),
              let current = doc.elements[i].textOutlineColor, current != textOutlineColor else { return }
        let color = textOutlineColor
        perform { $0.elements[i].textOutlineColor = color }
    }

    /// Applies the global pixelate amount to the selected element. Undo
    /// boundaries are the caller's job (the slider wraps drags in
    /// begin/commitInteraction).
    func applyPixelateAmountToSelection() {
        applyToSelection(\.pixelateAmount, pixelateAmount)
    }
}
