import XCTest
import AppKit
import AnnotationModel
@testable import Masume

/// Cmd+scroll wheel zooms the canvas; a plain scroll still pans.
@MainActor
final class CommandScrollZoomTests: XCTestCase {

    private func makeView(zoom: ZoomMode) -> (CanvasNSView, CanvasController) {
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore())
        controller.loadImage(ctx.makeImage()!)
        controller.zoomMode = zoom
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.controller = controller
        return (view, controller)
    }

    /// One mouse-wheel notch (line units, not precise), optionally with ⌘.
    private func wheel(_ notches: Int32, command: Bool) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                         wheel1: notches, wheel2: 0, wheel3: 0)!
        cg.flags = command ? .maskCommand : []
        return NSEvent(cgEvent: cg)!
    }

    func testCommandWheelUpZoomsInAboutTenPercentPerNotch() {
        let (view, controller) = makeView(zoom: .percent(1))
        view.scrollWheel(with: wheel(1, command: true))
        guard case .percent(let scale) = controller.zoomMode else { return XCTFail("expected percent zoom") }
        XCTAssertEqual(scale, exp(0.1), accuracy: 0.02)
        XCTAssertEqual(controller.effectiveZoomScale, scale)
    }

    func testCommandWheelDownZoomsOut() {
        let (view, controller) = makeView(zoom: .percent(2))
        view.scrollWheel(with: wheel(-1, command: true))
        guard case .percent(let scale) = controller.zoomMode else { return XCTFail("expected percent zoom") }
        XCTAssertLessThan(scale, 2)
    }

    func testCommandWheelWorksFromFitMode() {
        let (view, controller) = makeView(zoom: .fit)
        view.scrollWheel(with: wheel(1, command: true))
        guard case .percent(let scale) = controller.zoomMode else { return XCTFail("fit should become a percent zoom") }
        XCTAssertEqual(scale, exp(0.1), accuracy: 0.02, "fit of a 200px image in a 200px view is 1.0")
    }

    func testPlainWheelDoesNotZoom() {
        let (view, controller) = makeView(zoom: .percent(2))
        view.scrollWheel(with: wheel(1, command: false))
        guard case .percent(let scale) = controller.zoomMode else { return XCTFail("expected percent zoom") }
        XCTAssertEqual(scale, 2)
    }
}
