import AppKit
import CoreGraphics
import AnnotationModel
import AnnotationRender

// Inline text editing for CanvasNSView: the NSTextView overlay that edits a
// text box or callout in place, and the AppKit color/font/alignment
// bridges it needs. Split from CanvasView.swift for size.

class MinimalTextView: NSTextView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        menu.items.removeAll { item in
            if let action = item.action {
                return blockedMenuActions.contains(action)
            }
            return blockedMenuTitles.contains(item.title)
        }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
    }
}

extension CanvasNSView: NSTextViewDelegate {
    /// Editor frame for a text element's model rect; the -2 inset leaves room
    /// for the editor chrome around the rendered text.
    private func textEditorFrame(forModelRect rect: CGRect) -> NSRect {
        displayInfo.viewRect(forModelRect: rect).insetBy(dx: -2, dy: -2)
    }

    func beginTextEditing(for id: ElementID) {
        guard let controller,
              let element = controller.document?.elements.first(where: { $0.id == id }),
              case .text(let text) = element else { return }
        commitTextEditing()

        let info = displayInfo
        let tv = MinimalTextView(frame: textEditorFrame(forModelRect: text.textRect))
        tv.string = text.string
        tv.font = nsFont(for: text.font, scale: info.scale)
        tv.alignment = nsAlignment(text.alignment)
        if text.isCallout {
            // Edit in the bubble's own colors: ink on the fill.
            tv.textColor = nsColor(text.outlineColor)
            tv.backgroundColor = nsColor(text.color).withAlphaComponent(0.9)
        } else {
            tv.textColor = nsColor(text.color)
            tv.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.9)
        }
        tv.isRichText = false
        tv.drawsBackground = true
        tv.delegate = self
        addSubview(tv)
        window?.makeFirstResponder(tv)
        textEditor = tv
        editingTextID = id
        controller.isEditingText = true
    }

    /// Re-anchors the inline editor after the display mapping moved under it
    /// (pan). Sizes from the live editor string, like textDidChange, so a
    /// mid-typing pan doesn't snap the frame back to the committed text.
    func syncTextEditorFrame() {
        guard let tv = textEditor, let id = editingTextID,
              let element = controller?.document?.elements.first(where: { $0.id == id }),
              case .text(var t) = element else { return }
        t.string = tv.string
        t.size = Renderer.suggestedSize(for: t)
        let newFrame = textEditorFrame(forModelRect: t.textRect)
        if tv.frame != newFrame { tv.frame = newFrame }
    }

    func commitTextEditing() {
        guard let tv = textEditor, let id = editingTextID, let controller else { return }
        let newString = tv.string
        tv.removeFromSuperview()
        textEditor = nil
        editingTextID = nil
        controller.isEditingText = false

        if newString.isEmpty {
            controller.perform { $0.remove(id) }
            if controller.selection == id { controller.selection = nil }
        } else {
            controller.perform { doc in
                doc.mutate(id) { annotation in
                    if case .text(var t) = annotation {
                        t.string = newString
                        t.size = Renderer.suggestedSize(for: t)
                        annotation = .text(t)
                    }
                }
            }
        }
        // Editing over means the text is placed: an unlocked Text or Callout
        // tool hands back to Select, so the click that ended typing (if that
        // is what did) proceeds as a Select click rather than a new box.
        controller.didPlaceAnnotation()
        refresh()
    }

    func textDidEndEditing(_ notification: Notification) {
        commitTextEditing()
    }

    // Resize the inline editor with its content; otherwise text past the fixed
    // frame is invisible while typing (the model rect is synced on commit).
    func textDidChange(_ notification: Notification) {
        syncTextEditorFrame()
    }
}

func nsColor(_ c: RGBAColor) -> NSColor {
    NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
}

func nsAlignment(_ alignment: LineAlignment) -> NSTextAlignment {
    switch alignment {
    case .left: return .left
    case .center: return .center
    case .right: return .right
    }
}

func nsFont(for spec: FontSpec, scale: CGFloat) -> NSFont {
    let size = spec.pointSize * scale
    let base = NSFont(name: spec.family, size: size) ?? NSFont.systemFont(ofSize: size)
    if spec.bold {
        return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
    }
    return base
}
