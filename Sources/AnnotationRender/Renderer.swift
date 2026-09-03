import Foundation
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import UniformTypeIdentifiers
import AnnotationModel

/// Pure drawing pipeline shared by the on-screen canvas and file/clipboard
/// export, so what you see equals what you get.
public enum Renderer {

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: true])

    /// Pixellated output per (base image, rect, amount). CIPixellate runs on
    /// the software renderer, so re-rendering every redaction on every
    /// flatten makes canvas redraws O(number of redactions) — measured at
    /// ~11ms per large redaction, i.e. 3+ redactions blow the 16ms frame
    /// budget during a slider drag. With the cache only the element being
    /// edited re-renders; the rest are straight blits. NSCache is documented
    /// thread-safe, hence `nonisolated(unsafe)`.
    private nonisolated(unsafe) static let redactionCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    /// Draws the base image plus every annotation into `ctx`. The context must
    /// already be set up so that model coordinates (top-left origin, y-down)
    /// map directly — see `flatten` / the canvas view for the CTM setup.
    public static func draw(_ doc: Document, baseImage: CGImage?, assets: [UUID: CGImage] = [:], in ctx: CGContext) {
        let canvas = CGRect(origin: .zero, size: doc.canvasSize)
        if let baseImage {
            drawImage(baseImage, in: canvas, ctx: ctx)
        }
        // Loupes magnify the base image plus every redaction, whatever the
        // z-order, so pixelated content can never be read through a loupe.
        let redactions = doc.elements.compactMap { element -> RedactionElement? in
            if case .pixelate(let r) = element { return r }
            return nil
        }
        let scene = Scene(base: baseImage, redactions: redactions, assets: assets, canvasSize: doc.canvasSize)
        for element in doc.elements {
            draw(element, in: scene, ctx: ctx)
        }
    }

    /// What every element may draw against besides itself.
    private struct Scene {
        let base: CGImage?
        let redactions: [RedactionElement]
        let assets: [UUID: CGImage]
        let canvasSize: CGSize
    }

    /// Renders the document to a `CGImage`, honoring the crop rect, at `scale`.
    public static func flatten(_ doc: Document, baseImage: CGImage?,
                               scale: CGFloat = 1,
                               bounds: ExportBounds = .clipToImage,
                               assets: [UUID: CGImage] = [:]) -> CGImage? {
        let out = doc.outputRect(for: bounds)
        let pixelW = Int((out.width * scale).rounded())
        let pixelH = Int((out.height * scale).rounded())
        let maxPixelCount = 256 * 1024 * 1024
        guard pixelW > 0, pixelH > 0, pixelW <= maxPixelCount, pixelH <= maxPixelCount, pixelW * pixelH <= maxPixelCount else { return nil }

        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: pixelW, height: pixelH,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        // Map model space (top-left origin, y-down, cropped) into the bitmap
        // (bottom-left origin, y-up).
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: out.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -out.origin.x, y: -out.origin.y)

        if bounds == .expandToFit {
            setFill(ctx, .white)
            ctx.fill(out)
        }

        draw(doc, baseImage: baseImage, assets: assets, in: ctx)
        return ctx.makeImage()
    }

    /// Encodes a CGImage to PNG, JPEG, or WebP bytes. WebP goes through
    /// libwebp (lossy) because ImageIO cannot write it; `quality` applies to
    /// both lossy formats.
    public static func encode(_ image: CGImage, as type: UTType, quality: CGFloat = 0.9) -> Data? {
        if type == .webP {
            return WebPEncoder.encodeLossy(image, quality: quality)
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - Per-element drawing

    private static func draw(_ element: Annotation, in scene: Scene, ctx: CGContext) {
        switch element {
        case .arrow(let e): drawArrow(e, in: ctx)
        case .line(let e): drawLine(e, in: ctx)
        case .rectangle(let e): drawRect(e, in: ctx)
        case .ellipse(let e): drawEllipse(e, in: ctx)
        case .pen(let e): drawPen(e, in: ctx)
        case .text(let e): drawText(e, in: ctx)
        case .stamp(let e): drawStamp(e, in: ctx)
        case .pixelate(let e): drawRedaction(e.rect, amount: e.amount, base: scene.base, canvasSize: scene.canvasSize, in: ctx)
        case .magnifier(let e):
            drawMagnifier(e, base: scene.base, redactions: scene.redactions, canvasSize: scene.canvasSize, in: ctx)
        case .image(let e): drawImageLayer(e, image: scene.assets[e.assetID], in: ctx)
        }
    }

    private static func imageMaskPath(_ e: ImageElement) -> CGPath {
        switch e.mask {
        case .rectangle: return CGPath(rect: e.rect, transform: nil)
        case .rounded: return CGPath(roundedRect: e.rect, cornerWidth: e.cornerRadius, cornerHeight: e.cornerRadius, transform: nil)
        case .circle: return CGPath(ellipseIn: e.rect, transform: nil)
        }
    }

    /// A pasted image layer: the asset scaled into its rect, clipped to the
    /// mask, with an optional border tracing the mask and an optional
    /// shadow under the whole thing. A missing asset draws a gray block so
    /// the document still reads.
    private static func drawImageLayer(_ e: ImageElement, image: CGImage?, in ctx: CGContext) {
        let path = imageMaskPath(e)
        let body = {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            if let image {
                ctx.interpolationQuality = .high
                drawImage(image, in: e.rect, ctx: ctx)
            } else {
                ctx.setFillColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)
                ctx.fill(e.rect)
            }
            ctx.restoreGState()
            if e.borderWidth > 0 {
                setStroke(ctx, e.borderColor, e.borderWidth)
                ctx.addPath(path)
                ctx.strokePath()
            }
        }
        if e.shadow {
            withShadow(forStrokeWidth: max(e.borderWidth, 4), in: ctx, body)
        } else {
            body()
        }
    }

    private static func magnifierPath(_ e: MagnifierElement) -> CGPath {
        switch e.shape {
        case .circle: return CGPath(ellipseIn: e.rect, transform: nil)
        case .square: return CGPath(roundedRect: e.rect, cornerWidth: e.cornerRadius,
                                    cornerHeight: e.cornerRadius, transform: nil)
        }
    }

    /// Loupe: the base image around the loupe's center scaled by its zoom,
    /// clipped to its shape, under a ring in the stroke color. Redactions are
    /// drawn into the magnified view too (see `draw(_:baseImage:in:)`); no
    /// other annotation is.
    private static func drawMagnifier(_ e: MagnifierElement, base: CGImage?, redactions: [RedactionElement],
                                      canvasSize: CGSize, in ctx: CGContext) {
        let path = magnifierPath(e)
        withShadow(forStrokeWidth: e.width, in: ctx) {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let c = e.center
            ctx.translateBy(x: c.x, y: c.y)
            ctx.scaleBy(x: e.zoom, y: e.zoom)
            ctx.translateBy(x: -c.x, y: -c.y)
            let canvas = CGRect(origin: .zero, size: canvasSize)
            if let base {
                ctx.interpolationQuality = .high
                drawImage(base, in: canvas, ctx: ctx)
            } else {
                ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
                ctx.fill(canvas)
            }
            for redaction in redactions {
                drawRedaction(redaction.rect, amount: redaction.amount, base: base, canvasSize: canvasSize, in: ctx)
            }
            ctx.restoreGState()
            setStroke(ctx, e.color, e.width)
            ctx.addPath(path)
            ctx.strokePath()
        }
    }

    /// CGContext image/text drawing assumes a y-up space, but the renderer
    /// runs with a y-down (model-space) CTM, which would mirror content
    /// vertically. Runs `body` with the context flipped locally around `rect`
    /// so the content lands upright.
    private static func withYFlip(around rect: CGRect, in ctx: CGContext, _ body: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.maxY + rect.minY)
        ctx.scaleBy(x: 1, y: -1)
        body()
        ctx.restoreGState()
    }

    private static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        withYFlip(around: rect, in: ctx) {
            ctx.draw(image, in: rect)
        }
    }

    private static func setStroke(_ ctx: CGContext, _ color: RGBAColor, _ width: CGFloat) {
        ctx.setStrokeColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
    }

    private static func setFill(_ ctx: CGContext, _ color: RGBAColor) {
        ctx.setFillColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)
    }

    /// Skitch-style soft drop shadow under every stroked or filled element,
    /// proportional to the stroke width so thin strokes get a whisper and
    /// thick ones a bold lift. CGContext shadows are specified in device
    /// space, not user space, so the offset and blur are pre-multiplied by
    /// the CTM's scale; the shadow then matches at every export scale and
    /// on-screen zoom. The body draws inside a transparency layer so a
    /// fill-plus-stroke shape casts one shadow, not two overlapping ones.
    static func withShadow(forStrokeWidth width: CGFloat, in ctx: CGContext, _ body: () -> Void) {
        let ctm = ctx.ctm
        let deviceScale = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
        let drop = max(1.5, width * 0.35) * deviceScale
        let blur = max(1.5, width * 0.5) * deviceScale
        ctx.saveGState()
        // Base space is y-up in every context the renderer targets, so a
        // negative height moves the shadow down the image.
        ctx.setShadow(offset: CGSize(width: drop * 0.4, height: -drop), blur: blur,
                      color: CGColor(gray: 0, alpha: 0.45))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func drawLine(_ e: SegmentElement, in ctx: CGContext) {
        withShadow(forStrokeWidth: e.width, in: ctx) {
            setStroke(ctx, e.color, e.width)
            ctx.beginPath()
            ctx.move(to: e.start)
            ctx.addLine(to: e.end)
            ctx.strokePath()
        }
    }

    private static func drawArrow(_ e: SegmentElement, in ctx: CGContext) {
        // Skitch-style arrow: one filled polygon (tapered shaft + barbed head).
        let outline = e.arrowOutline()
        guard let first = outline.first else { return }
        withShadow(forStrokeWidth: e.width, in: ctx) {
            setFill(ctx, e.color)
            ctx.beginPath()
            ctx.move(to: first)
            for p in outline.dropFirst() { ctx.addLine(to: p) }
            ctx.closePath()
            ctx.fillPath()
        }
    }

    /// Freehand stroke through the points, smoothed with quadratic curves
    /// through segment midpoints. One stroke operation, so self-overlaps do
    /// not double up when translucent. A lone point draws a round dot. No
    /// shadow: a highlighter must sit flat on the page.
    private static func drawPen(_ e: PenElement, in ctx: CGContext) {
        guard let first = e.points.first else { return }
        var color = e.color
        color.a *= e.opacity
        setStroke(ctx, color, e.width)
        ctx.beginPath()
        ctx.move(to: first)
        if e.points.count < 3 {
            for p in e.points.dropFirst() { ctx.addLine(to: p) }
            if e.points.count == 1 { ctx.addLine(to: first) }
        } else {
            for i in 1..<(e.points.count - 1) {
                let p = e.points[i], next = e.points[i + 1]
                let mid = CGPoint(x: (p.x + next.x) / 2, y: (p.y + next.y) / 2)
                ctx.addQuadCurve(to: mid, control: p)
            }
            ctx.addLine(to: e.points[e.points.count - 1])
        }
        ctx.strokePath()
    }

    private static func drawRect(_ e: ShapeElement, in ctx: CGContext) {
        withShadow(forStrokeWidth: e.width, in: ctx) {
            if let fill = e.fill {
                setFill(ctx, fill)
                ctx.fill(e.rect)
            }
            setStroke(ctx, e.color, e.width)
            ctx.stroke(e.rect)
        }
    }

    private static func drawEllipse(_ e: ShapeElement, in ctx: CGContext) {
        withShadow(forStrokeWidth: e.width, in: ctx) {
            if let fill = e.fill {
                setFill(ctx, fill)
                ctx.fillEllipse(in: e.rect)
            }
            setStroke(ctx, e.color, e.width)
            ctx.strokeEllipse(in: e.rect)
        }
    }

    /// Outline pass thickness as a percentage of the point size, the unit
    /// CoreText's stroke-width attribute uses. The stroke straddles the glyph
    /// edge, so the visible outer rim is half of this; the fill pass drawn on
    /// top covers the inner half.
    private static let haloStrokePercent: Double = 12
    private static let outlineStrokePercent: Double = 18

    /// Fill attributes, or a stroke-only pass when `stroke` is given. Stroke
    /// attributes do not change glyph advances, so the two passes line up.
    private static func attributedString(for e: TextElement,
                                         stroke: (color: RGBAColor, percent: Double)? = nil) -> NSAttributedString {
        let traits: CTFontSymbolicTraits = e.font.bold ? .traitBold : []
        let base = CTFontCreateWithName(e.font.family as CFString, e.font.pointSize, nil)
        let font = CTFontCreateCopyWithSymbolicTraits(base, e.font.pointSize, nil, traits, traits) ?? base
        let color = CGColor(red: e.color.r, green: e.color.g, blue: e.color.b, alpha: e.color.a)
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle(for: e.alignment),
        ]
        if let stroke {
            // A positive stroke width means stroke only (no fill).
            attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = stroke.percent
            attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] =
                CGColor(red: stroke.color.r, green: stroke.color.g, blue: stroke.color.b, alpha: stroke.color.a)
        }
        return NSAttributedString(string: e.string, attributes: attrs)
    }

    private static func paragraphStyle(for alignment: LineAlignment) -> CTParagraphStyle {
        var ctAlignment: CTTextAlignment
        switch alignment {
        case .left: ctAlignment = .left
        case .center: ctAlignment = .center
        case .right: ctAlignment = .right
        }
        return withUnsafeMutablePointer(to: &ctAlignment) { pointer in
            let setting = CTParagraphStyleSetting(spec: .alignment,
                                                  valueSize: MemoryLayout<CTTextAlignment>.size,
                                                  value: pointer)
            return CTParagraphStyleCreate([setting], 1)
        }
    }

    /// Size needed to render the full string wrapped at the element's current
    /// width. CoreText drops lines that don't fit the frame rect, so callers
    /// must grow `size` to this value or overflowing text silently disappears.
    /// An empty string yields the one-line minimum height, so editors shrink
    /// back when all text is deleted. A callout's size includes its padding
    /// on every side; the text wraps at the inner width.
    public static func suggestedSize(for e: TextElement) -> CGSize {
        let pad = e.padding
        let oneLine = e.font.pointSize + 8
        guard !e.string.isEmpty else {
            return CGSize(width: e.size.width, height: oneLine + 2 * pad)
        }
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString(for: e))
        let constraint = CGSize(width: e.textRect.width, height: .greatestFiniteMagnitude)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, constraint, nil)
        // +2 guards against fractional-height rounding clipping the last line.
        return CGSize(width: e.size.width, height: max(ceil(fit.height) + 2, oneLine) + 2 * pad)
    }

    /// The bubble under a callout's text: body filled with the element color,
    /// edged in the ink (outline) color, with the Skitch drop shadow. A
    /// thought cloud's trailing circles share the shadow layer.
    private static func drawCalloutBody(_ e: TextElement, in ctx: CGContext) {
        let body = CalloutPaths.bodyPath(for: e)
        let circles = CalloutPaths.thoughtTailCircles(for: e)
        withShadow(forStrokeWidth: e.font.pointSize * 0.25, in: ctx) {
            setFill(ctx, e.color)
            ctx.addPath(body)
            ctx.fillPath()
            setStroke(ctx, e.outlineColor, e.borderWidth)
            ctx.addPath(body)
            ctx.strokePath()
            for circle in circles {
                let box = CGRect(x: circle.center.x - circle.radius, y: circle.center.y - circle.radius,
                                 width: circle.radius * 2, height: circle.radius * 2)
                ctx.fillEllipse(in: box)
                ctx.strokeEllipse(in: box)
            }
        }
    }

    private static func drawText(_ e: TextElement, in ctx: CGContext) {
        if e.isCallout { drawCalloutBody(e, in: ctx) }
        guard !e.string.isEmpty else { return }
        let box = e.textRect
        let path = CGPath(rect: box, transform: nil)
        func drawPass(_ attributed: NSAttributedString) {
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
        }
        let fill = attributedString(for: e)

        withYFlip(around: box, in: ctx) {
            // Glyph outlines are stroked with the context's join; round keeps
            // the outline from spiking at sharp corners.
            ctx.setLineJoin(.round)
            // Callout text is plain ink over the body; the bubble supplies
            // the contrast a halo would.
            if e.isCallout {
                var ink = e
                ink.color = e.outlineColor
                drawPass(attributedString(for: ink))
                return
            }
            switch e.style {
            case .plain:
                drawPass(fill)
            case .outline:
                drawPass(attributedString(for: e, stroke: (e.outlineColor, outlineStrokePercent)))
                drawPass(fill)
            case .shadow:
                withShadow(forStrokeWidth: FontSpec.strokeWidth(forPointSize: e.font.pointSize), in: ctx) {
                    drawPass(attributedString(for: e, stroke: (e.outlineColor, haloStrokePercent)))
                    drawPass(fill)
                }
            }
        }
    }

    /// Skitch pin: white halo around the silhouette, drop shadow, colored
    /// fill, a thin white ring inside the disk, and the white glyph.
    private static func drawStamp(_ e: StampElement, in ctx: CGContext) {
        let r = e.radius
        let pin = StampPaths.pinPath(for: e)
        withShadow(forStrokeWidth: r * 0.3, in: ctx) {
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.setLineWidth(r * 0.12)
            ctx.addPath(pin)
            ctx.strokePath()
            setFill(ctx, e.color)
            ctx.addPath(pin)
            ctx.fillPath()
        }
        ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.setLineWidth(r * 0.07)
        ctx.strokeEllipse(in: e.diskRect.insetBy(dx: r * 0.28, dy: r * 0.28))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        if let label = e.label {
            drawStampLabel(label, for: e, in: ctx)
        } else {
            ctx.addPath(StampPaths.path(for: e.kind, in: e.diskRect.insetBy(dx: r * 0.5, dy: r * 0.5)))
            ctx.fillPath()
        }
    }

    /// The count of a numbered or lettered stamp, bold and white, centered
    /// on the disk and shrunk for longer labels so three digits still fit
    /// inside the ring; or an emoji stamp's character in Apple Color Emoji.
    private static func drawStampLabel(_ label: String, for e: StampElement, in ctx: CGContext) {
        let isEmoji = e.kind == .emoji
        let scale: CGFloat = isEmoji ? 1.1 : label.count <= 1 ? 1.3 : label.count == 2 ? 1.05 : 0.8
        let font = CTFontCreateWithName((isEmoji ? "AppleColorEmoji" : "HelveticaNeue-Bold") as CFString,
                                        e.radius * scale, nil)
        let attributed = NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        // Digits and capitals have no descenders, so their cap height is
        // what to center; an emoji fills its ascent-to-descent box.
        let height = isEmoji ? ascent - descent : CTFontGetCapHeight(font)
        withYFlip(around: e.diskRect, in: ctx) {
            // Flipped, the disk's y range is unchanged.
            ctx.textPosition = CGPoint(x: e.center.x - width / 2, y: e.center.y - height / 2)
            CTLineDraw(line, ctx)
        }
    }

    private static func drawRedaction(_ rect: CGRect, amount: CGFloat,
                                      base: CGImage?, canvasSize: CGSize, in ctx: CGContext) {
        guard let base, rect.width > 1, rect.height > 1 else {
            // Fallback: opaque gray block if no base image is available.
            ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
            ctx.fill(rect)
            return
        }
        // The base image's identity plus its dimensions guards against a
        // recycled ObjectIdentifier serving stale pixels for a new image.
        let key = "\(ObjectIdentifier(base))|\(base.width)x\(base.height)|\(rect)|\(amount)|\(canvasSize.height)" as NSString
        if let cached = redactionCache.object(forKey: key) {
            drawImage(cached, in: rect, ctx: ctx)
            return
        }

        // CIImage is y-up; convert the y-down model rect into image space.
        let ciImage = CIImage(cgImage: base)
        let flippedY = canvasSize.height - rect.maxY
        let ciRect = CGRect(x: rect.minX, y: flippedY, width: rect.width, height: rect.height)

        let f = CIFilter(name: "CIPixellate")!
        f.setValue(ciImage.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(max(2, amount), forKey: kCIInputScaleKey)
        f.setValue(CIVector(x: ciRect.midX, y: ciRect.midY), forKey: kCIInputCenterKey)
        let cropped = f.outputImage!.cropped(to: ciRect)
        guard let out = ciContext.createCGImage(cropped, from: ciRect) else { return }
        redactionCache.setObject(out, forKey: key, cost: out.bytesPerRow * out.height)
        drawImage(out, in: rect, ctx: ctx)
    }
}
