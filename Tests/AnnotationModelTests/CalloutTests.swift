import XCTest
import CoreGraphics
@testable import AnnotationModel

/// A callout is a text box with a container: a speech bubble or thought
/// cloud whose tail points at an absolute image-space tip. The tail leaves
/// from the edge of the box nearest the tip and disappears when the tip is
/// inside the box.
final class CalloutTests: XCTestCase {

    private let acc: CGFloat = 0.001
    private let rect = CGRect(x: 100, y: 100, width: 200, height: 100)

    private func callout(tip: CGPoint, shape: CalloutShape = .speech) -> TextElement {
        var t = TextElement(origin: rect.origin, size: rect.size, string: "hi",
                            font: FontSpec(pointSize: 20), color: .red, outlineColor: .white)
        t.container = TextContainer(shape: shape, tailTip: tip)
        return t
    }

    // MARK: Tail geometry

    func testTailLeavesFromTheEdgeNearestTheTip() {
        let right = callout(tip: CGPoint(x: 400, y: 150)).calloutTail()
        XCTAssertEqual(right?.edge, .right)
        XCTAssertEqual(right?.base.x ?? 0, rect.maxX, accuracy: acc)
        XCTAssertEqual(right?.base.y ?? 0, 150, accuracy: acc)

        let left = callout(tip: CGPoint(x: 10, y: 150)).calloutTail()
        XCTAssertEqual(left?.edge, .left)
        XCTAssertEqual(left?.base.x ?? 0, rect.minX, accuracy: acc)

        let top = callout(tip: CGPoint(x: 150, y: 20)).calloutTail()
        XCTAssertEqual(top?.edge, .top)
        XCTAssertEqual(top?.base.y ?? 0, rect.minY, accuracy: acc)
        XCTAssertEqual(top?.base.x ?? 0, 150, accuracy: acc)

        let bottom = callout(tip: CGPoint(x: 150, y: 300)).calloutTail()
        XCTAssertEqual(bottom?.edge, .bottom)
        XCTAssertEqual(bottom?.base.y ?? 0, rect.maxY, accuracy: acc)
    }

    func testTailBaseStaysClearOfTheCorners() {
        // Tip far below and far to the right of the bottom-right corner, but
        // more below than right: the tail leaves the bottom edge, and its
        // base is pulled in from the corner so the triangle meets a flat edge.
        let t = callout(tip: CGPoint(x: 320, y: 400))
        let tail = t.calloutTail()
        XCTAssertEqual(tail?.edge, .bottom)
        XCTAssertLessThan(tail?.right.x ?? .infinity, rect.maxX - t.cornerRadius + acc)
        XCTAssertGreaterThan(tail?.left.x ?? 0, rect.minX)
        // Base points straddle the base center along the edge.
        XCTAssertEqual(tail?.left.y ?? 0, rect.maxY, accuracy: acc)
        XCTAssertEqual(tail?.right.y ?? 0, rect.maxY, accuracy: acc)
        XCTAssertLessThan(tail?.left.x ?? 0, tail?.base.x ?? 0)
        XCTAssertGreaterThan(tail?.right.x ?? 0, tail?.base.x ?? 0)
    }

    func testTipInsideTheBoxHidesTheTail() {
        XCTAssertNil(callout(tip: CGPoint(x: 150, y: 150)).calloutTail())
        XCTAssertNil(callout(tip: CGPoint(x: 300, y: 150)).calloutTail(), "on the edge counts as inside")
    }

    func testPlainTextHasNoTail() {
        let t = TextElement(origin: rect.origin, size: rect.size, string: "hi")
        XCTAssertNil(t.container)
        XCTAssertNil(t.calloutTail())
        XCTAssertEqual(t.padding, 0)
        XCTAssertEqual(t.textRect, rect)
    }

    // MARK: Layout

    func testCalloutTextRectIsInsetByThePadding() {
        let t = callout(tip: CGPoint(x: 400, y: 150))
        XCTAssertGreaterThan(t.padding, 0)
        XCTAssertEqual(t.textRect, rect.insetBy(dx: t.padding, dy: t.padding))
    }

    func testBoundingBoxCoversTheTailTip() {
        let tip = CGPoint(x: 450, y: 30)
        let box = callout(tip: tip).boundingBox()
        XCTAssertTrue(box.contains(tip))
        XCTAssertTrue(box.contains(rect))
    }

    // MARK: Handles and hit testing

    func testHandlesIncludeTheTailTipAndKeepTheTextHandles() {
        let tip = CGPoint(x: 400, y: 150)
        let handles = callout(tip: tip).handles()
        XCTAssertEqual(Set(handles.map(\.role)), [.left, .right, .bottomRight, .end])
        XCTAssertEqual(handles.first { $0.role == .end }?.position, tip)
    }

