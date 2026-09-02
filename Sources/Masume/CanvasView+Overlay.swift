import AppKit
import CoreGraphics
import AnnotationModel
import AnnotationRender

// Selection overlay for CanvasNSView: handles, the selection frame, and the
// text style preview button. Split from CanvasView.swift for size.

extension CanvasNSView {
    func drawHandle(at center: CGPoint, stroke: NSColor, lineWidth: CGFloat, in ctx: CGContext) {
        let hr = CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: hr)
        ctx.setStrokeColor(stroke.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.strokeEllipse(in: hr)
    }

    func drawSelection(_ element: Annotation, info: DisplayInfo, in ctx: CGContext) {
        let viewBox = info.viewRect(forModelRect: element.boundingBox())
        ctx.setStrokeColor(NSColor.miroBlue.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(viewBox.insetBy(dx: -2, dy: -2))

        for handle in element.handles() {
            drawHandle(at: info.modelToView(handle.position),
                       stroke: NSColor.miroBlue, lineWidth: 1.5, in: ctx)
        }
        if case .text(let text) = element, let center = textStyleButtonCenter(for: element, info: info) {
            drawTextStyleButton(at: center, for: text, in: ctx)
        }
    }

    // MARK: Text style button

    static let textStyleButtonRadius: CGFloat = 15
    private static let textStyleButtonGap: CGFloat = 12

    /// Center (view coordinates) of the style-cycling button floating above a
    /// selected text box; nil for other kinds.
    func textStyleButtonCenter(for element: Annotation, info: DisplayInfo) -> CGPoint? {
        guard case .text = element else { return nil }
        let box = info.viewRect(forModelRect: element.boundingBox())
        // Non-flipped view: above the box is the larger y.
        return CGPoint(x: box.midX, y: box.maxY + Self.textStyleButtonGap + Self.textStyleButtonRadius)
    }

    /// A disc showing an "a" rendered in the style the text would take on
    /// the next click: same color and halo/outline color as the element, so
    /// the button is a truthful preview rather than an icon.
    private func drawTextStyleButton(at center: CGPoint, for text: TextElement, in ctx: CGContext) {
        let r = Self.textStyleButtonRadius
        let disc = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: disc)
        ctx.setStrokeColor(NSColor.miroBlue.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: disc)

        var glyph = TextElement(origin: .zero, string: "a",
                                font: FontSpec(pointSize: 19, bold: text.font.bold),
                                color: text.color, style: text.style.next, outlineColor: text.outlineColor)
        glyph.size = Renderer.suggestedSize(for: glyph)
        // The line box is left-aligned; size it to the glyph's advance (about
        // 0.56em for a bold "a") so the glyph lands on the disc's center.
        glyph.size.width = 12
        let doc = Document(baseImage: .pngData(Data()), canvasSize: glyph.size, elements: [.text(glyph)])
        ctx.saveGState()
        ctx.addEllipse(in: disc)
        ctx.clip()
        // Map the renderer's y-down model space onto the disc, glyph box
        // centered (nudged up a little: the glyph sits low in its line box).
        ctx.translateBy(x: center.x - glyph.size.width / 2, y: center.y + glyph.size.height / 2 + 2)
        ctx.scaleBy(x: 1, y: -1)
        Renderer.draw(doc, baseImage: nil, in: ctx)
        ctx.restoreGState()
    }
}
