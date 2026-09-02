import XCTest
import AppKit
import AnnotationModel
@testable import Masume

/// Spacebar hand tool: while space is held, dragging pans the zoomed image
/// instead of annotating. Observed through the view→model mapping: after a
/// pan, the same view point lands on a different model point. Setup: 200×200
/// image in a 200×200 window-less view.
@MainActor
final class SpacePanGestureTests: XCTestCase {

    private func makeView(zoom: ZoomMode) -> (CanvasNSView, CanvasController) {
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore())
        controller.loadImage(ctx.makeImage()!)
        controller.zoomMode = zoom
        controller.tool = .pen
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.controller = controller
        return (view, controller)
    }

    private func mouse(_ type: NSEvent.EventType, at p: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func space(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: " ", charactersIgnoringModifiers: " ",
                         isARepeat: false, keyCode: 49)!
    }

    /// Model point a pen click at `p` lands on, read back from the dot it makes.
    private func modelPoint(forClickAt p: CGPoint, _ view: CanvasNSView, _ controller: CanvasController) -> CGPoint {
        view.mouseDown(with: mouse(.leftMouseDown, at: p))
        view.mouseUp(with: mouse(.leftMouseUp, at: p))
        guard case .pen(let pen)? = controller.document?.elements.last else { XCTFail("no dot"); return .zero }
        return pen.points[0]
    }

    func testSpaceDragPansTheZoomedImageAndDrawsNothing() {
        let (view, controller) = makeView(zoom: .percent(2))
        let before = modelPoint(forClickAt: CGPoint(x: 100, y: 100), view, controller)
        let count = controller.document?.elements.count

        view.keyDown(with: space(.keyDown))
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 80, y: 50)))   // 30pt right
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 80, y: 50)))
        view.keyUp(with: space(.keyUp))
        XCTAssertEqual(controller.document?.elements.count, count, "panning must not annotate")

        let after = modelPoint(forClickAt: CGPoint(x: 100, y: 100), view, controller)
        XCTAssertEqual(after.x, before.x - 15, accuracy: 0.001, "image moved 30 view pt right at 2x → 15 model pt")
        XCTAssertEqual(after.y, before.y, accuracy: 0.001)
    }

    func testPanIsClampedToTheImageEdge() {
        let (view, controller) = makeView(zoom: .percent(2))
        let before = modelPoint(forClickAt: CGPoint(x: 100, y: 100), view, controller)
        view.keyDown(with: space(.keyDown))
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 0, y: 100)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 1000, y: 100)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 1000, y: 100)))
        view.keyUp(with: space(.keyUp))
        let after = modelPoint(forClickAt: CGPoint(x: 100, y: 100), view, controller)
        // 400pt content in a 200pt viewport can shift at most 100pt (50 model pt at 2x).
        XCTAssertEqual(after.x, before.x - 50, accuracy: 0.001)
    }

    func testReleasingSpaceMidDragKeepsPanning() {
        let (view, controller) = makeView(zoom: .percent(2))
        let before = modelPoint(forClickAt: CGPoint(x: 100, y: 100), view, controller)
        view.keyDown(with: space(.keyDown))
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50)))
        view.keyUp(with: space(.keyUp))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 50, y: 30)))    // 20pt down on screen (non-flipped)
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 50, y: 30)))
        let after = modelPoint(forClickAt: CGPoint(x: 100, y: 100), view, controller)
        // Image moved down 20 view pt: the same view point lands 10 model pt higher in it.
        XCTAssertEqual(after.y, before.y - 10, accuracy: 0.001)
    }

    func testSpaceDragInFitModeDoesNothing() {
        let (view, controller) = makeView(zoom: .fit)
        let before = modelPoint(forClickAt: CGPoint(x: 100, y: 100), view, controller)
        let count = controller.document?.elements.count
        view.keyDown(with: space(.keyDown))
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 90, y: 90)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 90, y: 90)))
        view.keyUp(with: space(.keyUp))
        XCTAssertEqual(controller.document?.elements.count, count)
        let after = modelPoint(forClickAt: CGPoint(x: 100, y: 100), view, controller)
        XCTAssertEqual(after, before)
    }

    func testPlainClickAfterSpaceReleasedAnnotatesAgain() {
        let (view, controller) = makeView(zoom: .percent(2))
        view.keyDown(with: space(.keyDown))
        view.keyUp(with: space(.keyUp))
        let count = controller.document?.elements.count ?? 0
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 100, y: 100)))
        XCTAssertEqual(controller.document?.elements.count, count + 1)
    }
}
