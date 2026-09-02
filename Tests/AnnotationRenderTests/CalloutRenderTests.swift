import XCTest
import CoreGraphics
@testable import AnnotationModel
@testable import AnnotationRender

/// Pixel checks for callout bodies, tails, ink, and text alignment.
final class CalloutRenderTests: XCTestCase {

    private let canvas = CGSize(width: 300, height: 200)

    private func solidImage(_ size: CGSize, color: (Double, Double, Double)) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
        return ctx.makeImage()!
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    private func sample(_ buf: [UInt8], width: Int, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4
        return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
    }

    /// Renders a callout over a solid blue image.
    private func render(_ text: TextElement) -> [UInt8] {
        let base = solidImage(canvas, color: (0, 0, 1))
        var doc = Document(baseImage: .pngData(Data()), canvasSize: canvas)
        doc.add(.text(text))
        return pixels(Renderer.flatten(doc, baseImage: base, scale: 1)!)
    }

    private func callout(_ shape: CalloutShape, string: String = "", fill: RGBAColor = .red,
                         ink: RGBAColor = .white, alignment: LineAlignment = .left) -> TextElement {
        var t = TextElement(origin: CGPoint(x: 60, y: 40), size: CGSize(width: 160, height: 80),
                            string: string, font: FontSpec(pointSize: 40), color: fill, style: .plain,
                            outlineColor: ink, alignment: alignment,
                            container: TextContainer(shape: shape, tailTip: CGPoint(x: 280, y: 80)))
        // Like the editor: the box is tall enough for its text.
        if !string.isEmpty { t.size = Renderer.suggestedSize(for: t) }
        return t
    }

    func testSpeechBodyIsFilledWithTheColorAndEdgedWithTheInk() {
        let buf = render(callout(.speech))
        let w = Int(canvas.width)
        let center = sample(buf, width: w, x: 140, y: 80)
        XCTAssertGreaterThan(center.r, 200, "body is filled with the palette color")
        XCTAssertLessThan(center.b, 80)

        let edge = sample(buf, width: w, x: 140, y: 40)
        XCTAssertGreaterThan(min(edge.r, edge.g, edge.b), 180, "border is drawn in the ink color")

        let outside = sample(buf, width: w, x: 140, y: 170)
        XCTAssertGreaterThan(outside.b, 200, "the base image shows outside the bubble")
        XCTAssertLessThan(outside.r, 60)
    }

    func testSpeechTailIsFilledOutToTheTip() {
        let buf = render(callout(.speech))
        let w = Int(canvas.width)
        // Halfway from the right edge (x 220) to the tip (x 280), on the axis.
        let mid = sample(buf, width: w, x: 250, y: 80)
        XCTAssertGreaterThan(mid.r, 200, "tail interior carries the fill")
        XCTAssertLessThan(mid.b, 80)
        // Off the tail's axis it is still the base image.
        let beside = sample(buf, width: w, x: 250, y: 130)
        XCTAssertGreaterThan(beside.b, 200)
    }

    func testTipInsideTheBoxDrawsNoTail() {
        var t = callout(.speech)
        t.container?.tailTip = CGPoint(x: 140, y: 80)
        let buf = render(t)
        let w = Int(canvas.width)
        let rightOfBox = sample(buf, width: w, x: 250, y: 80)
        XCTAssertGreaterThan(rightOfBox.b, 200)
    }

    func testThoughtCloudFillsTheBodyAndTrailsCirclesTowardTheTip() {
        let buf = render(callout(.thought))
        let w = Int(canvas.width)
        let center = sample(buf, width: w, x: 140, y: 80)
        XCTAssertGreaterThan(center.r, 200)
        // A few pixels above the box's top edge, the scallops cover part of
        // the row (the cusps between bumps leave gaps, so scan the row).
        let bulged = (70..<210).contains { sample(buf, width: w, x: $0, y: 36).b < 120 }
        XCTAssertTrue(bulged, "the scalloped edge bulges past the box edge")
        let cusp = sample(buf, width: w, x: 140, y: 30)
        XCTAssertGreaterThan(cusp.b, 200, "the bulge is bounded")
        // First trailing circle sits just off the right edge on the tail axis.
        let firstCircle = sample(buf, width: w, x: 235, y: 80)
        XCTAssertGreaterThan(firstCircle.r, 150)
        XCTAssertLessThan(firstCircle.b, 120)
    }

