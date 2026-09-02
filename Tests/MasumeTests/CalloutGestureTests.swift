import XCTest
import AppKit
import AnnotationModel
import AnnotationRender
@testable import Masume

/// Drives `CanvasNSView` with synthetic mouse events to cover the callout
/// tool's tail-first gesture: the mouse-down is the tail tip, the drag
/// carries the bubble, and mouse-up opens the inline editor. The view has no
/// window, so event locations are view coordinates; with 1:1 zoom on a
/// 400×400 image in a 400×400 view, model y = 400 − view y. (The image is
/// larger than in the other gesture tests so a bubble at its default width
/// fits inside it; one that spills past the edge grows the expand-to-fit
/// canvas and shifts the mapping mid-test.)
@MainActor
final class CalloutGestureTests: XCTestCase {

    private func makeView() -> (CanvasNSView, CanvasController) {
        let ctx = CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore())
        controller.loadImage(ctx.makeImage()!)
        controller.zoomMode = .percent(1)
        controller.tool = .callout
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.controller = controller
        return (view, controller)
    }

    private func event(_ type: NSEvent.EventType, at p: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func text(_ controller: CanvasController) -> TextElement? {
        guard case .text(let t)? = controller.document?.elements.first else { return nil }
        return t
    }

    private func editor(in view: CanvasNSView) -> NSTextView? {
        view.subviews.compactMap { $0 as? NSTextView }.first
    }

    func testDragFromTheTipCarriesTheBubbleAndOpensTheEditor() {
        let (view, controller) = makeView()
        controller.strokeColor = .blue
        controller.textOutlineColor = .black
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 40, y: 360)))   // model (40, 40)
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 200, y: 260))) // model (200, 140)
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 200, y: 260)))

        guard let t = text(controller) else { return XCTFail("expected a text element") }
        XCTAssertEqual(t.container?.tailTip, CGPoint(x: 40, y: 40), "the mouse-down point is the tail tip")
        XCTAssertEqual(t.container?.shape, controller.calloutShape)
        XCTAssertEqual(t.rect.midX, 200, accuracy: 0.5, "the bubble follows the drag")
        XCTAssertEqual(t.rect.midY, 140, accuracy: 0.5)
        XCTAssertEqual(t.alignment, .center)
        XCTAssertEqual(t.color, .blue)
        XCTAssertEqual(t.outlineColor, .black)
        XCTAssertEqual(controller.selection, t.id)
        XCTAssertTrue(controller.isEditingText, "mouse-up opens the inline editor")
        XCTAssertNotNil(editor(in: view))
        XCTAssertEqual(editor(in: view)?.alignment, .center)
    }

    func testPlainClickPlacesTheBubbleAboveAndRightOfTheTip() {
        let (view, controller) = makeView()
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 60, y: 340)))   // model (60, 60)
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 60, y: 340)))
        guard let t = text(controller) else { return XCTFail("expected a text element") }
        XCTAssertEqual(t.container?.tailTip, CGPoint(x: 60, y: 60))
        XCTAssertGreaterThan(t.rect.minX, 60)
        XCTAssertLessThan(t.rect.maxY, 60)
        XCTAssertNotNil(t.calloutTail(), "the default placement leaves the tail visible")
        XCTAssertTrue(controller.isEditingText)
    }

    func testTypedTextCommitsIntoTheCalloutAndResizesIt() {
        let (view, controller) = makeView()
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 60, y: 300)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 60, y: 300)))
        guard let tv = editor(in: view) else { return XCTFail("no editor") }
        tv.string = "Hello\nthere"
        view.commitTextEditing()
        guard let t = text(controller) else { return XCTFail("expected a text element") }
        XCTAssertEqual(t.string, "Hello\nthere")
        XCTAssertNotNil(t.container, "committing keeps the bubble")
        XCTAssertEqual(t.size.height, Renderer.suggestedSize(for: t).height, accuracy: 0.5)
        XCTAssertFalse(controller.isEditingText)
    }

    func testEmptyCalloutIsRemovedWhenEditingEnds() {
        let (view, controller) = makeView()
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 60, y: 300)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 60, y: 300)))
        XCTAssertEqual(controller.document?.elements.count, 1)
        view.commitTextEditing()
        XCTAssertEqual(controller.document?.elements.count, 0)
        XCTAssertNil(controller.selection)
    }

    func testTailHandleDragMovesTheTipAfterwards() {
        let (view, controller) = makeView()
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 40, y: 360)))   // tip at model (40, 40)
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 200, y: 260)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 200, y: 260)))
        editor(in: view)?.string = "Hi"
        view.commitTextEditing()
        guard let id = text(controller)?.id else { return XCTFail("expected a text element") }
        controller.tool = .select
        controller.selection = id

        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 40, y: 360)))   // grab the tail tip
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 20, y: 380))) // model (20, 20)
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 20, y: 380)))
        XCTAssertEqual(text(controller)?.container?.tailTip, CGPoint(x: 20, y: 20))
        XCTAssertEqual(text(controller)?.rect.midX ?? 0, 200, accuracy: 0.5, "the bubble stays put")
    }
}

