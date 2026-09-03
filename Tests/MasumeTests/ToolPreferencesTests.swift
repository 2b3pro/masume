import XCTest
import CoreGraphics
import AnnotationModel
@testable import Masume

/// Tool selections survive across controllers sharing a store, standing in
/// for app launches. Sizes are remembered relative to the reference canvas.
@MainActor
final class ToolPreferencesTests: XCTestCase {

    private func image(_ w: Int, _ h: Int) -> CGImage {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    func testSelectionsSurviveIntoANewController() {
        let store = InMemoryToolPreferencesStore()
        let first = CanvasController(preferencesStore: store)
        first.loadImage(image(1200, 1000))          // reference canvas: widths are 1:1
        first.tool = .pen
        first.strokeWidth = 12
        first.strokeColor = .blue
        first.tool = .pixelate
        first.pixelateAmount = 20
        first.penOpacity = 0.4
        first.textStyle = .outline
        first.textOutlineColor = .black
        first.stampKind = .heart
        first.stampEmoji = "\u{1F525}"
        first.tool = .pen

        let second = CanvasController(preferencesStore: store)
        XCTAssertEqual(second.tool, .pen)
        XCTAssertEqual(second.strokeWidth, 12, "pen width remembered for the active tool")
        XCTAssertEqual(second.strokeColor, .blue)
        XCTAssertEqual(second.pixelateAmount, 20)
        XCTAssertEqual(second.penOpacity, 0.4)
        XCTAssertEqual(second.textStyle, .outline)
        XCTAssertEqual(second.textOutlineColor, .black)
        XCTAssertEqual(second.stampKind, .heart)
        XCTAssertEqual(second.stampEmoji, "\u{1F525}")
        second.tool = .arrow
        XCTAssertEqual(second.strokeWidth, DefaultStrokeWidth.segmentReferenceWidth, "untouched groups keep defaults")
    }

    func testRememberedSizesRescaleToTheNextImage() {
        let store = InMemoryToolPreferencesStore()
        let first = CanvasController(preferencesStore: store)
        first.loadImage(image(2400, 2000))          // 2x reference
        first.tool = .arrow
        first.strokeWidth = 40                       // reference 20
        first.tool = .pixelate
        first.pixelateAmount = 30                    // reference 15

        let second = CanvasController(preferencesStore: store)
        second.loadImage(image(1200, 1000))
        second.tool = .arrow
        XCTAssertEqual(second.strokeWidth, 20)
        XCTAssertEqual(second.pixelateAmount, 15)

        let third = CanvasController(preferencesStore: store)
        third.loadImage(image(600, 500))
        third.tool = .arrow
        XCTAssertEqual(third.strokeWidth, 10)
    }

    func testLoadingAnImageDoesNotDriftTheRememberedReference() {
        let store = InMemoryToolPreferencesStore()
        let c = CanvasController(preferencesStore: store)
        c.tool = .pixelate
        c.pixelateAmount = 50                        // reference 50
        c.loadImage(image(4800, 4000))               // 4x: 200 clamps to the 60 max
        XCTAssertEqual(c.pixelateAmount, RedactionElement.amountRange.upperBound)
        XCTAssertEqual(store.stored?.referencePixelateAmount, 50, "clamped display value must not overwrite the reference")
    }

    func testFreshStoreGivesDefaults() {
        let c = CanvasController(preferencesStore: InMemoryToolPreferencesStore())
        XCTAssertEqual(c.toolPreferences, ToolPreferences())
        XCTAssertEqual(c.tool, .arrow)
        XCTAssertEqual(c.strokeColor, .red)
        XCTAssertEqual(c.strokeWidth, DefaultStrokeWidth.segmentReferenceWidth)
    }

    func testUserDefaultsStoreRoundTrips() {
        let suite = "MasumeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsToolPreferencesStore(defaults: defaults)
        XCTAssertNil(store.load())
        var prefs = ToolPreferences()
        prefs.tool = .stamp
        prefs.referenceWidths[.shape] = 3
        prefs.strokeColor = .green
        store.save(prefs)
        XCTAssertEqual(store.load(), prefs)
    }

    func testPartialOrCorruptBlobFallsBackGracefully() throws {
        let partial = try JSONDecoder().decode(ToolPreferences.self,
                                               from: Data(#"{"tool":"pen","penOpacity":0.3}"#.utf8))
        XCTAssertEqual(partial.tool, .pen)
        XCTAssertEqual(partial.penOpacity, 0.3)
        XCTAssertEqual(partial.strokeColor, .red, "missing fields take defaults")
        XCTAssertEqual(partial.referenceWidths, ToolPreferences.defaultReferenceWidths)

        let suite = "MasumeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: UserDefaultsToolPreferencesStore.key)
        XCTAssertNil(UserDefaultsToolPreferencesStore(defaults: defaults).load())
    }
}
