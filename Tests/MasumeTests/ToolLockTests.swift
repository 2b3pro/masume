import XCTest
import AppKit
import AnnotationModel
@testable import Masume

/// One-shot tools: after placing an annotation the tool hands back to
/// Select so the instinctive "click the canvas to drop the tool" deselects
/// instead of creating another. Clicking the active tool again locks it
/// (a "+" badge) so it keeps creating. Pen is always sticky.
@MainActor
final class ToolLockTests: XCTestCase {

    private func makeView(tool: Tool) -> (CanvasNSView, CanvasController) {
        let ctx = CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore())
        controller.loadImage(ctx.makeImage()!)
        controller.zoomMode = .percent(1)
        controller.tool = tool
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.controller = controller
        return (view, controller)
    }

    private func event(_ type: NSEvent.EventType, at p: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func click(_ view: CanvasNSView, at p: CGPoint) {
        view.mouseDown(with: event(.leftMouseDown, at: p))
        view.mouseUp(with: event(.leftMouseUp, at: p))
    }

    // MARK: Lock toggling

    func testSelectingTheActiveToolTogglesItsLock() {
        let (_, controller) = makeView(tool: .arrow)
        XCTAssertFalse(controller.isLocked(.rectangle))
        controller.selectTool(.rectangle)
        XCTAssertEqual(controller.tool, .rectangle)
        XCTAssertFalse(controller.isLocked(.rectangle), "first pick just activates")
        controller.selectTool(.rectangle)
        XCTAssertTrue(controller.isLocked(.rectangle), "picking the active tool again locks it")
        controller.selectTool(.rectangle)
        XCTAssertFalse(controller.isLocked(.rectangle), "and again unlocks")
    }

    func testSelectPenAndCropCannotBeLocked() {
        let (_, controller) = makeView(tool: .arrow)
        for tool in [Tool.select, .pen, .crop] {
            controller.selectTool(tool)
            controller.selectTool(tool)
            XCTAssertFalse(controller.isLocked(tool), "\(tool) is not a one-shot tool")
        }
    }

    // MARK: One-shot placement

    func testUnlockedShapeToolHandsBackToSelectKeepingTheNewShapeSelected() {
        let (view, controller) = makeView(tool: .rectangle)
        click(view, at: CGPoint(x: 100, y: 300))
        XCTAssertEqual(controller.document?.elements.count, 1)
        XCTAssertEqual(controller.tool, .select)
        XCTAssertEqual(controller.selection, controller.document?.elements.first?.id,
                       "the new shape stays selected for handle adjustment")
        // The instinctive second click deselects instead of creating.
        click(view, at: CGPoint(x: 300, y: 100))
        XCTAssertEqual(controller.document?.elements.count, 1)
        XCTAssertNil(controller.selection)
    }

    func testLockedShapeToolKeepsCreating() {
        let (view, controller) = makeView(tool: .rectangle)
        controller.selectTool(.rectangle)   // already active: locks it
        click(view, at: CGPoint(x: 100, y: 300))
        click(view, at: CGPoint(x: 300, y: 100))
        XCTAssertEqual(controller.document?.elements.count, 2)
        XCTAssertEqual(controller.tool, .rectangle)
    }

    func testPenStaysStickyWithoutALock() {
        let (view, controller) = makeView(tool: .pen)
        click(view, at: CGPoint(x: 100, y: 300))
        click(view, at: CGPoint(x: 300, y: 100))
        XCTAssertEqual(controller.document?.elements.count, 2)
        XCTAssertEqual(controller.tool, .pen)
    }

    func testStampAndArrowAreOneShot() {
        for tool in [Tool.stamp, .arrow, .pixelate, .line, .ellipse] {
            let (view, controller) = makeView(tool: tool)
            click(view, at: CGPoint(x: 100, y: 300))
            XCTAssertEqual(controller.tool, .select, "\(tool) should hand back to Select")
        }
    }

    // MARK: Text and callouts revert when editing ends

    func testTextToolRevertsWhenTheCanvasClickEndsEditing() {
        let (view, controller) = makeView(tool: .text)
        click(view, at: CGPoint(x: 100, y: 300))
        XCTAssertTrue(controller.isEditingText)
        XCTAssertEqual(controller.tool, .text, "still the text tool while typing")
        view.subviews.compactMap { $0 as? NSTextView }.first?.string = "note"
        // Clicking elsewhere commits the text; it must not start another box.
        click(view, at: CGPoint(x: 300, y: 100))
        XCTAssertFalse(controller.isEditingText)
        XCTAssertEqual(controller.document?.elements.count, 1)
        XCTAssertEqual(controller.tool, .select)
    }

    func testCalloutToolRevertsAfterItsTextCommits() {
        let (view, controller) = makeView(tool: .callout)
        click(view, at: CGPoint(x: 60, y: 300))
        XCTAssertEqual(controller.tool, .callout, "still the callout tool while typing")
        view.subviews.compactMap { $0 as? NSTextView }.first?.string = "hey"
        view.commitTextEditing()
        XCTAssertEqual(controller.tool, .select)
        XCTAssertEqual(controller.selection, controller.document?.elements.first?.id)
    }

    func testLockedTextToolKeepsCreating() {
        let (view, controller) = makeView(tool: .text)
        controller.selectTool(.text)
        click(view, at: CGPoint(x: 100, y: 300))
        view.subviews.compactMap { $0 as? NSTextView }.first?.string = "one"
        click(view, at: CGPoint(x: 300, y: 100))
        XCTAssertEqual(controller.tool, .text)
        XCTAssertEqual(controller.document?.elements.count, 2, "the second click starts another box")
    }

    func testLocksAreNotPersisted() throws {
        let (_, controller) = makeView(tool: .arrow)
        controller.selectTool(.arrow)
        XCTAssertTrue(controller.isLocked(.arrow))
        let data = try JSONEncoder().encode(controller.toolPreferences)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.lowercased().contains("lock"))
    }
}