/// Controller-side behaviour: alignment and bubble shape as remembered
/// tool state that also edits the selection, and wrapping plain text.
@MainActor
final class CalloutControllerTests: XCTestCase {

    private func makeController() -> (CanvasController, InMemoryToolPreferencesStore) {
        let store = InMemoryToolPreferencesStore()
        let controller = CanvasController(preferencesStore: store)
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        controller.loadImage(ctx.makeImage()!)
        return (controller, store)
    }

    @discardableResult
    private func addText(_ controller: CanvasController, callout: Bool) -> ElementID {
        var t = TextElement(origin: CGPoint(x: 50, y: 50), size: CGSize(width: 200, height: 40), string: "hi")
        if callout { t.makeCallout(.speech) }
        controller.perform { $0.add(.text(t)) }
        return t.id
    }

    private func text(_ controller: CanvasController, _ id: ElementID) -> TextElement? {
        guard let element = controller.document?.elements.first(where: { $0.id == id }),
              case .text(let t) = element else { return nil }
        return t
    }

    func testAlignmentEditsTheSelectionAndIsRemembered() {
        let (controller, store) = makeController()
        let id = addText(controller, callout: false)
        controller.selection = id
        controller.textAlignment = .right
        XCTAssertEqual(text(controller, id)?.alignment, .right)
        XCTAssertEqual(store.stored?.textAlignment, .right)
        XCTAssertTrue(controller.canUndo)
        controller.undo()
        XCTAssertEqual(text(controller, id)?.alignment, .left, "one undo step per change")
    }

    func testShapeEditsOnlyASelectedCallout() {
        let (controller, store) = makeController()
        let plain = addText(controller, callout: false)
        controller.selection = plain
        controller.calloutShape = .thought
        XCTAssertNil(text(controller, plain)?.container, "plain text stays plain")
        XCTAssertEqual(store.stored?.calloutShape, .thought)

        let bubble = addText(controller, callout: true)
        controller.selection = bubble
        XCTAssertEqual(controller.calloutShape, .speech, "selecting adopts the callout's shape")
        controller.calloutShape = .thought
        XCTAssertEqual(text(controller, bubble)?.container?.shape, .thought)
    }

    func testSelectingAdoptsAlignment() {
        let (controller, _) = makeController()
        var t = TextElement(origin: .zero, string: "x")
        t.alignment = .center
        controller.perform { $0.add(.text(t)) }
        controller.selection = t.id
        XCTAssertEqual(controller.textAlignment, .center)
    }

    func testBubbleWrapsAndUnwrapsSelectedText() {
        let (controller, _) = makeController()
        let id = addText(controller, callout: false)
        controller.selection = id
        let before = text(controller, id)!
        XCTAssertNil(controller.selectedBubble)

        controller.setSelectedBubble(.speech)
        guard let wrapped = text(controller, id) else { return XCTFail("lost the element") }
        XCTAssertEqual(wrapped.container?.shape, .speech)
        XCTAssertEqual(controller.selectedBubble, .speech)
        XCTAssertEqual(wrapped.textRect.width, before.rect.width, accuracy: 0.5, "text keeps its width")
        XCTAssertEqual(wrapped.size.height, Renderer.suggestedSize(for: wrapped).height, accuracy: 0.5)

        controller.setSelectedBubble(nil)
        guard let unwrapped = text(controller, id) else { return XCTFail("lost the element") }
        XCTAssertNil(unwrapped.container)
        XCTAssertEqual(unwrapped.rect.width, before.rect.width, accuracy: 0.5)
        XCTAssertNil(controller.selectedBubble)
    }

    func testAccessoryVisibilityFlags() {
        let (controller, _) = makeController()
        controller.tool = .callout
        XCTAssertTrue(controller.editsCalloutShape)
        XCTAssertTrue(controller.editsTextAlignment)
        XCTAssertFalse(controller.editsTextStyle, "halo and outline do not apply to bubbles")

        controller.tool = .text
        XCTAssertTrue(controller.editsTextStyle)
        XCTAssertTrue(controller.editsTextAlignment)
        XCTAssertFalse(controller.editsCalloutShape)

        controller.tool = .select
        XCTAssertFalse(controller.editsTextAlignment)
        let bubble = addText(controller, callout: true)
        controller.selection = bubble
        XCTAssertTrue(controller.editsCalloutShape)
        XCTAssertTrue(controller.editsTextAlignment)
        XCTAssertFalse(controller.editsTextStyle)
    }

    func testPreferencesRoundTripNewFields() throws {
        var prefs = ToolPreferences()
        prefs.textAlignment = .center
        prefs.calloutShape = .thought
        let data = try JSONEncoder().encode(prefs)
        XCTAssertEqual(try JSONDecoder().decode(ToolPreferences.self, from: data), prefs)
        let legacy = try JSONDecoder().decode(ToolPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.textAlignment, .left)
        XCTAssertEqual(legacy.calloutShape, .speech)
    }
}
