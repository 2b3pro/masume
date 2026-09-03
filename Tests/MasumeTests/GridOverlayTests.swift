import XCTest
import CoreGraphics
@testable import Masume

/// The overlay's thinning rules, and the toggle's persistence.
@MainActor
final class GridOverlayTests: XCTestCase {

    func testLabelsThinAsCellsShrinkAndLinesHideBelowSixPoints() {
        XCTAssertEqual(GridOverlayMath.labelStride(cellPoints: 100), 1)
        XCTAssertEqual(GridOverlayMath.labelStride(cellPoints: 24), 1)
        XCTAssertEqual(GridOverlayMath.labelStride(cellPoints: 23), 2)
        XCTAssertEqual(GridOverlayMath.labelStride(cellPoints: 12), 2)
        XCTAssertEqual(GridOverlayMath.labelStride(cellPoints: 8), 3)
        XCTAssertEqual(GridOverlayMath.labelStride(cellPoints: 6), 4)
        XCTAssertNil(GridOverlayMath.labelStride(cellPoints: 5.9))
    }

    func testShowsGridIsRememberedAcrossControllers() {
        let key = "showsGrid"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let a = CanvasController(preferencesStore: InMemoryToolPreferencesStore())
        a.showsGrid = true
        XCTAssertTrue(CanvasController(preferencesStore: InMemoryToolPreferencesStore()).showsGrid)
        a.showsGrid = false
        XCTAssertFalse(CanvasController(preferencesStore: InMemoryToolPreferencesStore()).showsGrid)
    }

    func testGridDrawsWithoutTouchingTheDocumentOrExport() throws {
        // Drawing the grid is a pure side effect on the context: the document
        // is unchanged and the flattened export has no grid pixels.
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore(),
                                          recoveryStore: RecoveryStore(directory: FileManager.default.temporaryDirectory
                                            .appendingPathComponent("masume-grid-\(UUID().uuidString)")))
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        controller.loadImage(ctx.makeImage()!)
        controller.showsGrid = true
        controller.zoomMode = .percent(1)
        let view = CanvasNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.controller = controller
        let before = controller.document
        let revision = controller.project?.revision
        // Render the view into an offscreen bitmap so draw(_:) runs.
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertEqual(controller.document, before)
        XCTAssertEqual(controller.project?.revision, revision)
        // The export is still pure white: no grid line anywhere.
        let png = try XCTUnwrap(ExportService.pngData(controller))
        let image = try XCTUnwrap(ImageLoader.cgImage(from: png))
        var buf = [UInt8](repeating: 0, count: 400 * 300 * 4)
        let check = CGContext(data: &buf, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 1600,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        check.draw(image, in: CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertTrue(buf.allSatisfy { $0 == 255 }, "exports never carry the grid")
    }
}
