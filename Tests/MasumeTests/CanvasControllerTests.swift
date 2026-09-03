import XCTest
import CoreGraphics
import AnnotationModel
@testable import Masume

@MainActor
final class CanvasControllerTests: XCTestCase {

    private func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    /// A controller with a 2400×2000 image loaded — exactly double the
    /// reference canvas, so the expected widths are double the references
    /// (segment 32, shape 16).
    private func makeLoadedController() -> CanvasController {
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore())
        controller.loadImage(makeImage(width: 2400, height: 2000))
        return controller
    }

    // MARK: - Image-size-derived stroke width defaults (issue #32)

    func testLoadImageSetsStrokeWidthScaledToImageSize() {
        let controller = makeLoadedController()
        XCTAssertEqual(controller.tool, .arrow)
        XCTAssertEqual(controller.strokeWidth, 32, "double the reference canvas → double the segment reference")
    }

    func testLoadImageClampsStrokeWidthToSliderRange() {
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore())
        controller.loadImage(makeImage(width: 20, height: 20))
        XCTAssertEqual(controller.strokeWidth, DefaultStrokeWidth.range.lowerBound)
    }

    /// A user-adjusted width is remembered across images, rescaled to each
    /// image's size (it is stored relative to the reference canvas).
    func testLoadingNewImageKeepsUserAdjustedStrokeWidthRescaled() {
        let controller = makeLoadedController()        // 2x reference
        controller.strokeWidth = 8                     // reference 4
        controller.loadImage(makeImage(width: 2400, height: 2000))
        XCTAssertEqual(controller.strokeWidth, 8, "same-size image: same width")
        controller.loadImage(makeImage(width: 1200, height: 1000))
        XCTAssertEqual(controller.strokeWidth, 4, "reference-size image: half the width")
    }

    // MARK: - Per-tool-group stroke width memory

    func testShapeToolsGetThinnerDefaultThanArrow() {
        let controller = makeLoadedController()
        controller.tool = .rectangle
        XCTAssertEqual(controller.strokeWidth, 16, "shape reference is half the segment reference")
        controller.tool = .ellipse
        XCTAssertEqual(controller.strokeWidth, 16)
    }

    func testLineSharesArrowWidthGroup() {
        let controller = makeLoadedController()
        controller.tool = .line
        XCTAssertEqual(controller.strokeWidth, 32)
        controller.strokeWidth = 5
        controller.tool = .arrow
        XCTAssertEqual(controller.strokeWidth, 5)
    }

    func testToolSwitchRestoresEachGroupsRememberedWidth() {
        let controller = makeLoadedController()
        controller.strokeWidth = 5          // remembered for the segment group
        controller.tool = .rectangle
        XCTAssertEqual(controller.strokeWidth, 16)
        controller.strokeWidth = 9          // remembered for the shape group
        controller.tool = .arrow
        XCTAssertEqual(controller.strokeWidth, 5)
        controller.tool = .rectangle
        XCTAssertEqual(controller.strokeWidth, 9)
    }

    func testGrouplessToolKeepsCurrentSliderValue() {
        let controller = makeLoadedController()
        controller.tool = .select
        XCTAssertEqual(controller.strokeWidth, 32)
        controller.tool = .rectangle
        XCTAssertEqual(controller.strokeWidth, 16)
    }

    // MARK: - Pixelate amount ↔ selection sync

    private func makeRedaction(amount: CGFloat = 22) -> Annotation {
        .pixelate(RedactionElement(rect: CGRect(x: 10, y: 10, width: 200, height: 100), amount: amount))
    }

    func testLoadImageSetsPixelateAmountScaledToImageSize() {
        let controller = makeLoadedController()
        XCTAssertEqual(controller.pixelateAmount, 28, "double the reference canvas → double the pixelate reference")
    }

    func testLoadImageClampsPixelateAmountToRange() {
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore())
        controller.loadImage(makeImage(width: 20, height: 20))
        XCTAssertEqual(controller.pixelateAmount, RedactionElement.amountRange.lowerBound)
    }

    func testSelectingPixelateElementAdoptsItsAmount() {
        let controller = makeLoadedController()
        let redaction = makeRedaction(amount: 22)
        controller.document?.elements.append(redaction)
        controller.selection = redaction.id
        XCTAssertEqual(controller.pixelateAmount, 22)
    }

    func testSelectionSyncDoesNotWriteBackIntoDocument() {
        let controller = makeLoadedController()
        let redaction = makeRedaction(amount: 22)
        controller.document?.elements.append(redaction)
        let before = controller.document
        controller.selection = redaction.id
        XCTAssertEqual(controller.document, before, "adopting the amount must not count as an edit (isSyncing guard)")
    }

    func testChangingAmountEditsSelectedPixelateElement() {
        let controller = makeLoadedController()
        let redaction = makeRedaction(amount: 22)
        controller.document?.elements.append(redaction)
        controller.selection = redaction.id
        controller.pixelateAmount = 30
        XCTAssertEqual(controller.document?.elements.last?.pixelateAmount, 30)
    }

    func testChangingAmountLeavesNonPixelateSelectionUntouched() {
        let controller = makeLoadedController()
        let arrow = Annotation.arrow(SegmentElement(start: .zero, end: CGPoint(x: 100, y: 100)))
        controller.document?.elements.append(arrow)
        controller.selection = arrow.id
        let before = controller.document
        controller.pixelateAmount = 30
        XCTAssertEqual(controller.document, before)
    }

    func testSliderEditsPixelateAmountForPixelateTool() {
        let controller = makeLoadedController()
        XCTAssertFalse(controller.sliderEditsPixelateAmount)
        controller.tool = .pixelate
        XCTAssertTrue(controller.sliderEditsPixelateAmount)
    }

    func testSliderEditsPixelateAmountFollowsSelection() {
        let controller = makeLoadedController()
        let redaction = makeRedaction()
        let arrow = Annotation.arrow(SegmentElement(start: .zero, end: CGPoint(x: 100, y: 100)))
        controller.document?.elements.append(contentsOf: [redaction, arrow])
        controller.tool = .select
        controller.selection = redaction.id
        XCTAssertTrue(controller.sliderEditsPixelateAmount)
        controller.selection = arrow.id
        XCTAssertFalse(controller.sliderEditsPixelateAmount)
        controller.selection = nil
        XCTAssertFalse(controller.sliderEditsPixelateAmount)
    }

    // MARK: - Tool switch clears selection

    // MARK: - Text style

    private func addText(_ controller: CanvasController, style: TextStyle) -> ElementID {
        let text = TextElement(origin: CGPoint(x: 10, y: 10), string: "hi", style: style)
        controller.document?.add(.text(text))
        return text.id
    }

    func testTextStyleDefaultsToShadow() {
        XCTAssertEqual(CanvasController(preferencesStore: InMemoryToolPreferencesStore()).textStyle, .shadow)
    }

    func testSelectingTextAdoptsItsStyle() {
        let controller = makeLoadedController()
        let id = addText(controller, style: .outline)
        controller.selection = id
        XCTAssertEqual(controller.textStyle, .outline)
        XCTAssertFalse(controller.canUndo, "selection sync must not register an undo step")
    }

    func testChangingStyleEditsSelectedTextAndIsUndoable() {
        let controller = makeLoadedController()
        let id = addText(controller, style: .shadow)
        controller.selection = id
        controller.textStyle = .plain
        XCTAssertEqual(controller.document?.elements.first?.textStyle, .plain)
        XCTAssertTrue(controller.canUndo)
        controller.undo()
        XCTAssertEqual(controller.document?.elements.first?.textStyle, .shadow)
    }

    func testChangingStyleLeavesNonTextSelectionUntouched() {
        let controller = makeLoadedController()
        let arrow = SegmentElement(start: .zero, end: CGPoint(x: 50, y: 50))
        controller.document?.add(.arrow(arrow))
        controller.selection = arrow.id
        controller.textStyle = .plain
        XCTAssertEqual(controller.document?.elements.first, .arrow(arrow))
        XCTAssertFalse(controller.canUndo)
    }

    func testSelectingTextAdoptsItsOutlineColor() {
        let controller = makeLoadedController()
        controller.document?.add(.text(TextElement(origin: .zero, string: "hi", outlineColor: .black)))
        controller.selection = controller.document?.elements.first?.id
        XCTAssertEqual(controller.textOutlineColor, .black)
        XCTAssertFalse(controller.canUndo)
    }

    func testChangingOutlineColorEditsSelectedTextAndIsUndoable() {
        let controller = makeLoadedController()
        controller.selection = addText(controller, style: .shadow)
        controller.textOutlineColor = .black
        XCTAssertEqual(controller.document?.elements.first?.textOutlineColor, .black)
        XCTAssertTrue(controller.canUndo)
        controller.undo()
        XCTAssertEqual(controller.document?.elements.first?.textOutlineColor, .white)
    }

    func testChangingOutlineColorLeavesNonTextSelectionUntouched() {
        let controller = makeLoadedController()
        let arrow = SegmentElement(start: .zero, end: CGPoint(x: 50, y: 50))
        controller.document?.add(.arrow(arrow))
        controller.selection = arrow.id
        controller.textOutlineColor = .black
        XCTAssertEqual(controller.document?.elements.first, .arrow(arrow))
        XCTAssertFalse(controller.canUndo)
    }

    func testTextStyleControlShowsForTextToolOrTextSelection() {
        let controller = makeLoadedController()
        XCTAssertFalse(controller.editsTextStyle)
        controller.tool = .text
        XCTAssertTrue(controller.editsTextStyle)
        controller.tool = .select
        let id = addText(controller, style: .shadow)
        controller.selection = id
        XCTAssertTrue(controller.editsTextStyle)
    }

    // MARK: - Stamp kind

    private func addStamp(_ controller: CanvasController, kind: StampKind) -> ElementID {
        let stamp = StampElement(center: CGPoint(x: 50, y: 50), kind: kind)
        controller.document?.add(.stamp(stamp))
        return stamp.id
    }

    func testStampKindDefaultsToCheck() {
        XCTAssertEqual(CanvasController(preferencesStore: InMemoryToolPreferencesStore()).stampKind, .check)
    }

    func testSelectingStampAdoptsItsKindAndColor() {
        let controller = makeLoadedController()
        controller.document?.add(.stamp(StampElement(center: .zero, kind: .heart, color: .pink)))
        controller.selection = controller.document?.elements.first?.id
        XCTAssertEqual(controller.stampKind, .heart)
        XCTAssertEqual(controller.strokeColor, .pink)
        XCTAssertFalse(controller.canUndo)
    }

    func testChangingKindEditsSelectedStampAndIsUndoable() {
        let controller = makeLoadedController()
        let id = addStamp(controller, kind: .check)
        controller.selection = id
        controller.stampKind = .question
        XCTAssertEqual(controller.document?.elements.first?.stampKind, .question)
        XCTAssertTrue(controller.canUndo)
        controller.undo()
        XCTAssertEqual(controller.document?.elements.first?.stampKind, .check)
    }

    func testChangingKindLeavesNonStampSelectionUntouched() {
        let controller = makeLoadedController()
        let id = addText(controller, style: .plain)
        controller.selection = id
        controller.stampKind = .heart
        XCTAssertEqual(controller.document?.elements.first?.textStyle, .plain)
        XCTAssertFalse(controller.canUndo)
    }

    func testEmojiFollowsAndEditsTheSelectedEmojiStamp() {
        let controller = makeLoadedController()
        let stamp = StampElement(center: CGPoint(x: 50, y: 50), kind: .emoji, emoji: "\u{1F525}")
        controller.document?.add(.stamp(stamp))
        controller.selection = stamp.id
        XCTAssertEqual(controller.stampKind, .emoji)
        XCTAssertEqual(controller.stampEmoji, "\u{1F525}", "selecting adopts the stamp's emoji")
        XCTAssertFalse(controller.canUndo)
        controller.stampEmoji = "\u{2B50}"
        XCTAssertEqual(controller.document?.elements.first?.stampEmoji, "\u{2B50}")
        XCTAssertTrue(controller.canUndo)
        controller.undo()
        XCTAssertEqual(controller.document?.elements.first?.stampEmoji, "\u{1F525}")
        controller.selection = addStamp(controller, kind: .heart)
        controller.stampEmoji = "\u{1F600}"
        XCTAssertEqual(controller.document?.elements[1].stampKind, .heart, "a glyph stamp ignores the emoji")
    }

    func testStampKindControlShowsForStampToolOrStampSelection() {
        let controller = makeLoadedController()
        XCTAssertFalse(controller.editsStampKind)
        controller.tool = .stamp
        XCTAssertTrue(controller.editsStampKind)
        XCTAssertFalse(controller.editsTextStyle)
        controller.tool = .select
        controller.selection = addStamp(controller, kind: .cross)
        XCTAssertTrue(controller.editsStampKind)
    }

    func testStampToolHasNoStrokeWidthGroup() {
        let controller = makeLoadedController()
        let before = controller.strokeWidth
        controller.tool = .stamp
        XCTAssertEqual(controller.strokeWidth, before, "stamp tool keeps the slider value; it has no width group")
    }

    // MARK: - Pen opacity

    private func addPen(_ controller: CanvasController, opacity: CGFloat) -> ElementID {
        let pen = PenElement(points: [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 40)], opacity: opacity)
        controller.document?.add(.pen(pen))
        return pen.id
    }

    func testPenOpacityDefaultsToOpaque() {
        XCTAssertEqual(CanvasController(preferencesStore: InMemoryToolPreferencesStore()).penOpacity, 1)
    }

    func testSelectingPenAdoptsItsOpacityWithoutUndo() {
        let controller = makeLoadedController()
        controller.selection = addPen(controller, opacity: 0.4)
        XCTAssertEqual(controller.penOpacity, 0.4)
        XCTAssertFalse(controller.canUndo)
    }

    func testChangingOpacityEditsSelectedPen() {
        let controller = makeLoadedController()
        controller.selection = addPen(controller, opacity: 1)
        controller.penOpacity = 0.3
        XCTAssertEqual(controller.document?.elements.first?.opacity, 0.3)
    }

    func testChangingOpacityLeavesNonPenSelectionUntouched() {
        let controller = makeLoadedController()
        controller.selection = addText(controller, style: .plain)
        controller.penOpacity = 0.3
        XCTAssertNil(controller.document?.elements.first?.opacity)
    }

    func testOpacityControlShowsForPenToolOrPenSelection() {
        let controller = makeLoadedController()
        XCTAssertFalse(controller.editsPenOpacity)
        controller.tool = .pen
        XCTAssertTrue(controller.editsPenOpacity)
        controller.tool = .select
        controller.selection = addPen(controller, opacity: 1)
        XCTAssertTrue(controller.editsPenOpacity)
    }

    func testPenHasItsOwnRememberedWidth() {
        let controller = makeLoadedController()   // 2x reference canvas
        controller.tool = .pen
        XCTAssertEqual(controller.strokeWidth, DefaultStrokeWidth.penReferenceWidth * 2)
        controller.strokeWidth = 5
        controller.tool = .arrow
        XCTAssertEqual(controller.strokeWidth, 32)
        controller.tool = .pen
        XCTAssertEqual(controller.strokeWidth, 5)
    }

    func testToolSwitchClearsSelection() {
        let controller = makeLoadedController()
        let seg = SegmentElement(start: .zero, end: CGPoint(x: 100, y: 100))
        let arrow = Annotation.arrow(seg)
        controller.document?.elements.append(arrow)
        controller.selection = arrow.id
        XCTAssertNotNil(controller.selection)
        controller.tool = .rectangle
        XCTAssertNil(controller.selection)
    }
}
