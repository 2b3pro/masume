import XCTest
import AppKit
import AnnotationModel
import AnnotationRender
@testable import Masume

/// Dragging a text box's right edge narrower must grow its height so wrapped
/// lines are not clipped. 200×200 image in a 200×200 window-less view at
/// 1:1, so view y = 200 − model y.
@MainActor
final class TextResizeGestureTests: XCTestCase {

    private func mouse(_ type: NSEvent.EventType, at p: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testNarrowingATextBoxReMeasuresItsHeight() {
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore())
        controller.loadImage(ctx.makeImage()!)
        controller.zoomMode = .percent(1)
        var text = TextElement(origin: CGPoint(x: 10, y: 10), size: CGSize(width: 180, height: 10),
                               string: "wrap me across several lines please", font: FontSpec(pointSize: 20))
        text.size = Renderer.suggestedSize(for: text)
        let oneLineHeight = text.size.height
        controller.document?.add(.text(text))
        controller.selection = text.id
        controller.tool = .select
        controller.selection = text.id

        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.controller = controller
        // Grab the right-edge handle (model 190, 10 + h/2) and drag it to x = 80.
        let corner = CGPoint(x: 190, y: 200 - (10 + oneLineHeight / 2))
        view.mouseDown(with: mouse(.leftMouseDown, at: corner))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 80, y: corner.y)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 80, y: corner.y)))

        guard case .text(let resized)? = controller.document?.elements.first else { return XCTFail("no text") }
        XCTAssertEqual(resized.size.width, 70, accuracy: 0.5)
        XCTAssertGreaterThan(resized.size.height, oneLineHeight * 1.8, "narrower box must grow to fit wrapped lines")
        XCTAssertEqual(resized.size.height, Renderer.suggestedSize(for: resized).height, accuracy: 0.5)
    }
}