    func testTailHandleMovesTheTipOnly() {
        var t = callout(tip: CGPoint(x: 400, y: 150))
        t.moveHandle(.end, to: CGPoint(x: 50, y: 400))
        XCTAssertEqual(t.container?.tailTip, CGPoint(x: 50, y: 400))
        XCTAssertEqual(t.rect, rect, "dragging the tail must not move the box")
    }

    func testTranslateMovesBoxAndTipTogether() {
        var t = callout(tip: CGPoint(x: 400, y: 150))
        t.translate(by: CGVector(dx: 10, dy: -20))
        XCTAssertEqual(t.rect, rect.offsetBy(dx: 10, dy: -20))
        XCTAssertEqual(t.container?.tailTip, CGPoint(x: 410, y: 130))
    }

    func testWidthHandleRespectsThePaddedMinimum() {
        var t = callout(tip: CGPoint(x: 400, y: 150))
        t.moveHandle(.right, to: CGPoint(x: rect.minX + 1, y: 150))
        XCTAssertEqual(t.size.width, TextElement.minimumWidth + 2 * t.padding, accuracy: acc)
        XCTAssertGreaterThanOrEqual(t.textRect.width, TextElement.minimumWidth - acc)
    }

    func testHitTestCoversBodyAndTailButNotFarAway() {
        let t = callout(tip: CGPoint(x: 400, y: 150))
        XCTAssertTrue(t.hitTest(CGPoint(x: 200, y: 150), tolerance: 0), "inside the body")
        XCTAssertTrue(t.hitTest(CGPoint(x: 350, y: 150), tolerance: 0), "on the tail")
        XCTAssertFalse(t.hitTest(CGPoint(x: 350, y: 250), tolerance: 0))
        XCTAssertFalse(t.hitTest(CGPoint(x: 50, y: 50), tolerance: 0))
    }

    // MARK: Codable

    func testDecodingOlderTextDefaultsAlignmentAndContainer() throws {
        let legacy = """
        {"id":"9A7B4B3C-2A9B-4E4A-9C1B-0C0D9E0F1A2B","origin":[10,20],"size":[100,30],
         "string":"old","font":{"family":"Helvetica Neue","pointSize":28,"bold":true},
         "color":{"r":1,"g":0,"b":0,"a":1},"style":"shadow","outlineColor":{"r":1,"g":1,"b":1,"a":1}}
        """
        let t = try JSONDecoder().decode(TextElement.self, from: Data(legacy.utf8))
        XCTAssertEqual(t.alignment, .left)
        XCTAssertNil(t.container)
        XCTAssertEqual(t.string, "old")
    }

    func testCalloutRoundTripsThroughJSON() throws {
        var t = callout(tip: CGPoint(x: 400, y: 150), shape: .thought)
        t.alignment = .center
        let data = try JSONEncoder().encode(Annotation.text(t))
        let back = try JSONDecoder().decode(Annotation.self, from: data)
        XCTAssertEqual(back, .text(t))
    }

    // MARK: Annotation accessors

    func testAnnotationAccessorsForAlignmentAndShape() {
        var a = Annotation.text(callout(tip: CGPoint(x: 400, y: 150)))
        XCTAssertEqual(a.textAlignment, .left)
        XCTAssertEqual(a.calloutShape, .speech)
        a.textAlignment = .right
        a.calloutShape = .thought
        guard case .text(let t) = a else { return XCTFail("kind changed") }
        XCTAssertEqual(t.alignment, .right)
        XCTAssertEqual(t.container?.shape, .thought)

        var plain = Annotation.text(TextElement(origin: .zero))
        XCTAssertNil(plain.calloutShape, "plain text has no bubble shape")
        plain.calloutShape = .speech
        guard case .text(let still) = plain else { return XCTFail("kind changed") }
        XCTAssertNil(still.container, "setting a shape does not conjure a container")

        var arrow = Annotation.arrow(SegmentElement(start: .zero, end: .zero))
        XCTAssertNil(arrow.textAlignment)
        arrow.textAlignment = .center
        XCTAssertNil(arrow.textAlignment)
    }

    func testMakingCalloutFromTextPutsTheTailBelowLeft() throws {
        var t = TextElement(origin: rect.origin, size: rect.size, string: "hi")
        t.makeCallout(.speech)
        XCTAssertEqual(t.container?.shape, .speech)
        let tip = try XCTUnwrap(t.container?.tailTip)
        XCTAssertGreaterThan(tip.y, rect.maxY)
        XCTAssertLessThan(tip.x, rect.midX)
        XCTAssertNotNil(t.calloutTail())
        // Converting again keeps the tail where the user put it.
        t.container?.tailTip = CGPoint(x: 1, y: 1)
        t.makeCallout(.thought)
        XCTAssertEqual(t.container?.tailTip, CGPoint(x: 1, y: 1))
        XCTAssertEqual(t.container?.shape, .thought)
    }
}
