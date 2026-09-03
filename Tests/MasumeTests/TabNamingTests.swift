import XCTest
import CoreGraphics
import AnnotationModel
@testable import Masume

/// Tab titles: Untitled until named, renamed in place, and the name
/// surviving recovery and following a saved project on disk.
@MainActor
final class TabNamingTests: XCTestCase {

    private var scratch: URL!
    private var store: RecoveryStore!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("masume-name-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = RecoveryStore(directory: scratch.appendingPathComponent("recovery"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeController() throws -> CanvasController {
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore(), recoveryStore: store)
        let ctx = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let png = try XCTUnwrap(ExportService.pngData(CanvasController(preferencesStore: InMemoryToolPreferencesStore())) ?? {
            let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore(), recoveryStore: store)
            controller.loadImage(ctx.makeImage()!)
            defer { controller.discardRecovery() }
            return ExportService.pngData(controller)
        }())
        let file = scratch.appendingPathComponent("screenshot.png")
        try png.write(to: file)
        controller.loadImage(at: file)
        return controller
    }

    func testImportedFileIsUntitledUntilNamed() throws {
        let controller = try makeController()
        XCTAssertEqual(controller.documentTitle, "Untitled", "the file name is not the tab name")
        XCTAssertEqual(controller.sourceURL?.lastPathComponent, "screenshot.png", "but it is kept for export naming")
        try controller.renameDocument(to: "  Login bug  ")
        XCTAssertEqual(controller.documentTitle, "Login bug")
        XCTAssertEqual(controller.project?.workingName, "Login bug")
        XCTAssertThrowsError(try controller.renameDocument(to: "   "))
        XCTAssertThrowsError(try controller.renameDocument(to: "a/b"))
        XCTAssertEqual(controller.documentTitle, "Login bug")
    }

    func testWorkingNameSurvivesRecoveryAndSeedsTheManifest() throws {
        let controller = try makeController()
        try controller.renameDocument(to: "Header")
        XCTAssertEqual(try ProjectPackage.read(at: try XCTUnwrap(controller.project).recoveryURL).manifest.workingName, "Header")
        let relaunch = WorkspaceController(confirmDiscard: { _, _, _ in true }, confirmSave: { _ in .cancel },
                                           requestTermination: {}, recoveryStore: store)
        XCTAssertEqual(relaunch.tabs.count, 1)
        XCTAssertEqual(relaunch.active.documentTitle, "Header")
    }

    func testRenamingASavedProjectMovesThePackage() throws {
        let controller = try makeController()
        let url = scratch.appendingPathComponent("First.masume")
        try controller.saveProject(to: url, newIdentity: false)
        XCTAssertEqual(controller.documentTitle, "First")
        try controller.renameDocument(to: "Second")
        let moved = scratch.appendingPathComponent("Second.masume")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(controller.project?.projectURL?.path, moved.path)
        XCTAssertEqual(controller.documentTitle, "Second")
        XCTAssertFalse(controller.isDirty, "a rename is not an edit")
        XCTAssertEqual(try ProjectPackage.read(at: try XCTUnwrap(controller.project).recoveryURL).manifest.boundProjectPath,
                       moved.path, "recovery follows the move")
        // A sibling with the name already: refused, nothing moves.
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("Taken.masume"),
                                                withIntermediateDirectories: true)
        XCTAssertThrowsError(try controller.renameDocument(to: "Taken"))
        XCTAssertEqual(controller.project?.projectURL?.path, moved.path)
    }

    func testEmptyTabCannotBeRenamed() {
        let workspace = WorkspaceController(confirmDiscard: { _, _, _ in true }, confirmSave: { _ in .cancel },
                                            requestTermination: {}, recoveryStore: store)
        workspace.rename(workspace.active, to: "Nope")
        XCTAssertEqual(workspace.active.documentTitle, "Untitled")
    }
}