    // MARK: Text

    /// Columns (within the box interior) holding dark ink.
    private func inkColumns(_ buf: [UInt8], in rect: CGRect) -> ClosedRange<Int>? {
        let w = Int(canvas.width)
        var minX = Int.max, maxX = Int.min
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let p = sample(buf, width: w, x: x, y: y)
                if max(p.r, p.g, p.b) < 100 {
                    minX = min(minX, x); maxX = max(maxX, x)
                }
            }
        }
        return minX <= maxX ? minX...maxX : nil
    }

    func testCalloutTextIsDrawnInTheInkColor() {
        // White bubble, black ink: the glyph must be black, inside the box.
        let t = callout(.speech, string: "I", fill: .white, ink: .black, alignment: .center)
        let buf = render(t)
        let interior = t.textRect.insetBy(dx: 4, dy: 4)
        let ink = inkColumns(buf, in: interior)
        XCTAssertNotNil(ink, "glyph pixels are drawn in black")
        XCTAssertTrue(interior.contains(CGPoint(x: CGFloat(ink?.lowerBound ?? 0), y: interior.midY)))
    }

    func testAlignmentMovesTheLineWithinTheBox() {
        func inkRange(_ alignment: LineAlignment) -> ClosedRange<Int> {
            let t = callout(.speech, string: "I", fill: .white, ink: .black, alignment: alignment)
            let buf = render(t)
            return inkColumns(buf, in: t.textRect.insetBy(dx: 4, dy: 4)) ?? 0...0
        }
        let box = callout(.speech).textRect
        let left = inkRange(.left), center = inkRange(.center), right = inkRange(.right)
        XCTAssertLessThan(CGFloat(left.upperBound), box.minX + box.width * 0.3)
        XCTAssertGreaterThan(CGFloat(right.lowerBound), box.maxX - box.width * 0.3)
        XCTAssertGreaterThan(CGFloat(center.lowerBound), box.minX + box.width * 0.3)
        XCTAssertLessThan(CGFloat(center.upperBound), box.maxX - box.width * 0.3)
    }

    func testPlainTextHonorsAlignmentToo() {
        func inkRange(_ alignment: LineAlignment) -> ClosedRange<Int> {
            var t = TextElement(origin: CGPoint(x: 20, y: 20), size: CGSize(width: 260, height: 60),
                                string: "I", font: FontSpec(pointSize: 40), color: .black, style: .plain)
            t.alignment = alignment
            let base = solidImage(canvas, color: (1, 1, 1))
            var doc = Document(baseImage: .pngData(Data()), canvasSize: canvas)
            doc.add(.text(t))
            let buf = pixels(Renderer.flatten(doc, baseImage: base, scale: 1)!)
            return inkColumns(buf, in: t.rect) ?? 0...0
        }
        XCTAssertLessThan(inkRange(.left).upperBound, 100)
        XCTAssertGreaterThan(inkRange(.right).lowerBound, 200)
        let center = inkRange(.center)
        XCTAssertGreaterThan(center.lowerBound, 110)
        XCTAssertLessThan(center.upperBound, 190)
    }

    func testSuggestedSizeAddsThePaddingAroundTheText() {
        var plain = TextElement(origin: .zero, size: CGSize(width: 200, height: 10),
                                string: "hello", font: FontSpec(pointSize: 40))
        plain.size = Renderer.suggestedSize(for: plain)
        var bubble = plain
        bubble.makeCallout(.speech)
        let measured = Renderer.suggestedSize(for: bubble)
        XCTAssertEqual(measured.width, bubble.size.width)
        XCTAssertEqual(measured.height, plain.size.height + 2 * bubble.padding, accuracy: 0.5)
    }
}
