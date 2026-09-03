import XCTest
import CoreGraphics
import AnnotationModel
@testable import Masume

/// The controller's commit funnel: every committed change bumps the
/// revision, appends a history entry, and lands in the recovery package
/// right away. Recovery starts at import, before any edit or save.
@MainActor
final class ProjectSessionTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("masume-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func image(_ w: Int = 40, _ h: Int = 30) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func makeController(directory: URL? = nil) -> CanvasController {
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore(),
                                          recoveryStore: RecoveryStore(directory: directory ?? scratch))
        controller.loadImage(image())
        return controller
    }

    private func recovery(_ controller: CanvasController) throws -> ProjectPackage.Contents {
        try ProjectPackage.read(at: try XCTUnwrap(controller.project).recoveryURL)
    }

    func testImportWritesTheRecoveryPackageBeforeAnyEdit() throws {
        let controller = makeController()
        let project = try XCTUnwrap(controller.project)
        XCTAssertEqual(project.revision, 0)
        XCTAssertTrue(project.isDirty, "never saved")
        XCTAssertNil(project.projectURL)
        let contents = try recovery(controller)
        XCTAssertEqual(contents.manifest.id, project.id)
        XCTAssertEqual(contents.manifest.revision, 0)
        XCTAssertEqual(contents.manifest.canvasSize, CGSize(width: 40, height: 30))
        XCTAssertEqual(contents.manifest.elements, [])
        XCTAssertEqual(ProjectPackage.pngPixelSize(contents.baseImagePNG)?.width, 40)
        XCTAssertEqual(contents.history, [])
        XCTAssertEqual(RecoveryStore(directory: scratch).packages().count, 1)
    }

    func testEachCommitBumpsRevisionAppendsHistoryAndAutosaves() throws {
        let controller = makeController()
        let arrow = SegmentElement(start: .zero, end: CGPoint(x: 10, y: 10))
        controller.perform { $0.add(.arrow(arrow)) }
        let project = try XCTUnwrap(controller.project)
        XCTAssertEqual(project.revision, 1)
        XCTAssertEqual(project.history.count, 1)
        XCTAssertEqual(project.history.last?.summary, "\(project.actor.name) added arrow \(HistorySummary.shortID(arrow.id))")
        XCTAssertEqual(project.history.last?.actor.id, "human")
        var contents = try recovery(controller)
        XCTAssertEqual(contents.manifest.revision, 1)
        XCTAssertEqual(contents.manifest.elements, [.arrow(arrow)])
        XCTAssertEqual(contents.history.count, 1)

        // A drag-style interaction commits once at its end.
        controller.beginInteraction()
        controller.document?.mutate(arrow.id) { $0.translate(by: CGVector(dx: 5, dy: 5)) }
        controller.commitInteraction()
        XCTAssertEqual(project.revision, 2)
        XCTAssertEqual(project.history.last?.summary, "\(project.actor.name) changed arrow \(HistorySummary.shortID(arrow.id))")
        contents = try recovery(controller)
        XCTAssertEqual(contents.manifest.revision, 2)
        XCTAssertEqual(contents.history.count, 2)
        XCTAssertNil(project.autosaveError)
    }

    func testAnInteractionWithoutChangeIsNotACommit() throws {
        let controller = makeController()
        controller.beginInteraction()
        controller.commitInteraction()
        controller.perform { _ in }
        XCTAssertEqual(controller.project?.revision, 0)
        XCTAssertEqual(try recovery(controller).history.count, 0)
    }

    func testUndoAndRedoAreCommitsDescribedByWhatTheyDid() throws {
        let controller = makeController()
        let arrow = SegmentElement(start: .zero, end: CGPoint(x: 10, y: 10))
        controller.perform { $0.add(.arrow(arrow)) }
        controller.undo()
        let project = try XCTUnwrap(controller.project)
        XCTAssertEqual(project.revision, 2, "undo is a new revision, not a rewind")
        XCTAssertEqual(project.history.last?.summary, "\(project.actor.name) deleted arrow \(HistorySummary.shortID(arrow.id))")
        controller.redo()
        XCTAssertEqual(project.revision, 3)
        XCTAssertEqual(project.history.last?.summary, "\(project.actor.name) added arrow \(HistorySummary.shortID(arrow.id))")
        XCTAssertEqual(try recovery(controller).manifest.revision, 3)
        XCTAssertEqual(try recovery(controller).history.map(\.revisionAfter), [1, 2, 3])
    }

    func testApplyingACropRewritesTheBaseImageInRecovery() throws {
        let controller = makeController()
        controller.perform { $0.crop = CGRect(x: 5, y: 5, width: 10, height: 8) }
        controller.applyCrop()
        let project = try XCTUnwrap(controller.project)
        XCTAssertEqual(project.revision, 2)
        var contents = try recovery(controller)
        XCTAssertEqual(contents.manifest.canvasSize, CGSize(width: 10, height: 8))
        XCTAssertEqual(ProjectPackage.pngPixelSize(contents.baseImagePNG)?.width, 10)
        XCTAssertEqual(contents.history.count, 2, "history survives the package rewrite")

        controller.undo()
        contents = try recovery(controller)
        XCTAssertEqual(contents.manifest.canvasSize, CGSize(width: 40, height: 30))
        XCTAssertEqual(ProjectPackage.pngPixelSize(contents.baseImagePNG)?.width, 40)
        XCTAssertEqual(contents.history.count, 3)
    }

    func testAutosaveFailureIsShownAndTheDocumentStaysDirty() throws {
        // A regular file where the recovery directory should be: nothing can
        // be written there.
        let blocked = scratch.appendingPathComponent("blocked")
        try Data("x".utf8).write(to: blocked)
        let controller = makeController(directory: blocked)
        let project = try XCTUnwrap(controller.project)
        XCTAssertNotNil(project.autosaveError)
        XCTAssertEqual(controller.toastMessage?.hasPrefix("Recovery autosave failed"), true)
        controller.perform { $0.add(.arrow(SegmentElement(start: .zero, end: CGPoint(x: 1, y: 1)))) }
        XCTAssertEqual(project.revision, 1, "the in-memory commit still happens")
        XCTAssertTrue(project.isDirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.recoveryURL.path))
    }

    func testRemovingRecoveryDeletesThePackage() throws {
        let controller = makeController()
        let project = try XCTUnwrap(controller.project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.recoveryURL.path))
        project.removeRecovery()
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.recoveryURL.path))
    }
}
