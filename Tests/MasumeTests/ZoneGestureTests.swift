import XCTest
import AppKit
import AnnotationModel
@testable import Masume

/// The Select tool on empty canvas marks out a zone: marching ants the
/// person and the agent share, never an annotation. 1:1 zoom on a 400×400
/// image in a 400×400 view, so model y = 400 − view y.
@MainActor
final class ZoneGestureTests: XCTestCase {

    private func makeView() -> (CanvasNSView, CanvasController) {
        let ctx = CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore())
        controller.loadImage(ctx.makeImage()!)
        controller.zoomMode = .percent(1)
        controller.tool = .select
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.controller = controller
        return (view, controller)
    }

    private func event(_ type: NSEvent.EventType, at p: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func drag(_ view: CanvasNSView, from a: CGPoint, to b: CGPoint) {
        view.mouseDown(with: event(.leftMouseDown, at: a))
        view.mouseDragged(with: event(.leftMouseDragged, at: b))
        view.mouseUp(with: event(.leftMouseUp, at: b))
    }

    func testDraggingOnEmptyCanvasMarksOutAZoneThatIsNotAnAnnotation() {
        let (view, controller) = makeView()
        let before = controller.document
        drag(view, from: CGPoint(x: 100, y: 300), to: CGPoint(x: 220, y: 240))   // model (100,100) to (220,160)
        XCTAssertEqual(controller.zone, Zone(rect: CGRect(x: 100, y: 100, width: 120, height: 60), shape: .rectangle))
        XCTAssertEqual(controller.document, before, "the document is untouched")
        XCTAssertFalse(controller.canUndo, "and nothing was committed")
        XCTAssertEqual(controller.project?.revision, 0)
    }

    func testTheShapeChoiceAppliesToNewAndCurrentZones() {
        let (view, controller) = makeView()
        controller.zoneShape = .ellipse
        drag(view, from: CGPoint(x: 50, y: 350), to: CGPoint(x: 150, y: 250))
        XCTAssertEqual(controller.zone?.shape, .ellipse)
        controller.zoneShape = .rectangle
        XCTAssertEqual(controller.zone?.shape, .rectangle, "restyles the zone on the canvas")
        XCTAssertEqual(controller.flyoutTool, .select, "the Select row offers the shape")
    }

    func testAClickOrEscapeClearsTheZoneAndANewDragReplacesIt() {
        let (view, controller) = makeView()
        drag(view, from: CGPoint(x: 50, y: 350), to: CGPoint(x: 150, y: 250))
        XCTAssertNotNil(controller.zone)
        drag(view, from: CGPoint(x: 200, y: 200), to: CGPoint(x: 300, y: 100))
        XCTAssertEqual(controller.zone?.rect, CGRect(x: 200, y: 200, width: 100, height: 100), "replaced")
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 20, y: 20)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 20, y: 20)))
        XCTAssertNil(controller.zone, "a click marks nothing out")
        drag(view, from: CGPoint(x: 50, y: 350), to: CGPoint(x: 150, y: 250))
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                            context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                                            isARepeat: false, keyCode: 53)!)
        XCTAssertNil(controller.zone, "Escape clears it")
        drag(view, from: CGPoint(x: 50, y: 350), to: CGPoint(x: 52, y: 348))
        XCTAssertNil(controller.zone, "a wobble of a few pixels is a click")
    }

    func testDraggingAnElementMovesItRatherThanZoning() {
        let (view, controller) = makeView()
        controller.perform { $0.add(.rectangle(ShapeElement(rect: CGRect(x: 100, y: 100, width: 100, height: 100), fill: .red))) }
        drag(view, from: CGPoint(x: 150, y: 250), to: CGPoint(x: 170, y: 230))
        XCTAssertNil(controller.zone)
        guard case .rectangle(let moved)? = controller.document?.elements.first else { return XCTFail("rectangle") }
        XCTAssertEqual(moved.rect.origin, CGPoint(x: 120, y: 120))
    }
}
