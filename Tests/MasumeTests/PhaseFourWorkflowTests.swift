import XCTest
import AnnotationModel
import MasumeCommands
@testable import Masume

@MainActor
final class PhaseFourWorkflowTests: XCTestCase {
    private var scratch: URL!
    private var controller: CanvasController!

    @MainActor override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore(), recoveryStore: RecoveryStore(directory: scratch))
        let context = CGContext(data: nil, width: 200, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        controller.loadImage(context.makeImage()!)
    }

    @MainActor override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func run(_ name: String, _ params: [String: JSONValue], revision: Int? = nil) -> CommandResponse {
        CommandService(controller: controller).execute(CommandRequest(command: name, documentId: controller.project!.id.uuidString,
            expectedRevision: revision ?? controller.project!.revision, actorId: "test", params: .object(params)))
    }

    func testAgentCreatesStylesAndInvalidUpdateIsAtomic() throws {
        let box: JSONValue = .object(["x": .number(20), "y": .number(20), "width": .number(100), "height": .number(60)])
        guard case .success = run("create_element", ["type": .string("rounded_rectangle"), "rect": box,
                                                    "cornerRadius": .number(24), "shadow": .bool(false)]) else {
            return XCTFail("create failed")
        }
        let element = try XCTUnwrap(controller.document?.elements.first)
        XCTAssertEqual(element.rectangleCornerRadius, 24)
        XCTAssertEqual(element.shadowEnabled, false)
        let before = controller.document
        guard case .failure = run("update_element", ["id": .string(element.id.uuidString), "cornerRadius": .number(-2),
                                                    "color": .string("blue")]) else { return XCTFail("negative radius accepted") }
        XCTAssertEqual(controller.document, before)
        guard case .success = run("create_element", ["type": .string("highlight"), "rect": box, "opacity": .number(0.4)]) else {
            return XCTFail("highlight create failed")
        }
        XCTAssertEqual(controller.document?.elements.last?.opacity, 0.4)
        XCTAssertEqual(controller.document?.elements.last?.shadowEnabled, false)
        controller.undo()
        XCTAssertEqual(controller.document, before)
        controller.redo()
        XCTAssertEqual(controller.document?.elements.count, 2)
    }

    func testHumanStyleChangesAreUndoableAndDefaultsPersist() throws {
        controller.perform { $0.add(.rectangle(ShapeElement(rect: CGRect(x: 10, y: 10, width: 100, height: 50)))) }
        controller.selection = controller.document?.elements.first?.id
        controller.setRectangleTreatment(.rounded)
        controller.setRectangleRadius(22)
        controller.setShadow(false)
        XCTAssertEqual(controller.document?.elements.first?.shadowEnabled, false)
        controller.undo()
        XCTAssertEqual(controller.document?.elements.first?.shadowEnabled, true)
        controller.undo()
        XCTAssertEqual(controller.document?.elements.first?.rectangleCornerRadius, 16)
        let preferences = controller.toolPreferences
        let restored = CanvasController(preferencesStore: InMemoryToolPreferencesStore(preferences), recoveryStore: RecoveryStore(directory: scratch))
        XCTAssertEqual(restored.cornerRadius, 22)
        XCTAssertFalse(restored.shadowEnabled)
        XCTAssertEqual(restored.rectangleTreatment, .rounded)
    }
}
