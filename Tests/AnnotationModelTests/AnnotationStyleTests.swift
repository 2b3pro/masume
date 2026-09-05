import XCTest
import AnnotationModel

final class AnnotationStyleTests: XCTestCase {
    func testLegacyShapesAndSegmentsKeepShadows() throws {
        let elements: [Annotation] = [
            .rectangle(ShapeElement(rect: CGRect(x: 10, y: 10, width: 100, height: 60))),
            .arrow(SegmentElement(start: .zero, end: CGPoint(x: 20, y: 30))),
            .text(TextElement(origin: .zero, string: "Title")),
            .stamp(StampElement(center: .zero)),
        ]
        let data = try JSONEncoder().encode(elements)
        XCTAssertFalse(try XCTUnwrap(String(data: data, encoding: .utf8)).contains("\"shadow\":"))
        let decoded = try JSONDecoder().decode([Annotation].self, from: data)
        XCTAssertTrue(decoded.allSatisfy { $0.shadowEnabled == true })
        XCTAssertEqual(decoded, elements)
    }

    func testOverridesRoundTripAndDuplicate() throws {
        var elements: [Annotation] = [
            .line(SegmentElement(start: .zero, end: CGPoint(x: 30, y: 30))),
            .ellipse(ShapeElement(rect: CGRect(x: 10, y: 10, width: 100, height: 60))),
            .text(TextElement(origin: .zero, string: "Title")),
            .stamp(StampElement(center: CGPoint(x: 30, y: 40))),
        ]
        for i in elements.indices { elements[i].shadowEnabled = false }
        let decoded = try JSONDecoder().decode([Annotation].self, from: JSONEncoder().encode(elements))
        XCTAssertEqual(decoded, elements)
        XCTAssertTrue(decoded.allSatisfy { $0.duplicated().shadowEnabled == false })
    }

    func testRoundedCornerHitTestingAndRadiusClamp() {
        var shape = ShapeElement(rect: CGRect(x: 20, y: 20, width: 100, height: 100), width: 2, fill: .red)
        shape.cornerRadius = 500
        XCTAssertFalse(shape.hitTest(CGPoint(x: 20, y: 20), tolerance: 1))
        XCTAssertTrue(shape.hitTest(CGPoint(x: 70, y: 70), tolerance: 1))
        XCTAssertTrue(shape.hitTest(CGPoint(x: 70, y: 20), tolerance: 1))
        shape.fill = nil
        XCTAssertFalse(shape.hitTest(CGPoint(x: 70, y: 70), tolerance: 1))
    }

    func testHighlightIsFilledForSelectionAndRetainsOpacity() throws {
        var shape = ShapeElement(rect: CGRect(x: 10, y: 10, width: 100, height: 40))
        shape.highlightOpacity = 0.25
        var element = Annotation.rectangle(shape)
        XCTAssertEqual(element.shadowEnabled, false)
        XCTAssertTrue(element.hitTest(CGPoint(x: 60, y: 30), tolerance: 1))
        element.opacity = 0.4
        XCTAssertEqual(element.opacity, 0.4)
        XCTAssertEqual(try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(element)), element)
    }
}
