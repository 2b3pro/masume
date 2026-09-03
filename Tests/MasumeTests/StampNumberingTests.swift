import XCTest
import AppKit
import AnnotationModel
@testable import Masume

/// Numbered and lettered stamps on the canvas: placing counts up, `+` and
/// `-` change a selected flag, the stamp row switches digits and letters,
/// and Shift snaps a tail drag to 45°. 1:1 zoom on a 400×400 image in a
/// 400×400 view, so model y = 400 − view y.
@MainActor
final class StampNumberingTests: XCTestCase {

    private func makeView() -> (CanvasNSView, CanvasController) {
        let ctx = CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore())
        controller.loadImage(ctx.makeImage()!)
        controller.zoomMode = .percent(1)
        controller.tool = .stamp
        controller.stampKind = .number
        controller.selectTool(.stamp)   // already active: locks it, so each click places another
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.controller = controller
        return (view, controller)
    }

    private func mouse(_ type: NSEvent.EventType, at p: CGPoint, shift: Bool = false) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func key(_ character: String, modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                         context: nil, characters: character, charactersIgnoringModifiers: character,
                         isARepeat: false, keyCode: keyCode)!
    }

    private func click(_ view: CanvasNSView, at p: CGPoint) {
        view.mouseDown(with: mouse(.leftMouseDown, at: p))
        view.mouseUp(with: mouse(.leftMouseUp, at: p))
    }

    private func stamps(_ controller: CanvasController) -> [StampElement] {
        controller.document?.elements.compactMap { if case .stamp(let s) = $0 { s } else { nil } } ?? []
    }

    func testPlacingFlagsCountsUpFromOne() {
        let (view, controller) = makeView()
        click(view, at: CGPoint(x: 50, y: 350))
        click(view, at: CGPoint(x: 150, y: 350))
        click(view, at: CGPoint(x: 250, y: 350))
        XCTAssertEqual(stamps(controller).map(\.label), ["1", "2", "3"])
        controller.selection = nil      // the row edits a selected stamp; deselect to change the next one
        controller.stampKind = .letter
        click(view, at: CGPoint(x: 350, y: 350))
        XCTAssertEqual(stamps(controller).last?.label, "A", "letters start their own count")
    }

    func testPlusAndMinusChangeTheSelectedFlagAsUndoSteps() {
        let (view, controller) = makeView()
        click(view, at: CGPoint(x: 50, y: 350))
        click(view, at: CGPoint(x: 150, y: 350))
        controller.selection = stamps(controller)[0].id
        view.keyDown(with: key("+"))
        view.keyDown(with: key("="))
        XCTAssertEqual(stamps(controller)[0].label, "3")
        view.keyDown(with: key("-"))
        view.keyDown(with: key("-"))
        view.keyDown(with: key("-"))
        XCTAssertEqual(stamps(controller)[0].label, "1", "clamped at 1")
        controller.undo()
        XCTAssertEqual(stamps(controller)[0].label, "2", "each key press is one undo step")
        XCTAssertEqual(stamps(controller)[1].label, "2", "the other flag is untouched")
    }

    func testKeysIgnoreGlyphStampsAndCommandChords() {
        let (view, controller) = makeView()
        controller.selection = nil
        controller.stampKind = .heart
        click(view, at: CGPoint(x: 50, y: 350))
        let placed = controller.document!
        view.keyDown(with: key("+"))
        view.keyDown(with: key("\t", keyCode: 48))
        XCTAssertEqual(controller.document, placed, "no edit for a glyph stamp")
        controller.selection = nil
        controller.stampKind = .number
        click(view, at: CGPoint(x: 150, y: 350))
        let before = controller.canUndo
        view.keyDown(with: key("-", modifiers: [.command]))
        XCTAssertEqual(stamps(controller)[1].ordinal, 1)
        XCTAssertEqual(controller.canUndo, before, "Cmd+- belongs to zoom, not the flag")
    }

    func testSwitchingKindsKeepsTheCountAndGlyphsJoinAtTheEnd() {
        let (view, controller) = makeView()
        click(view, at: CGPoint(x: 50, y: 350))
        click(view, at: CGPoint(x: 150, y: 350))
        controller.selection = stamps(controller)[1].id
        controller.stampKind = .letter
        XCTAssertEqual(stamps(controller)[1].label, "B", "2 becomes B")
        controller.stampKind = .number
        XCTAssertEqual(stamps(controller)[1].label, "2")
        view.keyDown(with: key("\t", keyCode: 48))
        XCTAssertEqual(stamps(controller)[1].label, "B", "Tab toggles the selected flag")
        XCTAssertEqual(controller.stampKind, .letter, "and the palette follows")
        view.keyDown(with: key("\t", keyCode: 48))
        XCTAssertEqual(stamps(controller)[1].label, "2")
        controller.selection = nil
        controller.stampKind = .check
        click(view, at: CGPoint(x: 250, y: 350))
        controller.selection = stamps(controller)[2].id
        controller.stampKind = .number
        XCTAssertEqual(stamps(controller)[2].label, "3", "a glyph stamp turned flag takes the next count")
    }

    func testShiftSnapsTheTailWhilePlacingAndWhenReaimed() {
        let (view, controller) = makeView()
        // Place at model (200, 200) and drag the tail toward 20° below the x-axis with Shift.
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 200, y: 200)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 300, y: 200 - 36), shift: true))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 300, y: 200 - 36), shift: true))
        XCTAssertEqual(stamps(controller)[0].pointerAngle, 0, accuracy: 1e-9, "snapped to the x-axis")
        // Re-aim through the tail handle without Shift: exact.
        let tip = stamps(controller)[0].tailTip
        controller.tool = .select          // clears the selection; handles need it back
        controller.selection = stamps(controller)[0].id
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: tip.x, y: 400 - tip.y)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 300, y: 200 - 36)))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 300, y: 200 - 36)))
        XCTAssertEqual(stamps(controller)[0].pointerAngle, atan2(36, 100), accuracy: 1e-9)
        // And with Shift again, from the new tip: snaps to 45°.
        let tip2 = stamps(controller)[0].tailTip
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: tip2.x, y: 400 - tip2.y)))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 290, y: 200 - 70), shift: true))
        view.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 290, y: 200 - 70), shift: true))
        XCTAssertEqual(stamps(controller)[0].pointerAngle, .pi / 4, accuracy: 1e-9)
    }
}
