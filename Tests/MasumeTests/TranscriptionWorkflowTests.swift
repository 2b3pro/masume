import XCTest
import AnnotationModel
import MasumeCommands
@testable import Masume

private struct TranscriptionRecognizer: TextRecognizing {
    let expected: TextPreferences
    func recognize(in image: CGImage, languages: [String], customWords: [String]) throws -> [TextRecognitionLine] {
        guard languages == expected.languages, customWords == expected.customWords else {
            throw CommandError.invalidArgument("preferences were not forwarded")
        }
        return [TextRecognitionLine(text: "Shen", confidence: 0.98, bounds: CGRect(x: 5, y: 5, width: 30, height: 10)),
                TextRecognitionLine(text: "Columbla", confidence: 0.4, bounds: CGRect(x: 5, y: 20, width: 50, height: 10))]
    }
}

private final class GatedTextRecognizer: TextRecognizing, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    func waitForStart() -> Bool { started.wait(timeout: .now() + 5) == .success }
    func recognize(in image: CGImage, languages: [String], customWords: [String]) throws -> [TextRecognitionLine] {
        started.signal()
        guard resume.wait(timeout: .now() + 5) == .success else { throw TextRecognitionError.timedOut }
        return [TextRecognitionLine(text: "Old text", confidence: 1, bounds: CGRect(x: 5, y: 5, width: 10, height: 10))]
    }
}

@MainActor
final class TranscriptionWorkflowTests: XCTestCase {
    private var scratch: URL!
    private var controller: CanvasController!
    private let preferences = TextPreferences(languages: ["en-US"], customWords: ["Shen"])

    @MainActor override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        controller = makeController()
        let context = CGContext(data: nil, width: 200, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        controller.loadImage(context.makeImage()!)
    }

    @MainActor override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeController() -> CanvasController {
        CanvasController(preferencesStore: InMemoryToolPreferencesStore(),
                         recoveryStore: RecoveryStore(directory: scratch.appendingPathComponent("recovery")))
    }

