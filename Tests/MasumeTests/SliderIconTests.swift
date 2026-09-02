import XCTest
import AnnotationModel
@testable import Masume

/// The palette's size slider serves three jobs; the controller says which so
/// the tile can show a matching icon.
@MainActor
final class SliderIconTests: XCTestCase {

    private func makeController() -> CanvasController {
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore())
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        controller.loadImage(ctx.makeImage()!)
        return controller
    }

    func testTextAndCalloutToolsEditTextSize() {
        let controller = makeController()
        controller.tool = .text
        XCTAssertTrue(controller.sliderEditsTextSize)
        controller.tool = .callout
        XCTAssertTrue(controller.sliderEditsTextSize)
        controller.tool = .arrow
        XCTAssertFalse(controller.sliderEditsTextSize)
        controller.tool = .pixelate
        XCTAssertFalse(controller.sliderEditsTextSize)
        XCTAssertTrue(controller.sliderEditsPixelateAmount)
    }

    func testSelectedTextEditsTextSizeWithAnyTool() {
        let controller = makeController()
        let text = TextElement(origin: .zero, string: "hi")
        let arrow = SegmentElement(start: .zero, end: CGPoint(x: 10, y: 10))
        controller.perform { $0.add(.text(text)); $0.add(.arrow(arrow)) }
        controller.tool = .select
        controller.selection = text.id
        XCTAssertTrue(controller.sliderEditsTextSize)
        controller.selection = arrow.id
        XCTAssertFalse(controller.sliderEditsTextSize)
    }
}
