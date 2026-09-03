import XCTest
import AppKit
import AnnotationModel
@testable import Masume

/// Option-drag on an annotation drags off a copy: the original stays, the
/// copy moves, takes the selection, and the whole gesture is one undo step.
/// 1:1 zoom on a 400×400 image in a 400×400 view, so model y = 400 − view y.
@MainActor
final class OptionDragDuplicateTests: XCTestCase {

    private func makeView() -> (CanvasNSView, CanvasController) {
        let ctx = CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore())
        controller.loadImage(ctx.makeImage()!)
        controller.zoomMode = .percent(1)
        controller.tool = .select
        controller.perform { $0.add(.rectangle(ShapeElement(rect: CGRect(x: 100, y: 100, width: 100, height: 100),
                                                            color: .red, width: 4))) }
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.controller = controller
        return (view, controller)
    }

    private func event(_ type: NSEvent.EventType, at p: CGPoint, option: Bool) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: option ? [.option] : [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// The rectangles' own rects (a bounding box would add the stroke).
    private func rects(_ controller: CanvasController) -> [CGRect] {
        controller.document?.elements.compactMap { if case .rectangle(let r) = $0 { r.rect } else { nil } } ?? []
    }

    func testOptionDragLeavesTheOriginalAndMovesACopy() {
        let (view, controller) = makeView()
        let original = controller.document!.elements[0]
        // Model (100, 150) is on the rectangle's left edge: view (100, 250).
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 100, y: 250), option: true))
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 120, y: 240), option: true))
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 150, y: 200), option: true))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 150, y: 200), option: true))

        let elements = controller.document!.elements
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements[0], original, "the original neither moves nor changes identity")
        XCTAssertNotEqual(elements[1].id, original.id)
        XCTAssertEqual(rects(controller)[1], CGRect(x: 150, y: 150, width: 100, height: 100),
                       "the copy followed the pointer by (50, 50) in model space")
        XCTAssertEqual(controller.selection, elements[1].id, "the copy takes the selection")
        guard case .rectangle(let copy) = elements[1] else { return XCTFail("the copy keeps its kind") }
        XCTAssertEqual(copy.color, .red)
        XCTAssertEqual(copy.width, 4)
    }

    func testTheGestureIsOneUndoStep() {
        let (view, controller) = makeView()
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 100, y: 250), option: true))
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 150, y: 200), option: true))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 150, y: 200), option: true))
        XCTAssertEqual(controller.document?.elements.count, 2)
        controller.undo()
        XCTAssertEqual(rects(controller), [CGRect(x: 100, y: 100, width: 100, height: 100)])
        controller.redo()
        XCTAssertEqual(controller.document?.elements.count, 2)
    }

    func testOptionClickWithoutMovingDuplicatesNothing() {
        let (view, controller) = makeView()
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 100, y: 250), option: true))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 100, y: 250), option: true))
        XCTAssertEqual(controller.document?.elements.count, 1)
        XCTAssertEqual(controller.selection, controller.document?.elements[0].id, "it still selects")
    }

    func testPlainDragStillMovesTheOriginal() {
        let (view, controller) = makeView()
        let id = controller.document!.elements[0].id
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 100, y: 250), option: false))
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 150, y: 200), option: false))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 150, y: 200), option: false))
        XCTAssertEqual(rects(controller), [CGRect(x: 150, y: 150, width: 100, height: 100)])
        XCTAssertEqual(controller.document?.elements[0].id, id)
    }

    func testOptionDragWorksWithACreationToolActive() {
        let (view, controller) = makeView()
        controller.tool = .rectangle
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 100, y: 250), option: true))
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 150, y: 200), option: true))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 150, y: 200), option: true))
        XCTAssertEqual(controller.document?.elements.count, 2, "a body hit duplicates rather than creating")
    }
}
