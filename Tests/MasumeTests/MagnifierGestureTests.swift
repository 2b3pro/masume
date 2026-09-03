import XCTest
import AppKit
import AnnotationModel
@testable import Masume

/// Drives `CanvasNSView` with synthetic mouse events for the magnifier:
/// the mouse-down is the center, the drag sizes the loupe, and the slider
/// under a selected loupe sets its zoom. 1:1 zoom on a 400×400 image in a
/// 400×400 view, so model y = 400 − view y.
@MainActor
final class MagnifierGestureTests: XCTestCase {

    private func makeView() -> (CanvasNSView, CanvasController) {
        let ctx = CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore())
        controller.loadImage(ctx.makeImage()!)
        controller.zoomMode = .percent(1)
        controller.tool = .magnifier
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.controller = controller
        return (view, controller)
    }

    private func event(_ type: NSEvent.EventType, at p: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func loupe(_ controller: CanvasController) -> MagnifierElement? {
        guard case .magnifier(let m)? = controller.document?.elements.first else { return nil }
        return m
    }

    func testDragFromTheCenterSizesTheLoupeAndHandsBackToSelect() {
        let (view, controller) = makeView()
        controller.magnifierShape = .square
        controller.magnifierZoom = 3
        controller.strokeColor = .blue
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 200, y: 200)))    // model (200, 200)
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 230, y: 160))) // 50 away
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 230, y: 160)))
        guard let m = loupe(controller) else { return XCTFail("expected a loupe") }
        XCTAssertEqual(m.rect, CGRect(x: 150, y: 150, width: 100, height: 100))
        XCTAssertEqual(m.shape, .square)
        XCTAssertEqual(m.zoom, 3)
        XCTAssertEqual(m.color, .blue)
        XCTAssertEqual(controller.tool, .select, "one-shot like the other creation tools")
        XCTAssertEqual(controller.selection, m.id)
    }

    func testPlainClickDropsADefaultLoupe() {
        let (view, controller) = makeView()
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 200, y: 200)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 200, y: 200)))
        guard let m = loupe(controller) else { return XCTFail("expected a loupe") }
        XCTAssertEqual(m.center, CGPoint(x: 200, y: 200))
        XCTAssertGreaterThan(m.rect.width, 20)
        XCTAssertEqual(m.rect.width, m.rect.height)
    }

    func testSliderUnderTheLoupeSetsZoomAsOneUndoStep() {
        let (view, controller) = makeView()
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 200, y: 200)))
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 260, y: 200))) // radius 60
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 260, y: 200)))
        guard let m = loupe(controller) else { return XCTFail("expected a loupe") }
        XCTAssertEqual(m.zoom, MagnifierElement.defaultZoom)
        let undoDepthBefore = controller.canUndo

        // The slider floats under the loupe's box (view y below its minY).
        let info = view.displayInfo
        guard let track = view.magnifierSliderTrack(for: .magnifier(m), info: info) else {
            return XCTFail("no slider for a selected loupe")
        }
        XCTAssertLessThan(track.maxY, info.viewRect(forModelRect: m.boundingBox()).minY)
        XCTAssertTrue(undoDepthBefore)

        // Drag the knob to the right end: maximum zoom, then back to the middle.
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: track.minX + 8, y: track.midY)))
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: track.maxX + 40, y: track.midY)))
        XCTAssertEqual(loupe(controller)?.zoom, MagnifierElement.zoomRange.upperBound)
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: track.midX, y: track.midY)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: track.midX, y: track.midY)))
        let mid = (MagnifierElement.zoomRange.lowerBound + MagnifierElement.zoomRange.upperBound) / 2
        XCTAssertEqual(loupe(controller)?.zoom ?? 0, mid, accuracy: 0.1)
        XCTAssertEqual(controller.document?.elements.count, 1, "the slider click did not create anything")
        XCTAssertEqual(controller.magnifierZoom, loupe(controller)?.zoom, "new loupes inherit the zoom")

        controller.undo()
        XCTAssertEqual(loupe(controller)?.zoom, MagnifierElement.defaultZoom, "the whole drag is one undo step")
    }

    func testShapeAndZoomPreferencesRoundTrip() throws {
        var prefs = ToolPreferences()
        prefs.magnifierShape = .square
        prefs.magnifierZoom = 5
        let data = try JSONEncoder().encode(prefs)
        XCTAssertEqual(try JSONDecoder().decode(ToolPreferences.self, from: data), prefs)
        let legacy = try JSONDecoder().decode(ToolPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.magnifierShape, .circle)
        XCTAssertEqual(legacy.magnifierZoom, MagnifierElement.defaultZoom)
        let wild = try JSONDecoder().decode(ToolPreferences.self, from: Data(#"{"magnifierZoom": 900}"#.utf8))
        XCTAssertEqual(wild.magnifierZoom, MagnifierElement.zoomRange.upperBound, "stored zoom is clamped")
    }

    func testSelectingALoupeAdoptsItsShapeAndZoomAndShowsTheFlyout() {
        let (_, controller) = makeView()
        let m = MagnifierElement(rect: CGRect(x: 10, y: 10, width: 50, height: 50), shape: .square, zoom: 4)
        controller.perform { $0.add(.magnifier(m)) }
        controller.tool = .select
        XCTAssertEqual(controller.flyoutTool, .select, "the Select tool's own row: the zone shape")
        controller.selection = m.id
        XCTAssertEqual(controller.magnifierShape, .square)
        XCTAssertEqual(controller.magnifierZoom, 4)
        XCTAssertEqual(controller.flyoutTool, .magnifier)
        controller.magnifierShape = .circle
        XCTAssertEqual(loupe(controller)?.shape, .circle)
    }
}
