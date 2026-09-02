import XCTest
import CoreGraphics
@testable import AnnotationModel
@testable import AnnotationRender

/// Pixel checks for the loupe: magnified content, the ring, the shape, and
/// the guarantee that redactions stay redacted inside it.
final class MagnifierRenderTests: XCTestCase {

    private let canvas = CGSize(width: 200, height: 200)

    private func image(_ paint: (CGContext) -> Void) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        paint(ctx)
        return ctx.makeImage()!
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 200 * 200 * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &buf, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 200, height: 200))
        return buf
    }

    private func sample(_ buf: [UInt8], _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * 200 + x) * 4
        return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
    }

    private func render(_ elements: [Annotation], base: CGImage) -> [UInt8] {
        var doc = Document(baseImage: .pngData(Data()), canvasSize: canvas)
        for e in elements { doc.add(e) }
        return pixels(Renderer.flatten(doc, baseImage: base, scale: 1)!)
    }

    /// White base with a 4px black dot at the center (image rows are top-down
    /// in model space; the bitmap context is y-up, so flip when painting).
    private var dottedBase: CGImage {
        image { ctx in
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 98, y: 98, width: 4, height: 4))
        }
    }

    func testLoupeMagnifiesTheBaseAroundItsCenter() {
        let loupe = MagnifierElement(rect: CGRect(x: 60, y: 60, width: 80, height: 80), zoom: 4, color: .red, width: 6)
        let buf = render([.magnifier(loupe)], base: dottedBase)
        // The 4px dot is 16px across at 4x: (100, 106) is black inside the
        // loupe, though the base there is white.
        let magnified = sample(buf, 100, 106)
        XCTAssertLessThan(max(magnified.r, magnified.g, magnified.b), 60)
        let stillWhite = sample(buf, 100, 120)
        XCTAssertGreaterThan(min(stillWhite.r, stillWhite.g, stillWhite.b), 200)
        // The ring sits on the edge in the stroke color.
        let ring = sample(buf, 100, 60)
        XCTAssertGreaterThan(ring.r, 180)
        XCTAssertLessThan(ring.b, 90)
        // Outside the loupe the base is untouched.
        let outside = sample(buf, 100, 30)
        XCTAssertGreaterThan(min(outside.r, outside.g, outside.b), 200)
    }

    func testSquareLoupeCoversItsCornersAndCircleDoesNot() {
        // Left half red, right half blue; loupe center at x 120 with 4x zoom,
        // so (86, 70) shows base x ≈ 111 (blue) when inside the loupe and the
        // untouched base (red) when outside it.
        let split = image { ctx in
            ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
            ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 100, y: 0, width: 100, height: 200))
        }
        let rect = CGRect(x: 80, y: 60, width: 80, height: 80)
        let circle = render([.magnifier(MagnifierElement(rect: rect, shape: .circle, zoom: 4, width: 4))], base: split)
        let square = render([.magnifier(MagnifierElement(rect: rect, shape: .square, zoom: 4, width: 4))], base: split)
        XCTAssertGreaterThan(sample(circle, 86, 70).r, 180, "corner is outside the circle: base red")
        XCTAssertGreaterThan(sample(square, 86, 70).b, 180, "corner is inside the square: magnified blue")
    }

    func testRedactionsStayRedactedInsideTheLoupe() {
        // 1px checkerboard: pixelated it averages to gray; read raw it is
        // pure black or white.
        let checker = image { ctx in
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            for y in 0..<200 { for x in 0..<200 where (x + y) % 2 == 0 {
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            } }
        }
        let redaction = RedactionElement(rect: CGRect(x: 0, y: 0, width: 200, height: 200), amount: 20)
        let loupe = MagnifierElement(rect: CGRect(x: 60, y: 60, width: 80, height: 80), zoom: 3, width: 4)
        // Loupe below the redaction in z-order and above it: both must stay gray.
        for elements in [[Annotation.magnifier(loupe), .pixelate(redaction)], [.pixelate(redaction), .magnifier(loupe)]] {
            let buf = render(elements, base: checker)
            for (x, y) in [(100, 100), (90, 110), (110, 95)] {
                let p = sample(buf, x, y)
                XCTAssertGreaterThan(p.r, 60, "raw black leaked at \(x),\(y)")
                XCTAssertLessThan(p.r, 200, "raw white leaked at \(x),\(y)")
            }
        }
    }

    func testMissingBaseImageFillsTheLoupeGray() {
        var doc = Document(baseImage: .pngData(Data()), canvasSize: canvas)
        doc.add(.magnifier(MagnifierElement(rect: CGRect(x: 60, y: 60, width: 80, height: 80))))
        let buf = pixels(Renderer.flatten(doc, baseImage: nil, scale: 1)!)
        let p = sample(buf, 100, 100)
        XCTAssertGreaterThan(p.r, 100)
        XCTAssertLessThan(p.r, 160)
    }
}
