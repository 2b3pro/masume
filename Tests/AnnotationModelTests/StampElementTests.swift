import XCTest
import CoreGraphics
@testable import AnnotationModel

final class StampElementTests: XCTestCase {

    private func stamp() -> StampElement {
        StampElement(center: CGPoint(x: 100, y: 100), radius: 20, kind: .check, color: .red)
    }

    func testDefaultPointerPointsDown() {
        let s = stamp()
        XCTAssertEqual(s.tailTip.x, 100, accuracy: 0.001)
        XCTAssertEqual(s.tailTip.y, 100 + 20 * StampElement.tailReach, accuracy: 0.001)
    }

    func testHitTestCoversDiskAndTailButNotFarAway() {
        let s = stamp()
        XCTAssertTrue(s.hitTest(CGPoint(x: 100, y: 100), tolerance: 0))
        XCTAssertTrue(s.hitTest(CGPoint(x: 118, y: 100), tolerance: 0))
        XCTAssertTrue(s.hitTest(CGPoint(x: 100, y: 128), tolerance: 0), "on the tail")
        XCTAssertFalse(s.hitTest(CGPoint(x: 100, y: 60), tolerance: 0))
        XCTAssertFalse(s.hitTest(CGPoint(x: 140, y: 140), tolerance: 0))
    }

    func testTailHandleSwingsThePointer() {
        var s = stamp()
        s.moveHandle(.end, to: CGPoint(x: 160, y: 100))   // drag the tip to the right
        XCTAssertEqual(s.pointerAngle, 0, accuracy: 0.001)
        XCTAssertEqual(s.tailTip.x, 100 + 20 * StampElement.tailReach, accuracy: 0.001)
        XCTAssertEqual(s.radius, 20, "swinging the tail must not resize")
    }

    /// Creation is click-then-drag: the drag point relative to the center
    /// sets the direction, and a jittery plain click leaves it pointing down.
    func testCreationDragSetsDirectionButClickJitterDoesNot() {
        var s = stamp()
        s.moveHandle(.end, to: CGPoint(x: 101, y: 99))     // 1-2px wobble
        XCTAssertEqual(s.pointerAngle, .pi / 2, accuracy: 0.001)
        s.moveHandle(.end, to: CGPoint(x: 100, y: 90))     // 10px up, beyond the dead zone
        XCTAssertEqual(s.pointerAngle, -.pi / 2, accuracy: 0.001)
        s.moveHandle(.end, to: CGPoint(x: 70, y: 100))     // then left
        XCTAssertEqual(abs(s.pointerAngle), .pi, accuracy: 0.001)
    }

    func testResizeHandleChangesRadiusAndClamps() {
        var s = stamp()
        s.moveHandle(.topRight, to: CGPoint(x: 130, y: 60))
        XCTAssertEqual(s.radius, 50, accuracy: 0.001)
        s.moveHandle(.topRight, to: CGPoint(x: 101, y: 100))
        XCTAssertEqual(s.radius, StampElement.radiusRange.lowerBound)
        XCTAssertEqual(s.center, CGPoint(x: 100, y: 100), "resizing keeps the center")
    }

    func testHandlesSitOnTipAndDiskEdge() {
        let s = stamp()
        let roles = s.handles().map(\.role)
        XCTAssertEqual(roles, [.end, .topRight])
        XCTAssertEqual(s.handles()[0].position, s.tailTip)
        XCTAssertEqual(GeometryMath.distance(from: s.handles()[1].position, to: s.center), 20, accuracy: 0.001)
    }

    func testBoundingBoxContainsDiskAndTip() {
        let s = stamp()
        let box = s.boundingBox()
        XCTAssertTrue(box.contains(s.diskRect))
        XCTAssertTrue(box.contains(s.tailTip))
    }

    func testTranslateMovesCenterAndTip() {
        var s = stamp()
        s.translate(by: CGVector(dx: 5, dy: -7))
        XCTAssertEqual(s.center, CGPoint(x: 105, y: 93))
        XCTAssertEqual(s.tailTip.x, 105, accuracy: 0.001)
    }

