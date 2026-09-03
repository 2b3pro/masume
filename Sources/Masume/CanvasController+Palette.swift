import Foundation
import CoreGraphics
import AnnotationModel
import AnnotationRender

// Which palette controls apply right now, from the active tool and the
// selection, plus the selection-only bubble conversion. Split from
// CanvasController.swift for size.

extension CanvasController {
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

    /// True when an image layer is selected: mask, border, and shadow apply.
    var editsImageLayer: Bool {
        guard let sel = selection, let doc = document, let i = doc.index(of: sel) else { return false }
        return doc.elements[i].imageMask != nil
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
}