    func testPreferencesSaveRecoverUndoAndLegacyDecode() throws {
        try controller.saveTextPreferences(languages: preferences.languages, customWords: preferences.customWords)
        XCTAssertEqual(controller.document?.textPreferences, preferences)
        XCTAssertTrue(controller.project?.history.last?.summary.contains("transcription preferences") == true)
        XCTAssertEqual(controller.project?.history.last?.textPreferencesAfter, preferences)
        let recovery = try ProjectPackage.read(at: XCTUnwrap(controller.project?.recoveryURL))
        XCTAssertEqual(recovery.manifest.textPreferences, preferences)
        let url = scratch.appendingPathComponent("Archive.masume")
        try controller.saveProject(to: url, newIdentity: false)
        let reopened = makeController()
        try reopened.openProject(at: url)
        XCTAssertEqual(reopened.document?.textPreferences, preferences)
        controller.undo()
        XCTAssertEqual(controller.document?.textPreferences, TextPreferences())
        controller.redo()
        XCTAssertEqual(controller.document?.textPreferences, preferences)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: ProjectPackage.encodeManifest(recovery.manifest)) as? [String: Any])
        legacy.removeValue(forKey: "textPreferences")
        let decoded = try ProjectPackage.decodeManifest(JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.textPreferences, TextPreferences())
    }

    func testUIRecognitionUsesSavedPreferencesFindAndConfidenceOutputWithoutMutation() async throws {
        try controller.saveTextPreferences(languages: preferences.languages, customWords: preferences.customWords)
        let before = controller.document
        let revision = controller.project?.revision
        await controller.readTranscription(range: nil, recognizer: TranscriptionRecognizer(expected: preferences))
        let map = try XCTUnwrap(controller.currentTextMap)
        XCTAssertEqual(map.matches("shen").map(\.text), ["Shen"])
        XCTAssertTrue(map.transcription.contains("[low confidence] Columbla"))
        XCTAssertFalse(map.transcription.contains("[low confidence] Shen"))
        XCTAssertEqual(map.text, "Shen\nColumbla")
        XCTAssertEqual(controller.document, before)
        XCTAssertEqual(controller.project?.revision, revision)
        XCTAssertFalse(controller.isRecognizingText)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(map.json), encoding: .utf8))
        XCTAssertFalse(encoded.contains("base64"))
        XCTAssertFalse(encoded.contains("imagePath"))
    }

    func testGridAndPreferencesInvalidateResultsButAnnotationsDoNot() async throws {
        await controller.readTranscription(range: nil, recognizer: TranscriptionRecognizer(expected: TextPreferences()))
        XCTAssertNotNil(controller.currentTextMap)
        controller.perform { $0.add(.text(TextElement(origin: .zero, string: "Annotation"))) }
        XCTAssertNotNil(controller.currentTextMap)
        controller.setGridPreset(16)
        XCTAssertNil(controller.currentTextMap)
        await controller.readTranscription(range: nil, recognizer: TranscriptionRecognizer(expected: TextPreferences()))
        XCTAssertNotNil(controller.currentTextMap)
        try controller.saveTextPreferences(languages: ["fr-FR"], customWords: [])
        XCTAssertNil(controller.currentTextMap)
    }

    func testTextExportWritesMarkersAndRefusesStaleResultsWithoutOverwritingFile() async throws {
        await controller.readTranscription(range: nil, recognizer: TranscriptionRecognizer(expected: TextPreferences()))
        let url = scratch.appendingPathComponent("transcription.txt")
        try controller.writeTranscription(to: url)
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, "Shen\n[low confidence] Columbla")
        controller.setGridPreset(16)
        XCTAssertThrowsError(try controller.writeTranscription(to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), written)
    }

    func testZoneBoundsTranslateAndMissingZoneErrors() async throws {
        controller.zone = Zone(rect: CGRect(x: 20, y: 30, width: 80, height: 80), shape: .rectangle)
        await controller.readTranscription(range: "zone", recognizer: TranscriptionRecognizer(expected: TextPreferences()))
        let map = try XCTUnwrap(controller.currentTextMap)
        XCTAssertEqual(map.lines.first?.bounds.origin, CGPoint(x: 25, y: 35))
        controller.zone = nil
        XCTAssertNil(controller.currentTextMap)
        await controller.readTranscription(range: "zone", recognizer: TranscriptionRecognizer(expected: TextPreferences()))
        XCTAssertNil(controller.currentTextMap)
        XCTAssertNotNil(controller.textRecognitionError)
    }

    func testAsyncResultIsDiscardedWhenPreferencesChangeDuringRecognition() async throws {
        let recognizer = GatedTextRecognizer()
        let task = Task { await controller.readTranscription(range: nil, recognizer: recognizer) }
        let started = await Task.detached { recognizer.waitForStart() }.value
        XCTAssertTrue(started)
        try controller.saveTextPreferences(languages: ["de-DE"], customWords: [])
        recognizer.resume.signal()
        await task.value
        XCTAssertNil(controller.currentTextMap)
        XCTAssertNotNil(controller.textRecognitionError)
        XCTAssertFalse(controller.isRecognizingText)
    }

    func testLiveReadOverrideDoesNotChangeStoredPreferencesAndStaleMutationFails() throws {
        try controller.saveTextPreferences(languages: preferences.languages, customWords: preferences.customWords)
        let service = CommandService(controller: controller, textRecognizer: TranscriptionRecognizer(expected: TextPreferences()))
        let read = service.execute(CommandRequest(command: "read_text", params: .object(["languages": .array([]), "customWords": .array([])])))
        guard case .success = read else { return XCTFail("explicit empty arrays must override saved preferences") }
        XCTAssertEqual(controller.document?.textPreferences, preferences)
        let write = service.execute(CommandRequest(command: "set_text_preferences", documentId: controller.project!.id.uuidString,
                                                   expectedRevision: 0, params: .object(["languages": .array([])])))
        guard case .failure(let error) = write else { return XCTFail("stale preference write accepted") }
        XCTAssertEqual(error.code, .conflict)
        XCTAssertEqual(controller.document?.textPreferences, preferences)
    }
}
