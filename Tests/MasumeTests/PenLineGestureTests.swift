import XCTest
import AppKit
import AnnotationModel
@testable import Masume

/// Drives `CanvasNSView` with synthetic mouse events to cover the pen's
/// Shift-click straight-line gesture. The view has no window, so event
/// locations are view coordinates; with 1:1 zoom on a 200×200 image in a
/// 200×200 view, model y = 200 − view y.
@MainActor
final class PenLineGestureTests: XCTestCase {

    private func makeView() -> (CanvasNSView, CanvasController) {
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore())
        controller.loadImage(ctx.makeImage()!)
        controller.zoomMode = .percent(1)
        controller.tool = .pen
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.controller = controller
        return (view, controller)
    }

    private func event(_ type: NSEvent.EventType, at p: CGPoint, shift: Bool = false) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func points(_ controller: CanvasController) -> [CGPoint]? {
        guard case .pen(let pen)? = controller.document?.elements.first else { return nil }
        return pen.points
    }

    func testTwoShiftClicksMakeAStraightLineWhoseEndFollowsTheDrag() {
        let (view, controller) = makeView()
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 50, y: 150), shift: true))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 50, y: 150), shift: true))
        XCTAssertEqual(controller.document?.elements.count, 0, "first Shift-click only sets the anchor")

        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 150, y: 150), shift: true))
        XCTAssertEqual(controller.document?.elements.count, 1)
        XCTAssertEqual(points(controller), [CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 50)])

        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 150, y: 50), shift: true))
        XCTAssertEqual(points(controller), [CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 150)],
                       "the end point follows the pointer, the anchor stays")
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 150, y: 50), shift: true))
        XCTAssertEqual(points(controller)?.count, 2)
        XCTAssertTrue(controller.canUndo)
        XCTAssertEqual(controller.selection, controller.document?.elements.first?.id)
    }

    func testLineInheritsPenOpacityWidthAndColor() {
        let (view, controller) = makeView()
        controller.penOpacity = 0.4
        controller.strokeWidth = 20
        controller.strokeColor = .yellow
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 10, y: 100), shift: true))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 10, y: 100), shift: true))
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 190, y: 100), shift: true))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 190, y: 100), shift: true))
        guard case .pen(let pen)? = controller.document?.elements.first else { return XCTFail("no pen stroke") }
        XCTAssertEqual(pen.opacity, 0.4)
        XCTAssertEqual(pen.width, 20)
        XCTAssertEqual(pen.color, .yellow)
    }

    func testPlainClickAfterShiftClickAbandonsTheAnchor() {
        let (view, controller) = makeView()
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 50, y: 150), shift: true))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 50, y: 150), shift: true))
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 120, y: 120)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 120, y: 120)))
        XCTAssertEqual(points(controller), [CGPoint(x: 120, y: 80)], "a normal dot, not a line from the anchor")

        // The anchor was dropped: a Shift-click now starts a fresh anchor.
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 20, y: 20), shift: true))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 20, y: 20), shift: true))
        XCTAssertEqual(controller.document?.elements.count, 1)
    }

    func testShiftClickWithAnotherToolIsNotALineGesture() {
        let (view, controller) = makeView()
        controller.tool = .arrow
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 50, y: 150), shift: true))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 50, y: 150), shift: true))
        guard case .arrow? = controller.document?.elements.first else { return XCTFail("expected an arrow") }
    }
}
