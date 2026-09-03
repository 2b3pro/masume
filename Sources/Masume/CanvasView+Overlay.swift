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
        if case .text(let text) = element, !text.isCallout,
           let center = textStyleButtonCenter(for: element, info: info) {
            drawTextStyleButton(at: center, for: text, in: ctx)
        }
        if case .magnifier(let loupe) = element, let track = magnifierSliderTrack(for: element, info: info) {
            drawMagnifierSlider(in: track, zoom: loupe.zoom, in: ctx)
        }
    }

    // MARK: Magnifier zoom slider

    /// Knob diameter; the track is thinner and vertically centered in it.
    static let magnifierSliderHeight: CGFloat = 16
    private static let magnifierSliderGap: CGFloat = 14
    private static let magnifierSliderMinWidth: CGFloat = 120
    private static let magnifierSliderMaxWidth: CGFloat = 240

    /// Track rect (view coordinates) of the zoom slider floating under a
    /// selected loupe; nil for other kinds.
    func magnifierSliderTrack(for element: Annotation, info: DisplayInfo) -> CGRect? {
        guard case .magnifier = element else { return nil }
        let box = info.viewRect(forModelRect: element.boundingBox())
        let width = min(Self.magnifierSliderMaxWidth, max(Self.magnifierSliderMinWidth, box.width))
        // Non-flipped view: below the box is the smaller y.
        return CGRect(x: box.midX - width / 2,
                      y: box.minY - Self.magnifierSliderGap - Self.magnifierSliderHeight,
                      width: width, height: Self.magnifierSliderHeight)
    }

    /// Zoom for a pointer x along the track (clamped to the ends).
    static func magnifierZoom(forX x: CGFloat, in track: CGRect) -> CGFloat {
        let usable = track.width - magnifierSliderHeight
        let fraction = usable > 0 ? min(1, max(0, (x - track.minX - magnifierSliderHeight / 2) / usable)) : 0
        let range = MagnifierElement.zoomRange
        return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }

    private static func magnifierKnobX(forZoom zoom: CGFloat, in track: CGRect) -> CGFloat {
        let range = MagnifierElement.zoomRange
        let fraction = (MagnifierElement.clampedZoom(zoom) - range.lowerBound) / (range.upperBound - range.lowerBound)
        return track.minX + magnifierSliderHeight / 2 + fraction * (track.width - magnifierSliderHeight)
    }

    /// Miro-style slider: gray track, blue fill up to a white knob, and the
    /// zoom factor as a small label beneath.
    private func drawMagnifierSlider(in track: CGRect, zoom: CGFloat, in ctx: CGContext) {
        let knobX = Self.magnifierKnobX(forZoom: zoom, in: track)
        let bar = CGRect(x: track.minX + Self.magnifierSliderHeight / 2, y: track.midY - 2,
                         width: track.width - Self.magnifierSliderHeight, height: 4)
        let barPath = CGPath(roundedRect: bar, cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.fill(track.insetBy(dx: -6, dy: -4))
        ctx.setFillColor(NSColor.miroDivider.cgColor)
        ctx.addPath(barPath)
        ctx.fillPath()
        ctx.setFillColor(NSColor.miroBlue.cgColor)
        ctx.fill(CGRect(x: bar.minX, y: bar.minY, width: max(0, knobX - bar.minX), height: bar.height))
        drawHandle(at: CGPoint(x: knobX, y: track.midY), stroke: NSColor.miroBlue, lineWidth: 1.5, in: ctx)

        let label = String(format: "%.1f×", zoom) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.miroBlue,
        ]
        let size = label.size(withAttributes: attrs)
        label.draw(at: NSPoint(x: track.midX - size.width / 2, y: track.minY - size.height - 1), withAttributes: attrs)
    }

    /// Clicks on the floating controls of the selection: the style button
    /// above a text box (cycles the style; handled before beginInteraction so
    /// the controller's own undo step is the only one recorded) and the zoom
    /// slider under a loupe (one undo step per drag). Returns true when the
    /// click was consumed.
    func handleOverlayControlMouseDown(at viewPoint: CGPoint, info: DisplayInfo) -> Bool {
        guard let controller, let sel = controller.selection,
              let element = controller.document?.elements.first(where: { $0.id == sel }) else { return false }
        if let center = textStyleButtonCenter(for: element, info: info),
           hypot(viewPoint.x - center.x, viewPoint.y - center.y) <= Self.textStyleButtonRadius {
            controller.textStyle = controller.textStyle.next
            drag = .none
            refresh()
            return true
        }
        if let track = magnifierSliderTrack(for: element, info: info),
           track.insetBy(dx: -6, dy: -6).contains(viewPoint) {
            controller.beginInteraction()
            controller.magnifierZoom = Self.magnifierZoom(forX: viewPoint.x, in: track)
            drag = .magnifierZoom(track: track)
            refresh()
            return true
        }
        return false
    }

    // MARK: Text style button

    static let textStyleButtonRadius: CGFloat = 15
    private static let textStyleButtonGap: CGFloat = 12

    /// Center (view coordinates) of the style-cycling button floating above a
    /// selected text box; nil for other kinds and for callouts, whose bubble
    /// replaces the halo/outline treatment.
    func textStyleButtonCenter(for element: Annotation, info: DisplayInfo) -> CGPoint? {
        guard case .text(let text) = element, !text.isCallout else { return nil }
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

// MARK: - Crop frame and zone

extension CanvasNSView {
    func drawCropOverlay(_ crop: CGRect, info: DisplayInfo, imageRect: CGRect, in ctx: CGContext) {
        let viewCrop = info.viewRect(forModelRect: crop)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fill(imageRect)
        ctx.clear(viewCrop)
        // Frame outside the image: the new canvas that applying would add.
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(viewCrop)
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

        drawFrameHandles(viewCrop, in: ctx)
    }

    /// The zone's marching ants: a rectangle or ellipse, dark underlay and
    /// white dashes like the crop outline, with nothing dimmed.
    func drawZone(_ zone: Zone, info: DisplayInfo, in ctx: CGContext) {
        let viewRect = info.viewRect(forModelRect: zone.rect)
        let path: CGPath
        switch zone.shape {
        case .rectangle: path = CGPath(rect: viewRect, transform: nil)
        case .ellipse: path = CGPath(ellipseIn: viewRect, transform: nil)
        }
        ctx.saveGState()
        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineDash(phase: antsPhase, lengths: [6, 4])
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Corner and edge handles so a frame is re-editable with the crop tool.
    func drawFrameHandles(_ viewRect: CGRect, in ctx: CGContext) {
        for handle in viewRect.frameHandles() {
            drawHandle(at: handle.position, stroke: NSColor.miroBlue, lineWidth: 1, in: ctx)
        }
    }
}