    // MARK: Numbered and lettered stamps

    func testLabelsCountInDigitsOrLetters() {
        var s = StampElement(center: .zero, kind: .number, ordinal: 1)
        XCTAssertEqual(s.label, "1")
        s.kind = .letter
        XCTAssertEqual(s.label, "A", "the count survives a kind switch")
        s.ordinal = 26; XCTAssertEqual(s.label, "Z")
        s.ordinal = 27; XCTAssertEqual(s.label, "AA")
        s.kind = .heart
        XCTAssertNil(s.label, "glyph stamps show no count")
        XCTAssertTrue(StampKind.number.isOrdinal); XCTAssertTrue(StampKind.letter.isOrdinal)
        XCTAssertFalse(StampKind.check.isOrdinal)
    }

    func testEmojiStampsShowTheirCharacterAndNormalizeInput() throws {
        var s = StampElement(center: .zero, kind: .emoji)
        XCTAssertEqual(s.label, StampElement.defaultEmoji, "a thumbs up until one is chosen")
        s.emoji = "\u{1F525}"
        XCTAssertEqual(s.label, "\u{1F525}")
        s.kind = .check
        XCTAssertNil(s.label)
        XCTAssertEqual(StampElement.normalizedEmoji("  \u{1F525} "), "\u{1F525}")
        XCTAssertEqual(StampElement.normalizedEmoji("\u{1F44D}\u{1F525}"), "\u{1F525}", "the last one typed wins")
        XCTAssertEqual(StampElement.normalizedEmoji("\u{1F44D}\u{1F3FD}"), "\u{1F44D}\u{1F3FD}", "a skin tone stays attached")
        XCTAssertEqual(StampElement.normalizedEmoji("\u{1F1EF}\u{1F1F5}"), "\u{1F1EF}\u{1F1F5}", "a flag stays whole")
        XCTAssertNil(StampElement.normalizedEmoji("  \n"))
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stamp())) as? [String: Any] ?? [:]
        legacy.removeValue(forKey: "emoji")
        let decoded = try JSONDecoder().decode(StampElement.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.emoji, StampElement.defaultEmoji, "older stamps decode with the default")
        var a = Annotation.stamp(StampElement(center: .zero, kind: .emoji, emoji: "\u{1F525}"))
        XCTAssertEqual(a.stampEmoji, "\u{1F525}")
        a.stampEmoji = "\u{2B50}"
        XCTAssertEqual(a.stampEmoji, "\u{2B50}")
        XCTAssertNil(Annotation.stamp(stamp()).stampEmoji, "glyph stamps expose no emoji")
    }

    func testStepClampsToTheOrdinalRange() {
        var s = StampElement(center: .zero, kind: .number, ordinal: 2)
        s.step(by: -1); XCTAssertEqual(s.ordinal, 1)
        s.step(by: -1); XCTAssertEqual(s.ordinal, 1, "never below 1")
        s.step(by: 5); XCTAssertEqual(s.ordinal, 6)
        s.ordinal = 999
        s.step(by: 1); XCTAssertEqual(s.ordinal, 999, "never past 999")
    }

    func testStampsSavedBeforeCountsDecodeWithOrdinalOne() throws {
        // What 0.3.0 wrote: no ordinal key.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stamp())) as? [String: Any] ?? [:]
        XCTAssertNotNil(legacy.removeValue(forKey: "ordinal"))
        let s = try JSONDecoder().decode(StampElement.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(s.ordinal, 1)
        XCTAssertEqual(s.kind, .check)
        let full = StampElement(center: .zero, kind: .letter, ordinal: 12)
        let round = try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(Annotation.stamp(full)))
        XCTAssertEqual(round, .stamp(full))
    }

    func testNextOrdinalIsOnePastTheHighestOfItsKind() {
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(doc.nextStampOrdinal(for: .number), 1, "the first flag is 1")
        doc.add(.stamp(StampElement(center: .zero, kind: .number, ordinal: 1)))
        doc.add(.stamp(StampElement(center: .zero, kind: .number, ordinal: 2)))
        doc.add(.stamp(StampElement(center: .zero, kind: .number, ordinal: 3)))
        XCTAssertEqual(doc.nextStampOrdinal(for: .number), 4)
        XCTAssertEqual(doc.nextStampOrdinal(for: .letter), 1, "letters count separately")
        doc.remove(doc.elements[1].id)
        XCTAssertEqual(doc.nextStampOrdinal(for: .number), 4, "a gap is not refilled, so labels never repeat")
        doc.add(.stamp(StampElement(center: .zero, kind: .check, ordinal: 40)))
        XCTAssertEqual(doc.nextStampOrdinal(for: .number), 4, "glyph stamps do not count")
    }

    func testShiftSnapsTheTailToFortyFiveDegrees() {
        var s = stamp()
        s.aimTail(at: CGPoint(x: 100 + 100, y: 100 + 30), snapping: true)   // about 17° below the x-axis
        XCTAssertEqual(s.pointerAngle, 0, accuracy: 1e-9, "rounds to the nearest 45°")
        s.aimTail(at: CGPoint(x: 100 + 100, y: 100 + 70), snapping: true)   // about 35°
        XCTAssertEqual(s.pointerAngle, .pi / 4, accuracy: 1e-9)
        s.aimTail(at: CGPoint(x: 100 - 10, y: 100 - 100), snapping: true)   // just left of straight up
        XCTAssertEqual(s.pointerAngle, -.pi / 2, accuracy: 1e-9)
        s.aimTail(at: CGPoint(x: 100 + 100, y: 100 + 30), snapping: false)
        XCTAssertEqual(s.pointerAngle, atan2(30, 100), accuracy: 1e-9, "unsnapped is exact")
        let before = s.pointerAngle
        s.aimTail(at: CGPoint(x: 101, y: 101), snapping: true)
        XCTAssertEqual(s.pointerAngle, before, "the dead zone still applies")
    }

    func testCodableRoundTrip() throws {
        let s = StampElement(center: CGPoint(x: 3, y: 4), radius: 12, kind: .heart, color: .pink, pointerAngle: 1.2)
        let data = try JSONEncoder().encode(Annotation.stamp(s))
        XCTAssertEqual(try JSONDecoder().decode(Annotation.self, from: data), .stamp(s))
    }

    func testAnnotationAccessors() {
        var a = Annotation.stamp(stamp())
        XCTAssertEqual(a.stampKind, .check)
        XCTAssertNil(a.strokeWidth)
        XCTAssertEqual(a.color, .red)
        a.stampKind = .question
        XCTAssertEqual(a.stampKind, .question)
        var arrow = Annotation.arrow(SegmentElement(start: .zero, end: CGPoint(x: 1, y: 1)))
        XCTAssertNil(arrow.stampKind)
        arrow.stampKind = .heart
        XCTAssertNil(arrow.stampKind)
    }

    func testClickPlacementKeepsStampSize() {
        let a = Annotation.stamp(stamp())
        XCTAssertEqual(a.applyingDefaultInitialSize(canvasSize: CGSize(width: 1200, height: 1000)), a)
    }

    func testDefaultRadiusScalesWithCanvas() {
        XCTAssertEqual(StampElement.defaultRadius(forCanvasSize: DefaultSizeScale.referenceCanvasSize),
                       StampElement.referenceRadius)
        XCTAssertEqual(StampElement.defaultRadius(forCanvasSize: CGSize(width: 2400, height: 2000)),
                       StampElement.referenceRadius * 2)
    }

    /// The tail tip is a grabbable handle when the stamp is selected.
    func testResolvePointerFindsTailHandle() {
        let s = stamp()
        let doc = Document(baseImage: .file(path: "/x.png"), canvasSize: CGSize(width: 400, height: 400),
                           elements: [.stamp(s)])
        XCTAssertEqual(doc.resolvePointer(at: s.tailTip, selection: s.id, bodyTolerance: 8, handleTolerance: 8),
                       .handle(s.id, .end))
    }
}
