import XCTest
import CoreGraphics
import AnnotationModel
@testable import Masume

/// Grid density as a document action, and the grid surviving crop, save,
/// and open.
@MainActor
final class GridDocumentTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("masume-grid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeController(width: Int = 1440, height: Int = 900) -> CanvasController {
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore(),
                                          recoveryStore: RecoveryStore(directory: scratch.appendingPathComponent("r")))
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        controller.loadImage(ctx.makeImage()!)
        return controller
    }

    func testImportedImageGetsTheDefaultGrid() {
        XCTAssertEqual(makeController().document?.grid, GridDefinition(columns: 12, rows: 8))
        XCTAssertEqual(makeController(width: 1170, height: 2532).document?.grid, GridDefinition(columns: 7, rows: 16))
    }

    func testChangingDensityIsUndoableAndRecordedAndBumpsTheVersion() throws {
        let controller = makeController()
        controller.setGridPreset(24)
        XCTAssertEqual(controller.document?.grid, GridDefinition(columns: 24, rows: 15, version: 2))
        let project = try XCTUnwrap(controller.project)
        XCTAssertEqual(project.revision, 1)
        XCTAssertTrue(project.history.last?.summary.hasSuffix("changed the grid to 24\u{00D7}15") == true)
        controller.setGridPreset(24)
        XCTAssertEqual(project.revision, 1, "picking the current density is not a change")
        controller.setGridPreset(99)
        XCTAssertEqual(project.revision, 1, "not a preset")
        controller.undo()
        XCTAssertEqual(controller.document?.grid, GridDefinition(columns: 12, rows: 8, version: 1))
        XCTAssertEqual(try ProjectPackage.read(at: project.recoveryURL).manifest.grid,
                       GridDefinition(columns: 12, rows: 8, version: 1))
    }

    func testApplyingACropRederivesTheGridForTheNewSize() {
        let controller = makeController()
        controller.perform { $0.crop = CGRect(x: 0, y: 0, width: 600, height: 300) }
        controller.applyCrop()
        XCTAssertEqual(controller.document?.grid, GridDefinition(columns: 12, rows: 6, version: 2),
                       "same preset (the default tier, 12), re-derived for 600×300, new version")
    }

    func testSavedGridComesBackExactlyEvenIfTheDefaultWouldDiffer() throws {
        let controller = makeController()
        controller.setGridPreset(32)
        let url = scratch.appendingPathComponent("G.masume")
        try controller.saveProject(to: url, newIdentity: false)
        let reader = CanvasController(preferencesStore: InMemoryToolPreferencesStore(),
                                      recoveryStore: RecoveryStore(directory: scratch.appendingPathComponent("r2")))
        try reader.openProject(at: url)
        XCTAssertEqual(reader.document?.grid, GridDefinition(columns: 32, rows: 20, version: 2))
    }
}
