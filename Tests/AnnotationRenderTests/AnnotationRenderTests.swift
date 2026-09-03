import XCTest
import CoreGraphics
import UniformTypeIdentifiers
@testable import AnnotationModel
@testable import AnnotationRender

final class AnnotationRenderTests: XCTestCase {

    private func solidImage(_ size: CGSize, color: (Double, Double, Double)) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
        return ctx.makeImage()!
    }

    func testFlattenProducesFullCanvasImage() {
        let base = solidImage(CGSize(width: 100, height: 80), color: (0, 0, 1))
        let doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 100, height: 80))
        let out = Renderer.flatten(doc, baseImage: base, scale: 1)
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.width, 100)
        XCTAssertEqual(out?.height, 80)
    }

    func testFlattenHonorsCrop() {
        let base = solidImage(CGSize(width: 100, height: 80), color: (0, 0, 1))
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 100, height: 80))
        doc.crop = CGRect(x: 10, y: 10, width: 40, height: 20)
        let out = Renderer.flatten(doc, baseImage: base, scale: 1)
        XCTAssertEqual(out?.width, 40)
        XCTAssertEqual(out?.height, 20)
    }

    func testFlattenScale() {
        let base = solidImage(CGSize(width: 50, height: 50), color: (1, 0, 0))
        let doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 50, height: 50))
        let out = Renderer.flatten(doc, baseImage: base, scale: 2)
        XCTAssertEqual(out?.width, 100)
        XCTAssertEqual(out?.height, 100)
    }

    func testPNGEncodeRoundTrips() {
        let base = solidImage(CGSize(width: 20, height: 20), color: (0, 1, 0))
        let doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 20, height: 20))
        let img = Renderer.flatten(doc, baseImage: base, scale: 1)!
        let png = Renderer.encode(img, as: .png)
        XCTAssertNotNil(png)
        XCTAssertGreaterThan(png!.count, 8)
        // PNG magic number.
        XCTAssertEqual(Array(png!.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    /// Top-red / bottom-blue base image must come out of `flatten` with red
    /// still on top (model space and CGImage row order are both top-down).
    private func topRedBottomBlueImage(_ size: CGSize) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let w = Int(size.width), h = Int(size.height)
        let ctx = CGContext(data: nil, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CGBitmapContext is y-up: the upper half is y >= h/2.
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h - h / 2))
        return ctx.makeImage()!
    }

    func testFlattenPreservesBaseImageOrientation() {
        let base = topRedBottomBlueImage(CGSize(width: 40, height: 40))
        let doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 40, height: 40))
        let out = Renderer.flatten(doc, baseImage: base, scale: 1)!
        let top = samplePixel(out, x: 20, y: 5)
        let bottom = samplePixel(out, x: 20, y: 35)
        XCTAssertGreaterThan(top.r, 200, "top of flattened image should be red")
        XCTAssertLessThan(top.b, 50)
        XCTAssertGreaterThan(bottom.b, 200, "bottom of flattened image should be blue")
        XCTAssertLessThan(bottom.r, 50)
    }

    /// An annotation near the model-space top must land near the top of the
    /// output, on top of the red half.
    func testElementPositionMatchesBaseImageOrientation() {
        let base = topRedBottomBlueImage(CGSize(width: 40, height: 40))
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 40, height: 40))
        doc.add(.rectangle(ShapeElement(rect: CGRect(x: 2, y: 2, width: 36, height: 8),
                                        color: .black, width: 2, fill: .black)))
        let out = Renderer.flatten(doc, baseImage: base, scale: 1)!
        let inked = samplePixel(out, x: 20, y: 6)
        XCTAssertLessThan(inked.r + inked.g + inked.b, 90, "rect at model top should ink the output top")
        let bottom = samplePixel(out, x: 20, y: 35)
        XCTAssertGreaterThan(bottom.b, 200, "bottom half should remain blue")
    }

    func testArrowChangesPixels() {
        let base = solidImage(CGSize(width: 100, height: 100), color: (1, 1, 1))
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 100, height: 100))
        let plain = Renderer.flatten(doc, baseImage: base, scale: 1)!
        doc.add(.arrow(SegmentElement(start: CGPoint(x: 10, y: 50), end: CGPoint(x: 90, y: 50), color: .red, width: 8)))
        let annotated = Renderer.flatten(doc, baseImage: base, scale: 1)!
        XCTAssertNotEqual(pixelHash(plain), pixelHash(annotated))
    }

    // MARK: - Drop shadows

    /// Skitch-style shadow: a stroke on white leaves a darkened band just
    /// below it, and nothing above it beyond the blur reach.
    func testStrokedElementsCastShadowBelow() {
        let base = solidImage(CGSize(width: 100, height: 100), color: (1, 1, 1))
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 100, height: 100))
        doc.add(.line(SegmentElement(start: CGPoint(x: 20, y: 30), end: CGPoint(x: 80, y: 30), color: .red, width: 6)))
        let out = Renderer.flatten(doc, baseImage: base, scale: 1)!

        let below = samplePixel(out, x: 50, y: 36)   // just under the 6pt stroke (27...33)
        XCTAssertLessThan(below.r + below.g + below.b, 720, "expected a shadow band below the stroke")
        XCTAssertEqual(below.r, below.g, accuracy: 3, "shadow should be neutral, not tinted")

        let above = samplePixel(out, x: 50, y: 18)
        XCTAssertEqual(above.r + above.g + above.b, 765, "no shadow expected well above the stroke")
    }

    /// CGContext shadows are specified in device space; the renderer must
    /// compensate so a 2x export carries the same shadow as 1x, just scaled.
    func testShadowScalesWithExportScale() {
        let base = solidImage(CGSize(width: 100, height: 100), color: (1, 1, 1))
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 100, height: 100))
        doc.add(.line(SegmentElement(start: CGPoint(x: 20, y: 30), end: CGPoint(x: 80, y: 30), color: .red, width: 6)))
        let one = Renderer.flatten(doc, baseImage: base, scale: 1)!
        let two = Renderer.flatten(doc, baseImage: base, scale: 2)!

        let at1 = samplePixel(one, x: 50, y: 36)
        let at2 = samplePixel(two, x: 100, y: 72)
        XCTAssertEqual(at1.r, at2.r, accuracy: 12)
        XCTAssertLessThan(at2.r + at2.g + at2.b, 720)
    }

    func testShadowIsPresentOnAllStrokedKinds() {
        let base = solidImage(CGSize(width: 100, height: 100), color: (1, 1, 1))
        let kinds: [(String, Annotation)] = [
            ("arrow", .arrow(SegmentElement(start: CGPoint(x: 10, y: 30), end: CGPoint(x: 90, y: 30), color: .red, width: 6))),
            ("rectangle", .rectangle(ShapeElement(rect: CGRect(x: 20, y: 10, width: 60, height: 20), color: .red, width: 6))),
            ("ellipse", .ellipse(ShapeElement(rect: CGRect(x: 20, y: 10, width: 60, height: 20), color: .red, width: 6))),
        ]
        for (name, element) in kinds {
            var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 100, height: 100))
            doc.add(element)
            let out = Renderer.flatten(doc, baseImage: base, scale: 1)!
            // Scan the column under the element's bottom edge for any non-white pixel
            // that is neutral gray (shadow) rather than red (the element itself).
            let shadowed = (34...42).contains { y in
                let p = samplePixel(out, x: 50, y: y)
                return p.r + p.g + p.b < 740 && abs(p.r - p.g) <= 3
            }
            XCTAssertTrue(shadowed, "\(name) should cast a shadow below its bottom edge")
        }
    }

    // MARK: - Text styles

    private func textDoc(style: TextStyle, color: RGBAColor, outline: RGBAColor = .white) -> Document {
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 200, height: 80))
        doc.add(.text(TextElement(origin: CGPoint(x: 10, y: 10), size: CGSize(width: 180, height: 60),
                                  string: "Hello", font: FontSpec(pointSize: 36), color: color, style: style,
                                  outlineColor: outline)))
        return doc
    }

    private func pixels(_ image: CGImage) -> [(r: Int, g: Int, b: Int)] {
        (0..<image.height).flatMap { y in (0..<image.width).map { x in samplePixel(image, x: x, y: y) } }
    }

    /// Outline style draws a black outline around the glyphs; plain does not.
    func testOutlineStyleAddsBlackOutline() {
        let base = solidImage(CGSize(width: 200, height: 80), color: (1, 1, 1))
        let isBlack: ((r: Int, g: Int, b: Int)) -> Bool = { $0.r < 60 && $0.g < 60 && $0.b < 60 }
        let outlined = Renderer.flatten(textDoc(style: .outline, color: .yellow, outline: .black), baseImage: base, scale: 1)!
        XCTAssertTrue(pixels(outlined).contains(where: isBlack), "outline style should produce black pixels")
        let whiteOutlined = Renderer.flatten(textDoc(style: .outline, color: .yellow, outline: .white), baseImage: base, scale: 1)!
        XCTAssertFalse(pixels(whiteOutlined).contains(where: isBlack), "a white outline draws no black")
        let plain = Renderer.flatten(textDoc(style: .plain, color: .yellow), baseImage: base, scale: 1)!
        XCTAssertFalse(pixels(plain).contains(where: isBlack), "plain style should not produce black pixels")
    }

    /// The halo takes the outline color too: black halo on white shows black.
    func testShadowStyleHaloUsesOutlineColor() {
        let white = solidImage(CGSize(width: 200, height: 80), color: (1, 1, 1))
        let isBlack: ((r: Int, g: Int, b: Int)) -> Bool = { $0.r < 60 && $0.g < 60 && $0.b < 60 }
        let blackHalo = Renderer.flatten(textDoc(style: .shadow, color: .yellow, outline: .black), baseImage: white, scale: 1)!
        XCTAssertTrue(pixels(blackHalo).contains(where: isBlack))
        let whiteHalo = Renderer.flatten(textDoc(style: .shadow, color: .yellow, outline: .white), baseImage: white, scale: 1)!
        XCTAssertFalse(pixels(whiteHalo).contains(where: isBlack))
    }

    /// Shadow style draws a white halo around the glyphs (visible on black)
    /// and a neutral drop shadow (visible on white); plain does neither.
    func testShadowStyleAddsWhiteHaloAndShadow() {
        let black = solidImage(CGSize(width: 200, height: 80), color: (0, 0, 0))
        let isWhite: ((r: Int, g: Int, b: Int)) -> Bool = { $0.r > 200 && $0.g > 200 && $0.b > 200 }
        let shadowed = Renderer.flatten(textDoc(style: .shadow, color: .red), baseImage: black, scale: 1)!
        XCTAssertTrue(pixels(shadowed).contains(where: isWhite), "shadow style should halo the glyphs in white")
        let plain = Renderer.flatten(textDoc(style: .plain, color: .red), baseImage: black, scale: 1)!
        XCTAssertFalse(pixels(plain).contains(where: isWhite))

        let white = solidImage(CGSize(width: 200, height: 80), color: (1, 1, 1))
        let isGray: ((r: Int, g: Int, b: Int)) -> Bool = {
            abs($0.r - $0.g) <= 4 && abs($0.g - $0.b) <= 4 && $0.r < 235 && $0.r > 40
        }
        let onWhite = Renderer.flatten(textDoc(style: .shadow, color: .red), baseImage: white, scale: 1)!
        XCTAssertTrue(pixels(onWhite).contains(where: isGray), "shadow style should cast a gray shadow")
        let plainOnWhite = Renderer.flatten(textDoc(style: .plain, color: .red), baseImage: white, scale: 1)!
        XCTAssertFalse(pixels(plainOnWhite).contains(where: isGray))
    }

    // MARK: - Stamps

    private func stampDoc(_ kind: StampKind, color: RGBAColor = .red) -> Document {
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 200, height: 200))
        doc.add(.stamp(StampElement(center: CGPoint(x: 100, y: 80), radius: 40, kind: kind, color: color)))
        return doc
    }

    /// Colored disk, white ring inside it, colored tail below (default
    /// pointer points down), and white halo just outside the disk.
    func testStampDrawsDiskRingTailAndHalo() {
        let base = solidImage(CGSize(width: 200, height: 200), color: (0, 0, 0))
        let out = Renderer.flatten(stampDoc(.check, color: .red), baseImage: base, scale: 1)!

        let disk = samplePixel(out, x: 100 + 36, y: 80)          // 0.9r, right of center
        XCTAssertGreaterThan(disk.r, 180); XCTAssertLessThan(disk.g, 90)
        // The ring is a few pixels wide; scan its band rather than one pixel.
        let ringHit = (24...34).contains { dy in
            let p = samplePixel(out, x: 100, y: 80 - dy)
            return min(p.r, p.g, p.b) > 200
        }
        XCTAssertTrue(ringHit, "white ring inside the disk")
        let tail = samplePixel(out, x: 100, y: 80 + Int(40 * 1.5))
        XCTAssertGreaterThan(tail.r, 180); XCTAssertLessThan(tail.g, 90)
        let halo = samplePixel(out, x: 100 - 42, y: 80)         // 1.05r, left of center
        XCTAssertGreaterThan(min(halo.r, halo.g, halo.b), 180, "white halo outside the disk on black")
    }

    /// A numbered stamp shows its count as white text on the disk: the
    /// stroke of a "1" crosses the disk center, and a lettered "A" leaves
    /// the exact center colored (the crossbar sits low) but paints white
    /// on the legs beside it.
    func testNumberedAndLetteredStampsDrawTheirCountInWhite() {
        let base = solidImage(CGSize(width: 200, height: 200), color: (0, 0, 0))
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 200, height: 200))
        doc.add(.stamp(StampElement(center: CGPoint(x: 100, y: 80), radius: 40, kind: .number, color: .red, ordinal: 1)))
        let one = Renderer.flatten(doc, baseImage: base, scale: 1)!
        let center = samplePixel(one, x: 100, y: 80)
        XCTAssertGreaterThan(min(center.r, center.g, center.b), 200, "the 1's stem is white at the disk center")
        let beside = samplePixel(one, x: 100 + 22, y: 80)
        XCTAssertGreaterThan(beside.r, 180); XCTAssertLessThan(beside.g, 90)

        doc.elements[0].stampKind = .letter
        let a = Renderer.flatten(doc, baseImage: base, scale: 1)!
        // Inside the white ring (at 0.72r) only, so the ring itself is not counted.
        func whitePixels(_ image: CGImage) -> [(Int, Int)] {
            (76...124).flatMap { x in (56...104).compactMap { y in
                guard hypot(Double(x - 100), Double(y - 80)) < 24 else { return nil }
                let p = samplePixel(image, x: x, y: y)
                return min(p.r, p.g, p.b) > 200 ? (x, y) : nil
            } }
        }
        let whiteInA = whitePixels(a), whiteInOne = whitePixels(one)
        XCTAssertGreaterThan(whiteInA.count, 200, "the A paints a good deal of white inside the disk")
        XCTAssertGreaterThan(whiteInA.count, whiteInOne.count, "two legs and a bar cover more than one stem")
        XCTAssertTrue(whiteInA.contains { $0.0 < 90 && $0.1 > 90 }, "the A's left leg reaches the lower left")
        XCTAssertFalse(whiteInOne.contains { $0.0 < 88 && $0.1 > 90 }, "the 1 has nothing there")
    }

    func testStampGlyphIsWhiteAtItsCenterForBarGlyphs() {
        let base = solidImage(CGSize(width: 200, height: 200), color: (0, 0, 0))
        // The cross and exclaim glyphs both cover the disk center.
        for kind in [StampKind.cross, .exclaim] {
            let out = Renderer.flatten(stampDoc(kind), baseImage: base, scale: 1)!
            let p = samplePixel(out, x: 100, y: 80)
            XCTAssertGreaterThan(min(p.r, p.g, p.b), 200, "\(kind) glyph should be white at the center")
        }
    }

    func testEveryStampKindRendersDistinctly() {
        let base = solidImage(CGSize(width: 200, height: 200), color: (1, 1, 1))
        let hashes = StampKind.allCases.map { pixelHash(Renderer.flatten(stampDoc($0), baseImage: base, scale: 1)!) }
        XCTAssertEqual(Set(hashes).count, StampKind.allCases.count)
    }

    func testStampTailFollowsPointerAngle() {
        let base = solidImage(CGSize(width: 200, height: 200), color: (0, 0, 0))
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 200, height: 200))
        doc.add(.stamp(StampElement(center: CGPoint(x: 100, y: 100), radius: 40, kind: .heart, color: .red,
                                    pointerAngle: 0)))   // points right
        let out = Renderer.flatten(doc, baseImage: base, scale: 1)!
        let right = samplePixel(out, x: 160, y: 100)
        XCTAssertGreaterThan(right.r, 180)
        let below = samplePixel(out, x: 100, y: 160)
        XCTAssertLessThan(below.r, 40, "nothing drawn below when the tail points right")
    }

    // MARK: - Pen

    private func penDoc(opacity: CGFloat, color: RGBAColor = .yellow) -> Document {
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 200, height: 100))
        doc.add(.pen(PenElement(points: [CGPoint(x: 20, y: 50), CGPoint(x: 100, y: 50), CGPoint(x: 180, y: 50)],
                                color: color, width: 12, opacity: opacity)))
        return doc
    }

    func testOpaquePenPaintsItsColor() {
        let base = solidImage(CGSize(width: 200, height: 100), color: (1, 1, 1))
        let out = Renderer.flatten(penDoc(opacity: 1), baseImage: base, scale: 1)!
        let p = samplePixel(out, x: 100, y: 50)
        XCTAssertGreaterThan(p.r, 240); XCTAssertLessThan(p.b, 20)
    }

    /// Half opacity over white lands halfway between white and the color.
    func testHighlighterOpacityBlendsWithTheBase() {
        let base = solidImage(CGSize(width: 200, height: 100), color: (1, 1, 1))
        let out = Renderer.flatten(penDoc(opacity: 0.5), baseImage: base, scale: 1)!
        let p = samplePixel(out, x: 100, y: 50)
        XCTAssertGreaterThan(p.r, 240)
        XCTAssertEqual(p.b, 128, accuracy: 12, "blue channel should be about half of white")
        XCTAssertEqual(samplePixel(out, x: 100, y: 80).b, 255, "off the stroke stays white")
    }

    /// A self-crossing translucent stroke must not darken where it overlaps.
    func testTranslucentStrokeDoesNotDoubleUpOnSelfOverlap() {
        let base = solidImage(CGSize(width: 200, height: 100), color: (1, 1, 1))
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 200, height: 100))
        doc.add(.pen(PenElement(points: [CGPoint(x: 20, y: 50), CGPoint(x: 180, y: 50), CGPoint(x: 20, y: 50)],
                                color: .yellow, width: 12, opacity: 0.5)))
        let out = Renderer.flatten(doc, baseImage: base, scale: 1)!
        XCTAssertEqual(samplePixel(out, x: 100, y: 50).b, 128, accuracy: 12)
    }

    func testSinglePointPenDrawsADot() {
        let base = solidImage(CGSize(width: 100, height: 100), color: (1, 1, 1))
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 100, height: 100))
        doc.add(.pen(PenElement(points: [CGPoint(x: 50, y: 50)], color: .red, width: 10, opacity: 1)))
        let out = Renderer.flatten(doc, baseImage: base, scale: 1)!
        XCTAssertLessThan(samplePixel(out, x: 50, y: 50).g, 100)
    }

    // MARK: - Redaction render cache

    /// Per-pixel gradient: unlike a solid or two-band image, every pixelate
    /// block size produces distinct output (a straight color boundary can
    /// align with the block grid and pixellate back to itself).
    private func gradientImage(_ size: CGSize) -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        var buf = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                buf[i] = UInt8((x * 7) % 256)
                buf[i + 1] = UInt8((y * 13) % 256)
                buf[i + 2] = UInt8((x + y) % 256)
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func testRedactionRepeatFlattenIsStable() {
        let base = gradientImage(CGSize(width: 100, height: 100))
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 100, height: 100))
        doc.add(.pixelate(RedactionElement(rect: CGRect(x: 20, y: 20, width: 60, height: 60), amount: 12)))
        let first = Renderer.flatten(doc, baseImage: base, scale: 1)!
        let second = Renderer.flatten(doc, baseImage: base, scale: 1)!
        XCTAssertEqual(pixelHash(first), pixelHash(second),
                       "a cached redaction must blit the same pixels a fresh render produces")
    }

    func testRedactionAmountChangeChangesPixels() {
        let base = gradientImage(CGSize(width: 100, height: 100))
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 100, height: 100))
        doc.add(.pixelate(RedactionElement(rect: CGRect(x: 20, y: 20, width: 60, height: 60), amount: 6)))
        let fine = Renderer.flatten(doc, baseImage: base, scale: 1)!
        doc.elements[0].pixelateAmount = 34
        let coarse = Renderer.flatten(doc, baseImage: base, scale: 1)!
        XCTAssertNotEqual(pixelHash(fine), pixelHash(coarse),
                          "a changed amount must not be served stale pixels from the cache")
    }

    func testRedactionFollowsBaseImageSwap() {
        let size = CGSize(width: 100, height: 100)
        var doc = Document(baseImage: .pngData(Data()), canvasSize: size)
        doc.add(.pixelate(RedactionElement(rect: CGRect(x: 20, y: 20, width: 60, height: 60), amount: 12)))
        _ = Renderer.flatten(doc, baseImage: solidImage(size, color: (1, 0, 0)), scale: 1)!
        let out = Renderer.flatten(doc, baseImage: solidImage(size, color: (0, 0, 1)), scale: 1)!
        let px = samplePixel(out, x: 50, y: 50)
        XCTAssertGreaterThan(px.b, 200, "a new base image must not be served the old image's pixels")
        XCTAssertLessThan(px.r, 50)
    }

    // MARK: - Export bounds

    func testFlattenExpandToFitExpandsCanvas() {
        let base = solidImage(CGSize(width: 50, height: 50), color: (0, 0, 1))
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 50, height: 50))
        doc.add(.arrow(SegmentElement(start: CGPoint(x: 40, y: 25),
                                      end: CGPoint(x: 100, y: 25), width: 6)))
        let out = Renderer.flatten(doc, baseImage: base, scale: 1, bounds: .expandToFit)!
        XCTAssertGreaterThan(out.width, 50)
    }

    func testFlattenExpandToFitFillsWhiteBackground() {
        let base = solidImage(CGSize(width: 50, height: 50), color: (0, 0, 1))
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 50, height: 50))
        doc.add(.arrow(SegmentElement(start: CGPoint(x: 40, y: 25),
                                      end: CGPoint(x: 100, y: 25), width: 6)))
        let out = Renderer.flatten(doc, baseImage: base, scale: 1, bounds: .expandToFit)!
        let px = samplePixel(out, x: out.width - 1, y: 1)
        XCTAssertGreaterThan(px.r, 240)
        XCTAssertGreaterThan(px.g, 240)
        XCTAssertGreaterThan(px.b, 240)
    }

    func testFlattenClipToImagePreservesSize() {
        let base = solidImage(CGSize(width: 50, height: 50), color: (0, 0, 1))
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 50, height: 50))
        doc.add(.arrow(SegmentElement(start: CGPoint(x: 40, y: 25),
                                      end: CGPoint(x: 100, y: 25), width: 6)))
        let out = Renderer.flatten(doc, baseImage: base, scale: 1, bounds: .clipToImage)!
        XCTAssertEqual(out.width, 50)
        XCTAssertEqual(out.height, 50)
    }

    func testFlattenDefaultBoundsClips() {
        let base = solidImage(CGSize(width: 50, height: 50), color: (0, 0, 1))
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 50, height: 50))
        doc.add(.arrow(SegmentElement(start: CGPoint(x: 40, y: 25),
                                      end: CGPoint(x: 100, y: 25), width: 6)))
        let out = Renderer.flatten(doc, baseImage: base, scale: 1)!
        XCTAssertEqual(out.width, 50, "default bounds should clip")
    }

    func testSuggestedSizeGrowsWithContent() {
        let short = TextElement(origin: .zero, size: CGSize(width: 220, height: 44), string: "Hi")
        let long = TextElement(origin: .zero, size: CGSize(width: 220, height: 44),
                               string: String(repeating: "wrap me around ", count: 10))
        let shortSize = Renderer.suggestedSize(for: short)
        let longSize = Renderer.suggestedSize(for: long)
        XCTAssertEqual(shortSize.width, 220, "width is the wrap constraint and must not change")
        XCTAssertEqual(longSize.width, 220)
        XCTAssertGreaterThan(longSize.height, shortSize.height, "long text needs more lines")
        XCTAssertGreaterThan(longSize.height, 44, "overflowing text must outgrow the initial box")
    }

    func testSuggestedSizeForEmptyStringShrinksToMinimum() {
        let element = TextElement(origin: .zero, size: CGSize(width: 220, height: 300), string: "")
        let size = Renderer.suggestedSize(for: element)
        XCTAssertEqual(size.width, 220, "width is the wrap constraint and must not change")
        XCTAssertEqual(size.height, element.font.pointSize + 8,
                       "empty text should shrink back to the one-line minimum")
    }

    /// CoreText drops lines that don't fit the frame rect, so an overflowing
    /// string in the initial 220x44 box rendered nothing. After resizing to
    /// `suggestedSize`, the wrapped lines below the first must be visible.
    func testOverflowingTextRendersAfterResize() {
        let canvas = CGSize(width: 400, height: 400)
        let base = solidImage(canvas, color: (1, 1, 1))
        var element = TextElement(origin: CGPoint(x: 10, y: 10),
                                  size: CGSize(width: 220, height: 44),
                                  string: String(repeating: "wrap me around ", count: 10),
                                  color: RGBAColor(r: 1, g: 0, b: 0))
        element.size = Renderer.suggestedSize(for: element)

        var doc = Document(baseImage: .pngData(Data()), canvasSize: canvas)
        doc.add(.text(element))
        let out = Renderer.flatten(doc, baseImage: base, scale: 1)!

        let w = out.width, h = out.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(out, in: CGRect(x: 0, y: 0, width: w, height: h))

        func hasRedPixel(rows: Range<Int>) -> Bool {
            for y in rows {
                for x in 10..<230 {
                    let i = (y * w + x) * 4
                    if buf[i] > 180 && buf[i + 1] < 100 && buf[i + 2] < 100 { return true }
                }
            }
            return false
        }
        XCTAssertTrue(hasRedPixel(rows: 10..<54), "first line should render")
        XCTAssertTrue(hasRedPixel(rows: 54..<(10 + Int(element.size.height))),
                      "wrapped lines beyond the original 44pt box should render")
    }

    private func checkerImage(_ size: Int) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        for y in 0..<size where y % 2 == 0 {
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: y, width: size, height: 1))
        }
        return ctx.makeImage()!
    }

    private func samplePixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let i = (y * w + x) * 4
        return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
    }

    private func pixelHash(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        return data.reduce(into: Hasher()) { $0.combine($1) }.finalize()
    }
}
