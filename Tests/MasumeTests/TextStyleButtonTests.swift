import XCTest
import AppKit
import AnnotationModel
import AnnotationRender
@testable import Masume

/// The style button above a selected text box cycles its style, and the
/// side handles change its width. 200×200 image in a 200×200 window-less
/// view at 1:1, so view y = 200 − model y.
@MainActor
final class TextStyleButtonTests: XCTestCase {

    private func mouse(_ type: NSEvent.EventType, at p: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func makeSelectedText() -> (CanvasNSView, CanvasController, TextElement) {
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore())
        controller.loadImage(ctx.makeImage()!)
        controller.zoomMode = .percent(1)
        controller.tool = .select
        var text = TextElement(origin: CGPoint(x: 20, y: 80), size: CGSize(width: 100, height: 10),
                               string: "hi", font: FontSpec(pointSize: 20), style: .shadow)
        text.size = Renderer.suggestedSize(for: text)
        controller.document?.add(.text(text))
        controller.selection = text.id
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.controller = controller
        return (view, controller, text)
    }

    private func click(_ view: CanvasNSView, at p: CGPoint) {
        view.mouseDown(with: mouse(.leftMouseDown, at: p))
        view.mouseUp(with: mouse(.leftMouseUp, at: p))
    }

    func testClickingTheButtonCyclesTheStyleWithOneUndoStepEach() {
        let (view, controller, text) = makeSelectedText()
        let top = 200 - text.origin.y                      // model top edge in view coords
        let button = CGPoint(x: 70, y: top + 12 + CanvasNSView.textStyleButtonRadius)
        click(view, at: button)
        XCTAssertEqual(controller.document?.elements.first?.textStyle, .outline)
        XCTAssertEqual(controller.selection, text.id, "selection survives the click")
        click(view, at: button)
        XCTAssertEqual(controller.document?.elements.first?.textStyle, .plain)
        controller.undo()
        XCTAssertEqual(controller.document?.elements.first?.textStyle, .outline)
        controller.undo()
        XCTAssertEqual(controller.document?.elements.first?.textStyle, .shadow)
        XCTAssertFalse(controller.canUndo, "exactly one undo step per click")
    }

    func testButtonIsInertWithoutASelection() {
        let (view, controller, text) = makeSelectedText()
        controller.selection = nil
        let top = 200 - text.origin.y
        click(view, at: CGPoint(x: 70, y: top + 12 + CanvasNSView.textStyleButtonRadius))
        XCTAssertEqual(controller.document?.elements.first?.textStyle, .shadow)
    }

    func testDraggingTheRightHandleWidensTheBox() {
        let (view, controller, text) = makeSelectedText()
        let midY = 200 - text.rect.midY
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: text.rect.maxX, y: midY)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: text.rect.maxX + 50, y: midY)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: text.rect.maxX + 50, y: midY)))
        guard case .text(let resized)? = controller.document?.elements.first else { return XCTFail("no text") }
        XCTAssertEqual(resized.size.width, 150, accuracy: 0.5)
        XCTAssertEqual(resized.origin, text.origin)
        XCTAssertEqual(resized.size.height, Renderer.suggestedSize(for: resized).height, accuracy: 0.5)
    }

    func testDraggingTheLeftHandleKeepsTheRightEdge() {
        let (view, controller, text) = makeSelectedText()
        let midY = 200 - text.rect.midY
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: text.rect.minX, y: midY)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: text.rect.minX - 15, y: midY)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: text.rect.minX - 15, y: midY)))
        guard case .text(let resized)? = controller.document?.elements.first else { return XCTFail("no text") }
        XCTAssertEqual(resized.rect.maxX, text.rect.maxX, accuracy: 0.5)
        XCTAssertEqual(resized.size.width, 115, accuracy: 0.5)
    }
}
