import XCTest
import AnnotationModel
import AnnotationRender

final class AnnotationStyleRenderTests: XCTestCase {
    private func render(_ element: Annotation, scale: CGFloat = 1) throws -> CGImage {
        let document = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 180, height: 140), elements: [element])
        return try XCTUnwrap(Renderer.flatten(document, baseImage: nil, scale: scale))
    }

    private func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        let data = image.dataProvider!.data! as Data
        return data[y * image.bytesPerRow + x * 4 + 3]
    }

    func testHighlightHasUniformTranslucencyAndNoBorderOrShadow() throws {
        var shape = ShapeElement(rect: CGRect(x: 30, y: 30, width: 100, height: 60), color: .yellow, width: 10)
        shape.highlightOpacity = 0.3
        for scale: CGFloat in [1, 2] {
            let image = try render(.rectangle(shape), scale: scale)
            let s = Int(scale)
            XCTAssertEqual(Int(alpha(image, x: 60 * s, y: 60 * s)), 77, accuracy: 1)
            XCTAssertEqual(alpha(image, x: 31 * s, y: 31 * s), alpha(image, x: 60 * s, y: 60 * s))
            XCTAssertEqual(alpha(image, x: 132 * s, y: 92 * s), 0)
        }
    }

    func testRoundedCornersAreTransparentAndShadowToggleChangesPixels() throws {
        var shape = ShapeElement(rect: CGRect(x: 30, y: 30, width: 100, height: 60), width: 4, fill: .red)
        shape.cornerRadius = 25
        shape.shadow = false
        let flat = try render(.rectangle(shape))
        XCTAssertEqual(alpha(flat, x: 30, y: 30), 0)
        XCTAssertEqual(alpha(flat, x: 70, y: 60), 255)
        shape.shadow = true
        let shadowed = try render(.rectangle(shape))
        XCTAssertNotEqual(flat.dataProvider!.data! as Data, shadowed.dataProvider!.data! as Data)
    }

    func testEachSupportedShadowOverrideAffectsRendering() throws {
        let box = CGRect(x: 30, y: 30, width: 100, height: 60)
        var callout = TextElement(origin: box.origin, size: box.size, string: "Test")
        callout.makeCallout(.speech)
        let elements: [Annotation] = [
            .arrow(SegmentElement(start: box.origin, end: CGPoint(x: 100, y: 70))),
            .line(SegmentElement(start: box.origin, end: CGPoint(x: 100, y: 70))),
            .ellipse(ShapeElement(rect: box)), .text(callout),
            .text(TextElement(origin: box.origin, size: box.size, string: "Test")),
            .stamp(StampElement(center: CGPoint(x: 70, y: 60), radius: 20)),
        ]
        for var element in elements {
            element.shadowEnabled = false
            let flat = try render(element)
            element.shadowEnabled = true
            let shadowed = try render(element)
            XCTAssertNotEqual(flat.dataProvider!.data! as Data, shadowed.dataProvider!.data! as Data, element.kindName)
        }
    }
}
