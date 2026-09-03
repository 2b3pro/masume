import XCTest
import AppKit
import AnnotationModel
@testable import Masume

/// The crop tool's second job: a frame reaching outside the canvas grows it
/// with white, through the canvas's own handles or a rubber band that runs
/// past the edge. 1:1 zoom on a 200×200 red image in a 200×200 view.
@MainActor
final class CanvasResizeTests: XCTestCase {

    private func redImage(_ size: Int = 200) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()!
    }

    private func makeView() -> (CanvasNSView, CanvasController) {
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore())
        controller.loadImage(redImage())
        controller.zoomMode = .percent(1)
        controller.tool = .crop
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.controller = controller
        return (view, controller)
    }

    private func event(_ type: NSEvent.EventType, at p: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// The pixel at model (x, y), top-left origin: a bitmap context's first
    /// row in memory is its top row.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var buf = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &buf, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let i = (y * image.width + x) * 4
        return (buf[i], buf[i + 1], buf[i + 2])
    }

    func testApplyingAFrameOutsideTheCanvasGrowsItWithWhite() throws {
        let (_, controller) = makeView()
        controller.document?.add(.rectangle(ShapeElement(rect: CGRect(x: 10, y: 10, width: 20, height: 20))))
        controller.document?.crop = CGRect(x: -50, y: -100, width: 300, height: 350)
        XCTAssertTrue(controller.pendingFrameExpands)
        XCTAssertEqual(controller.pendingFrameWidth, 300)
        XCTAssertEqual(controller.pendingFrameHeight, 350)
        controller.applyCrop()
        let doc = try XCTUnwrap(controller.document)
        XCTAssertEqual(doc.canvasSize, CGSize(width: 300, height: 350))
        XCTAssertNil(doc.crop)
        guard case .rectangle(let shape)? = doc.elements.first else { return XCTFail("rectangle") }
        XCTAssertEqual(shape.rect.origin, CGPoint(x: 60, y: 110), "elements shift with the image")
        let base = try XCTUnwrap(controller.baseImage)
        XCTAssertEqual(base.width, 300); XCTAssertEqual(base.height, 350)
        let added = pixel(base, x: 10, y: 10)
        XCTAssertEqual([added.r, added.g, added.b], [255, 255, 255], "new canvas is white")
        let moved = pixel(base, x: 60, y: 110)
        XCTAssertEqual([moved.r, moved.g, moved.b], [255, 0, 0], "the image sits at its offset")
        let farCorner = pixel(base, x: 249, y: 299)
        XCTAssertEqual(farCorner.r, 255); XCTAssertEqual(farCorner.g, 0)
        let below = pixel(base, x: 100, y: 320)
        XCTAssertEqual([below.r, below.g, below.b], [255, 255, 255])
        controller.undo()
        XCTAssertEqual(controller.document?.canvasSize, CGSize(width: 200, height: 200))
        XCTAssertEqual(controller.baseImage?.width, 200)
    }

    func testAFrameInsideTheCanvasStillCrops() {
        let (_, controller) = makeView()
        controller.document?.crop = CGRect(x: 50, y: 50, width: 100, height: 80)
        XCTAssertFalse(controller.pendingFrameExpands)
        controller.applyCrop()
        XCTAssertEqual(controller.document?.canvasSize, CGSize(width: 100, height: 80))
        XCTAssertEqual(controller.baseImage?.width, 100)
    }

    func testSizeFieldsResizeTheFrameFromItsTopLeft() {
        let (_, controller) = makeView()
        controller.document?.crop = CGRect(x: 20, y: 30, width: 100, height: 100)
        controller.pendingFrameWidth = 400
        controller.pendingFrameHeight = 50
        XCTAssertEqual(controller.document?.crop, CGRect(x: 20, y: 30, width: 400, height: 50))
        XCTAssertTrue(controller.pendingFrameExpands)
        controller.pendingFrameWidth = 1
        XCTAssertEqual(controller.document?.crop?.width, 2, "never thinner than the minimum")
    }

    func testDraggingTheCanvasEdgeHandleOutwardStartsAFrameThatGrowsIt() throws {
        let (view, controller) = makeView()
        // The right-edge handle of the canvas sits at view (200, 100).
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 199, y: 100)))
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 260, y: 100)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 260, y: 100)))
        XCTAssertEqual(controller.document?.crop, CGRect(x: 0, y: 0, width: 260, height: 200), "kept, not clamped")
        XCTAssertTrue(controller.pendingFrameExpands)
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                            isARepeat: false, keyCode: 36)!)
        XCTAssertEqual(controller.document?.canvasSize, CGSize(width: 260, height: 200))
        XCTAssertNil(controller.document?.crop)
    }

    func testCornerHandleOfThePendingFrameResizesItAndInsideMovesIt() {
        let (view, controller) = makeView()
        controller.document?.crop = CGRect(x: 50, y: 50, width: 100, height: 100)
        // Bottom-right corner in model (150, 150) is view (150, 50); drag it past the canvas.
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 150, y: 50)))
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 230, y: 20)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 230, y: 20)))
        XCTAssertEqual(controller.document?.crop, CGRect(x: 50, y: 50, width: 180, height: 130))
        // The top edge handle, model (140, 50): view (140, 150). Drag it up past the canvas.
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 140, y: 150)))
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 140, y: 230)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 140, y: 230)))
        XCTAssertEqual(controller.document?.crop, CGRect(x: 50, y: -30, width: 180, height: 210))
        // Inside: moves the whole frame.
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 110, y: 90)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 110, y: 90)))
        XCTAssertEqual(controller.document?.crop, CGRect(x: 60, y: -20, width: 180, height: 210))
    }

    func testAFrameThatKeepsNoneOfTheImageIsDropped() {
        let (view, controller) = makeView()
        // Rubber band entirely outside the canvas (view y above 200 is model y below 0).
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 10, y: 250)))
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 60, y: 300)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 60, y: 300)))
        XCTAssertNil(controller.document?.crop)
    }
}
