import XCTest
import CoreGraphics
import AnnotationModel
@testable import Masume

/// The unredacted-original disclosure policy and the share-safe copy.
@MainActor
final class DisclosureAndShareSafeTests: XCTestCase {

    private var scratch: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("masume-disclosure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        suiteName = "masume.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeController() -> CanvasController {
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore(),
                                          recoveryStore: RecoveryStore(directory: scratch.appendingPathComponent("r")))
        let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        controller.loadImage(ctx.makeImage()!)
        return controller
    }

    func testDisclosureShowsOncePerDocument() throws {
        let first = try XCTUnwrap(makeController().project)
        XCTAssertTrue(RedactionDisclosure.shouldShow(project: first, defaults: defaults))
        RedactionDisclosure.recordShown(project: first, suppress: false, defaults: defaults)
        XCTAssertFalse(RedactionDisclosure.shouldShow(project: first, defaults: defaults), "not again for this document")
        let second = try XCTUnwrap(makeController().project)
        XCTAssertTrue(RedactionDisclosure.shouldShow(project: second, defaults: defaults), "but yes for the next one")
    }

    func testOptOutSilencesEveryDocument() throws {
        let first = try XCTUnwrap(makeController().project)
        RedactionDisclosure.recordShown(project: first, suppress: true, defaults: defaults)
        let second = try XCTUnwrap(makeController().project)
        XCTAssertFalse(RedactionDisclosure.shouldShow(project: second, defaults: defaults))
        XCTAssertTrue(defaults.bool(forKey: RedactionDisclosure.suppressKey))
    }

    func testDisclosureTextNamesTheRiskAndTheSafeAlternative() {
        XCTAssertTrue(RedactionDisclosure.body.contains("unredacted"))
        XCTAssertTrue(RedactionDisclosure.body.contains("Create Share-Safe Copy"))
    }

    func testShareSafeCopyIsAFlatPNGWithNoPackage() throws {
        let controller = makeController()
        controller.perform { $0.add(.pixelate(RedactionElement(rect: CGRect(x: 0, y: 0, width: 40, height: 30)))) }
        let url = scratch.appendingPathComponent("Untitled share-safe.png")
        try ExportService.writeShareSafeCopy(controller, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(ProjectPackage.pngPixelSize(data)?.width, 40)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        XCTAssertFalse(isDir.boolValue, "a plain file, not a package")
    }
}
