import XCTest
import CoreGraphics
@testable import AnnotationModel

/// The loupe: a rect-backed element that grows around its center while
/// being created, resizes by corners afterwards, and clamps its zoom.
final class MagnifierTests: XCTestCase {

    private let acc: CGFloat = 0.001
    private let canvas = DefaultSizeScale.referenceCanvasSize

    func testPlainClickPlacesADefaultSquareLoupeCenteredOnTheClick() {
        let p = CGPoint(x: 300, y: 200)
        let placed = Annotation.magnifier(MagnifierElement(rect: CGRect(corner: p, p)))
            .applyingDefaultInitialSize(canvasSize: canvas)
        guard case .magnifier(let m) = placed else { return XCTFail("kind changed") }
        XCTAssertEqual(m.rect.width, DefaultInitialSize.magnifierSide, accuracy: acc)
        XCTAssertEqual(m.rect.height, DefaultInitialSize.magnifierSide, accuracy: acc)
        XCTAssertEqual(m.center.x, p.x, accuracy: acc)
        XCTAssertEqual(m.center.y, p.y, accuracy: acc)
    }

    func testCreationDragGrowsAroundTheCenter() {
        let p = CGPoint(x: 300, y: 200)
        var m = MagnifierElement(rect: CGRect(corner: p, p))
        m.moveHandle(.end, to: CGPoint(x: 330, y: 240))   // 50 away
        XCTAssertEqual(m.rect, CGRect(x: 250, y: 150, width: 100, height: 100))
        XCTAssertEqual(m.center, p)
        // A drag that comes back in shrinks it again around the same center.
        m.moveHandle(.end, to: CGPoint(x: 310, y: 200))
        XCTAssertEqual(m.rect, CGRect(x: 290, y: 190, width: 20, height: 20))
    }

    func testCornerHandlesResizeFreelyAfterwards() {
        var m = MagnifierElement(rect: CGRect(x: 250, y: 150, width: 100, height: 100))
        XCTAssertEqual(Set(m.handles().map(\.role)), [.topLeft, .topRight, .bottomLeft, .bottomRight])
        m.moveHandle(.bottomRight, to: CGPoint(x: 450, y: 250))
        XCTAssertEqual(m.rect, CGRect(x: 250, y: 150, width: 200, height: 100), "an oval now")
    }

    func testZoomIsClamped() {
        var m = MagnifierElement(rect: .zero, zoom: 100)
        XCTAssertEqual(m.zoom, MagnifierElement.zoomRange.upperBound)
        m.zoom = 0.1
        XCTAssertEqual(m.zoom, MagnifierElement.zoomRange.lowerBound)
        var a = Annotation.magnifier(m)
        a.magnifierZoom = 3
        XCTAssertEqual(a.magnifierZoom, 3)
        a.magnifierShape = .square
        XCTAssertEqual(a.magnifierShape, .square)
        XCTAssertEqual(a.strokeWidth, 6)
        XCTAssertEqual(a.color, .red)
        a.strokeWidth = 10
        a.color = .blue
        guard case .magnifier(let back) = a else { return XCTFail("kind changed") }
        XCTAssertEqual(back.width, 10)
        XCTAssertEqual(back.color, .blue)
    }

    func testAccessorsAreNilForOtherKinds() {
        var text = Annotation.text(TextElement(origin: .zero))
        XCTAssertNil(text.magnifierZoom)
        XCTAssertNil(text.magnifierShape)
        text.magnifierZoom = 3
        XCTAssertNil(text.magnifierZoom)
    }

    func testCodableRoundTrip() throws {
        let m = MagnifierElement(rect: CGRect(x: 1, y: 2, width: 30, height: 40), shape: .square, zoom: 3.5,
                                 color: .green, width: 4)
        let data = try JSONEncoder().encode(Annotation.magnifier(m))
        XCTAssertEqual(try JSONDecoder().decode(Annotation.self, from: data), .magnifier(m))
    }

    func testHitTestAndBoundsIncludeTheRing() {
        let m = MagnifierElement(rect: CGRect(x: 100, y: 100, width: 100, height: 100), width: 8)
        XCTAssertTrue(m.hitTest(CGPoint(x: 150, y: 150), tolerance: 0))
        XCTAssertFalse(m.hitTest(CGPoint(x: 300, y: 300), tolerance: 0))
        XCTAssertEqual(m.boundingBox(), CGRect(x: 92, y: 92, width: 116, height: 116))
        XCTAssertEqual(m.cornerRadius, 0)
        var square = m
        square.shape = .square
        XCTAssertGreaterThan(square.cornerRadius, 0)
    }
}
