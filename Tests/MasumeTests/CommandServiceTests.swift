import XCTest
import CoreGraphics
import AnnotationModel
@testable import Masume

/// The command service through its JSON surface: every command, every
/// error code, attribution, batch atomicity, and the crop that carries no
/// annotations.
@MainActor
final class CommandServiceTests: XCTestCase {

    private var scratch: URL!
    private var controller: CanvasController!
    private var service: CommandService!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("masume-cmd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        CommandService.cropDirectory = scratch.appendingPathComponent("crops")
        controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore(),
                                      recoveryStore: RecoveryStore(directory: scratch.appendingPathComponent("r")))
        // 1200 × 800: a 12 × 8 grid of 100 px cells.
        let ctx = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        controller.loadImage(ctx.makeImage()!)
        service = CommandService(controller: controller)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Numbered stamps

    func testNumberedStampsCountUpAndTakeAnOrdinal() {
        let first = result(run("create_element", params: ["type": "stamp", "kind": "number", "at": "B2"]))
        XCTAssertEqual((first["element"] as? [String: Any])?["label"] as? String, "1")
        let second = result(run("create_element", params: ["type": "stamp", "kind": "letter", "at": "C2"]))
        XCTAssertEqual((second["element"] as? [String: Any])?["label"] as? String, "A", "letters count on their own")
        let third = result(run("create_element", params: ["type": "stamp", "kind": "number", "at": "D2", "ordinal": 7]))
        let thirdElement = third["element"] as? [String: Any]
        XCTAssertEqual(thirdElement?["label"] as? String, "7")
        XCTAssertEqual(thirdElement?["ordinal"] as? Int, 7)
        let fourth = result(run("create_element", params: ["type": "stamp", "kind": "number", "at": "E2"]))
        XCTAssertEqual((fourth["element"] as? [String: Any])?["label"] as? String, "8", "one past the highest")
        let id = thirdElement?["id"] as? String ?? ""
        let updated = result(run("update_element", params: ["id": id, "kind": "letter", "ordinal": 28]))
        XCTAssertEqual((updated["element"] as? [String: Any])?["label"] as? String, "AB")
        XCTAssertEqual(errorCode(run("update_element", params: ["id": id, "ordinal": 0])), "invalid_argument")
        XCTAssertEqual(errorCode(run("create_element", params: ["type": "stamp", "kind": "number", "at": "F2", "ordinal": 1000])),
                       "invalid_argument")
        let plain = result(run("create_element", params: ["type": "stamp", "kind": "heart", "at": "G2"]))
        XCTAssertNil((plain["element"] as? [String: Any])?["label"], "glyph stamps report no label")
    }

    func testEmojiStampsTakeAndReportTheirCharacter() {
        let plain = result(run("create_element", params: ["type": "stamp", "kind": "emoji", "at": "B2"]))
        XCTAssertEqual((plain["element"] as? [String: Any])?["emoji"] as? String, StampElement.defaultEmoji)
        let fire = result(run("create_element", params: ["type": "stamp", "kind": "emoji", "at": "C2", "emoji": "\u{1F525}"]))
        let element = fire["element"] as? [String: Any]
        XCTAssertEqual(element?["emoji"] as? String, "\u{1F525}")
        XCTAssertEqual(element?["label"] as? String, "\u{1F525}")
        XCTAssertNil(element?["ordinal"], "an emoji stamp has no count")
        let id = element?["id"] as? String ?? ""
        let updated = result(run("update_element", params: ["id": id, "emoji": "\u{1F1EF}\u{1F1F5}"]))
        XCTAssertEqual((updated["element"] as? [String: Any])?["emoji"] as? String, "\u{1F1EF}\u{1F1F5}", "a flag is one character")
        XCTAssertEqual(errorCode(run("update_element", params: ["id": id, "emoji": "ab"])), "invalid_argument")
        XCTAssertEqual(errorCode(run("update_element", params: ["id": id, "emoji": ""])), "invalid_argument")
    }

    // MARK: Zones

    func testTheZoneIsReportedResolvedAndUsableAsAnAddress() {
        XCTAssertNil(result(run("get_active_document", mutation: false))["zone"] as? [String: Any])
        controller.zone = Zone(rect: CGRect(x: 150, y: 250, width: 300, height: 100), shape: .ellipse)
        let zone = result(run("get_active_document", mutation: false))["zone"] as? [String: Any]
        XCTAssertEqual(zone?["shape"] as? String, "ellipse")
        XCTAssertEqual(zone?["range"] as? String, "B3:E4", "the grid range covering it")
        XCTAssertEqual((zone?["rect"] as? [String: Any])?["width"] as? Double, 300)
        let resolved = result(run("resolve_grid", params: ["address": "zone"], mutation: false))
        XCTAssertEqual((resolved["center"] as? [String: Any])?["x"] as? Double, 300)
        XCTAssertEqual(resolved["address"] as? String, "zone")
        let box = result(run("create_element", params: ["type": "rectangle", "over": "zone"]))
        let boxRect = (box["element"] as? [String: Any])?["rect"] as? [String: Any]
        XCTAssertEqual(boxRect?["x"] as? Double, 150, "a box over the zone")
        XCTAssertEqual(boxRect?["width"] as? Double, 300)
        let stamp = result(run("create_element", params: ["type": "stamp", "at": "ZONE"]))
        XCTAssertEqual(((stamp["element"] as? [String: Any])?["center"] as? [String: Any])?["y"] as? Double, 300)
        let crop = result(run("set_crop", params: ["crop": "zone"]))
        XCTAssertEqual((crop["crop"] as? [String: Any])?["height"] as? Double, 100)
        controller.zone = nil
        XCTAssertEqual(errorCode(run("resolve_grid", params: ["address": "zone"], mutation: false)), "not_found")
        XCTAssertEqual(errorCode(run("create_element", params: ["type": "rectangle", "over": "zone"])), "invalid_address")
    }

    func testAnAgentCanMarkAZoneOutWithoutTouchingTheRevision() {
        let before = revision
        let byRange = result(run("set_zone", params: ["zone": "C3:D4", "shape": "ellipse"], mutation: false))
        XCTAssertEqual(controller.zone, Zone(rect: CGRect(x: 200, y: 200, width: 200, height: 200), shape: .ellipse))
        XCTAssertEqual((byRange["zone"] as? [String: Any])?["range"] as? String, "C3:D4")
        result(run("set_zone", params: ["zone": ["x": 10, "y": 20, "width": 30, "height": 40]], mutation: false))
        XCTAssertEqual(controller.zone?.rect, CGRect(x: 10, y: 20, width: 30, height: 40))
        XCTAssertEqual(controller.zone?.shape, .ellipse, "the shape carries over when not given")
        XCTAssertEqual(revision, before, "no revision, no history")
        XCTAssertEqual(errorCode(run("set_zone", params: ["zone": ["x": 0, "y": 0, "width": 2, "height": 2]], mutation: false)), "invalid_argument")
        XCTAssertEqual(errorCode(run("set_zone", params: ["zone": "A1", "shape": "star"], mutation: false)), "invalid_argument")
        result(run("set_zone", params: ["zone": NSNull()], mutation: false))
        XCTAssertNil(controller.zone)
    }

    // MARK: Helpers

    private var docID: String { controller.project!.id.uuidString }
    private var revision: Int { controller.project!.revision }

    /// Runs a command and returns the envelope as a dictionary.
    @discardableResult
    private func run(_ command: String, params: [String: Any] = [:], mutation: Bool = true,
                     documentId: String? = nil, expectedRevision: Int? = nil,
                     actor: String = "nova", reason: String? = nil) -> [String: Any] {
        var request: [String: Any] = ["command": command, "params": params, "actorId": actor, "actorName": "Nova"]
        if mutation || documentId != nil { request["documentId"] = documentId ?? docID }
        if mutation || expectedRevision != nil { request["expectedRevision"] = expectedRevision ?? revision }
        if let reason { request["reason"] = reason }
        return envelope(service.execute(json: encode(request)))
    }

    private func encode(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func envelope(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func result(_ envelope: [String: Any]) -> [String: Any] {
        XCTAssertEqual(envelope["ok"] as? Bool, true, "\(envelope)")
        return envelope["result"] as? [String: Any] ?? [:]
    }

    private func errorCode(_ envelope: [String: Any]) -> String? {
        XCTAssertEqual(envelope["ok"] as? Bool, false, "\(envelope)")
        return (envelope["error"] as? [String: Any])?["code"] as? String
    }

    private func point(_ any: Any?) -> CGPoint? {
        guard let o = any as? [String: Any], let x = o["x"] as? Double, let y = o["y"] as? Double else { return nil }
        return CGPoint(x: x, y: y)
    }

    // MARK: Reads

    func testActiveDocumentSummary() {
        let r = result(run("get_active_document", mutation: false))
        XCTAssertEqual(r["id"] as? String, docID)
        XCTAssertEqual(r["revision"] as? Int, 0)
        XCTAssertEqual(r["name"] as? String, "Untitled")
        XCTAssertEqual((r["canvas"] as? [String: Any])?["width"] as? Double, 1200)
        XCTAssertEqual((r["grid"] as? [String: Any])?["columns"] as? Int, 12)
        XCTAssertEqual((r["grid"] as? [String: Any])?["rows"] as? Int, 8)
        XCTAssertEqual(r["dirty"] as? Bool, true)
        XCTAssertEqual(r["containsOriginalImage"] as? Bool, true)
        XCTAssertTrue(r["projectPath"] is NSNull)
    }

    func testResolveGridReturnsRectCenterCornersAndNormalized() {
        let r = result(run("resolve_grid", params: ["address": "d5:f7"], mutation: false))
        XCTAssertEqual(r["address"] as? String, "D5:F7")
        XCTAssertEqual((r["rect"] as? [String: Any])?["x"] as? Double, 300)
        XCTAssertEqual((r["rect"] as? [String: Any])?["width"] as? Double, 300)
        XCTAssertEqual(point(r["center"]), CGPoint(x: 450, y: 550))
        XCTAssertEqual((r["corners"] as? [Any])?.count, 4)
        XCTAssertEqual((r["normalized"] as? [String: Any])?["x"] as? Double, 0.25)
    }

    func testBadAddressesAreInvalidAddressNeverClamped() {
        XCTAssertEqual(errorCode(run("resolve_grid", params: ["address": "M1"], mutation: false)), "invalid_address")
        XCTAssertEqual(errorCode(run("resolve_grid", params: ["address": "F7:D5"], mutation: false)), "invalid_address")
        XCTAssertEqual(errorCode(run("resolve_grid", params: ["address": "hello"], mutation: false)), "invalid_address")
        XCTAssertEqual(errorCode(run("create_element", params: ["type": "arrow", "from": "B3", "to": "Z9"])),
                       "invalid_address")
    }

    // MARK: Conflicts

    func testWrongDocumentOrStaleRevisionChangesNothing() {
        XCTAssertEqual(errorCode(run("create_element", params: ["type": "arrow", "from": "B3", "to": "D6"],
                                     documentId: UUID().uuidString)), "conflict")
        XCTAssertEqual(errorCode(run("create_element", params: ["type": "arrow", "from": "B3", "to": "D6"],
                                     expectedRevision: 7)), "conflict")
        XCTAssertEqual(controller.document?.elements.count, 0)
        XCTAssertEqual(revision, 0)
        // Mutations must name both.
        let out = envelope(service.execute(json: encode(["command": "delete_elements", "params": ["ids": ["x"]]])))
        XCTAssertEqual(errorCode(out), "invalid_argument")
    }

    func testMalformedJSONAndUnknownCommand() {
        XCTAssertEqual(errorCode(envelope(service.execute(json: Data("{nope".utf8)))), "invalid_argument")
        XCTAssertEqual(errorCode(run("frobnicate", mutation: false)), "unsupported")
        XCTAssertEqual(errorCode(run("create_element", params: ["type": "hologram", "over": "A1"])), "unsupported")
    }

    // MARK: Create, read back, update, delete

    func testCreateArrowFromCellsAttributedWithReason() throws {
        let r = result(run("create_element", params: ["type": "arrow", "from": "B3", "to": "D6", "color": "blue"],
                           reason: "point at the Save button"))
        XCTAssertEqual(r["revision"] as? Int, 1)
        let element = try XCTUnwrap(r["element"] as? [String: Any])
        XCTAssertEqual(element["type"] as? String, "arrow")
        XCTAssertEqual(point(element["start"]), CGPoint(x: 150, y: 250), "center of B3")
        XCTAssertEqual(point(element["end"]), CGPoint(x: 350, y: 550), "center of D6")
        XCTAssertEqual(element["color"] as? String, "#007AFF")
        let id = try XCTUnwrap(element["id"] as? String)

        let project = try XCTUnwrap(controller.project)
        XCTAssertEqual(project.history.last?.actor, HistoryActor(id: "nova", name: "Nova"))
        XCTAssertEqual(project.history.last?.reason, "point at the Save button")
        XCTAssertEqual(project.history.last?.summary, "Nova added arrow \(id.prefix(4))")
        XCTAssertTrue(controller.canUndo, "the human can undo the agent's edit")
        XCTAssertNil(controller.commitAttribution, "attribution is cleared after the call")

        let got = result(run("get_element", params: ["id": id.lowercased()], mutation: false))
        XCTAssertEqual((got["element"] as? [String: Any])?["id"] as? String, id)
        let listed = result(run("list_elements", mutation: false))
        XCTAssertEqual((listed["elements"] as? [Any])?.count, 1)
    }

    func testUpdateChangesOnlyTheGivenKeysAndZOrder() throws {
        let first = result(run("create_element", params: ["type": "rectangle", "over": "A1:B2"]))
        let second = result(run("create_element", params: ["type": "ellipse", "over": "C3"]))
        let firstID = try XCTUnwrap((first["element"] as? [String: Any])?["id"] as? String)
        let secondID = try XCTUnwrap((second["element"] as? [String: Any])?["id"] as? String)

        let r = result(run("update_element", params: ["id": firstID, "color": "#00FF00", "fill": "yellow", "zOrder": "front"]))
        let element = try XCTUnwrap(r["element"] as? [String: Any])
        XCTAssertEqual(element["color"] as? String, "#00FF00")
        XCTAssertEqual(element["fill"] as? String, "#FFCC00")
        XCTAssertEqual((element["rect"] as? [String: Any])?["width"] as? Double, 200, "geometry untouched")
        XCTAssertEqual(controller.document?.elements.last?.id.uuidString, firstID, "moved to front")
        XCTAssertEqual(controller.document?.elements.first?.id.uuidString, secondID)
        let line = result(run("create_element", params: ["type": "line", "from": "A1", "to": "B1"]))
        let lineID = try XCTUnwrap((line["element"] as? [String: Any])?["id"] as? String)
        let moved = result(run("update_element", params: ["id": lineID, "end": ["x": 9, "y": 9]]))
        XCTAssertEqual(point((moved["element"] as? [String: Any])?["end"]), CGPoint(x: 9, y: 9), "one end alone moves")
        XCTAssertEqual(point((moved["element"] as? [String: Any])?["start"]), CGPoint(x: 50, y: 50), "the other stays")
        XCTAssertEqual(errorCode(run("update_element", params: ["id": UUID().uuidString, "color": "red"])), "not_found")
        XCTAssertEqual(errorCode(run("update_element", params: ["id": firstID, "color": "mauve"])), "invalid_argument")
    }

    func testDeleteRefusesUnknownIDsWithoutDeletingAnything() throws {
        let created = result(run("create_element", params: ["type": "line", "from": "A1", "to": "B1"]))
        let a = try XCTUnwrap((created["element"] as? [String: Any])?["id"] as? String)
        XCTAssertEqual(errorCode(run("delete_elements", params: ["ids": [a, UUID().uuidString]])), "not_found")
        XCTAssertEqual(controller.document?.elements.count, 1)
        let r = result(run("delete_elements", params: ["ids": [a]]))
        XCTAssertEqual((r["deleted"] as? [String])?.first, a)
        XCTAssertEqual(controller.document?.elements.count, 0)
    }

    func testEveryTypeCanBeCreated() {
        let inputs: [[String: Any]] = [
            ["type": "line", "start": ["x": 1, "y": 1], "end": ["x": 5, "y": 5]],
            ["type": "pen", "points": [["x": 1, "y": 1], ["x": 5, "y": 5]], "opacity": 0.4],
            ["type": "text", "at": "C3", "text": "hello", "alignment": "center"],
            ["type": "callout", "over": "E2:G3", "tail": "F6", "text": "look here", "shape": "thought"],
            ["type": "stamp", "at": "H4", "kind": "heart"],
            ["type": "pixelate", "over": "A8:B8", "amount": 20],
            ["type": "magnifier", "over": "J2:K3", "zoom": 3, "shape": "square"],
        ]
        for input in inputs {
            let r = result(run("create_element", params: input))
            XCTAssertEqual((r["element"] as? [String: Any])?["type"] as? String, input["type"] as? String)
        }
        XCTAssertEqual(controller.document?.elements.count, inputs.count)
        let callout = controller.document?.elements.compactMap { element -> TextElement? in
            if case .text(let t) = element, t.isCallout { return t }
            return nil
        }.first
        XCTAssertEqual(callout?.container?.shape, .thought)
        XCTAssertEqual(callout?.container?.tailTip, CGPoint(x: 550, y: 550), "center of F6")
    }

    // MARK: Crop, density, undo, redo

    func testSetCropByRangeAndClear() {
        let r = result(run("set_crop", params: ["crop": "B2:E5"]))
        XCTAssertEqual((r["crop"] as? [String: Any])?["x"] as? Double, 100)
        XCTAssertEqual(controller.document?.crop, CGRect(x: 100, y: 100, width: 400, height: 400))
        XCTAssertEqual(errorCode(run("set_crop", params: ["crop": ["x": 5000, "y": 5000, "width": 10, "height": 10]])),
                       "invalid_argument")
        result(run("set_crop", params: ["crop": NSNull()]))
        XCTAssertNil(controller.document?.crop)
    }

    func testDensityAndUndoRedoAreAgentCommits() throws {
        result(run("set_grid_density", params: ["cellsAcrossLongSide": 24]))
        XCTAssertEqual(controller.document?.grid.columns, 24)
        XCTAssertEqual(errorCode(run("set_grid_density", params: ["cellsAcrossLongSide": 13])), "invalid_argument")
        let undone = result(run("undo", reason: "too fine"))
        XCTAssertEqual(controller.document?.grid.columns, 12)
        XCTAssertEqual(undone["revision"] as? Int, 2)
        XCTAssertEqual(controller.project?.history.last?.actor.id, "nova")
        XCTAssertEqual(controller.project?.history.last?.reason, "too fine")
        result(run("redo"))
        XCTAssertEqual(controller.document?.grid.columns, 24)
        XCTAssertEqual(errorCode(run("redo")), "invalid_argument")
    }

    // MARK: Batch

    func testBatchIsAtomic() {
        let failing = run("batch", params: ["commands": [
            ["command": "create_element", "params": ["type": "arrow", "from": "A1", "to": "B2"]],
            ["command": "create_element", "params": ["type": "arrow", "from": "A1", "to": "Q9"]],
        ]])
        XCTAssertEqual(errorCode(failing), "invalid_address")
        XCTAssertTrue(((failing["error"] as? [String: Any])?["message"] as? String ?? "").hasPrefix("commands[1]"))
        XCTAssertEqual(controller.document?.elements.count, 0)
        XCTAssertEqual(revision, 0)

        let ok = result(run("batch", params: ["commands": [
            ["command": "create_element", "params": ["type": "arrow", "from": "A1", "to": "B2"]],
            ["command": "create_element", "params": ["type": "text", "at": "C3", "text": "two"]],
            ["command": "set_crop", "params": ["crop": "A1:F8"]],
        ]], reason: "annotate the header"))
        XCTAssertEqual((ok["results"] as? [Any])?.count, 3)
        XCTAssertEqual(controller.document?.elements.count, 2)
        XCTAssertEqual(revision, 1, "one commit for the whole batch")
        XCTAssertEqual(controller.project?.history.count, 1)
        controller.undo()
        XCTAssertEqual(controller.document?.elements.count, 0, "and one undo step")
    }

    // MARK: Base image, history, files

    func testViewBaseImageCropsTheUntouchedImage() throws {
        // A big blue arrow across the region; the crop must not show it.
        result(run("create_element", params: ["type": "arrow", "from": "A1", "to": "L8", "color": "blue", "width": 60]))
        let r = result(run("view_base_image", params: ["range": "D5:F7", "margin": 10], mutation: false))
        XCTAssertEqual(r["width"] as? Int, 320)
        XCTAssertEqual(r["height"] as? Int, 320)
        XCTAssertEqual(r["marginAdded"] as? Bool, true)
        XCTAssertEqual((r["bounds"] as? [String: Any])?["x"] as? Double, 290)
        XCTAssertEqual(r["revision"] as? Int, 1)
        let path = try XCTUnwrap(r["path"] as? String)
        XCTAssertTrue(path.hasPrefix(scratch.path))
        let image = try XCTUnwrap(ImageLoader.cgImage(from: Data(contentsOf: URL(fileURLWithPath: path))))
        var buf = [UInt8](repeating: 0, count: 320 * 320 * 4)
        let ctx = CGContext(data: &buf, width: 320, height: 320, bitsPerComponent: 8, bytesPerRow: 1280,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 320, height: 320))
        XCTAssertTrue(buf.allSatisfy { $0 == 255 }, "pure white: no annotation leaked into the crop")
        XCTAssertEqual(controller.project?.history.count, 1, "looking leaves no trace")
    }

    func testHistoryListsAgentAndHumanCommits() {
        result(run("create_element", params: ["type": "stamp", "at": "A1"], reason: "mark it"))
        controller.perform { $0.add(.line(SegmentElement(start: .zero, end: CGPoint(x: 5, y: 5)))) }
        let r = result(run("get_history", mutation: false))
        let entries = r["entries"] as? [[String: Any]] ?? []
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual((entries[0]["actor"] as? [String: Any])?["id"] as? String, "nova")
        XCTAssertEqual(entries[0]["reason"] as? String, "mark it")
        XCTAssertEqual((entries[1]["actor"] as? [String: Any])?["id"] as? String, "human")
        XCTAssertEqual(entries[1]["revisionAfter"] as? Int, 2)
        XCTAssertEqual(((result(run("get_history", params: ["limit": 1], mutation: false))["entries"]) as? [Any])?.count, 1)
    }

    func testSaveAndExportWriteFiles() throws {
        result(run("create_element", params: ["type": "rectangle", "over": "B2:C3", "fill": "red"]))
        XCTAssertEqual(errorCode(run("save_project", mutation: false)), "invalid_argument", "never saved: path required")
        let project = scratch.appendingPathComponent("Agent.masume").path
        let saved = result(run("save_project", params: ["path": project], mutation: false))
        XCTAssertEqual(saved["path"] as? String, project)
        XCTAssertEqual(try ProjectPackage.read(at: URL(fileURLWithPath: project)).manifest.elements.count, 1)
        XCTAssertFalse(controller.isDirty)

        let out = scratch.appendingPathComponent("flat.png").path
        let exported = result(run("export", params: ["path": out, "bounds": "clipToImage"], mutation: false))
        XCTAssertEqual(exported["width"] as? Int, 1200)
        XCTAssertEqual(exported["format"] as? String, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out))
        XCTAssertEqual(errorCode(run("export", params: ["path": "relative.png"], mutation: false)), "invalid_argument")
        XCTAssertEqual(errorCode(run("export", params: ["path": out, "format": "gif"], mutation: false)), "invalid_argument")
    }

    func testNoDocumentIsNotFound() {
        let empty = CommandService(controller: CanvasController(preferencesStore: InMemoryToolPreferencesStore()))
        let out = envelope(empty.execute(json: Data(#"{"command":"get_active_document"}"#.utf8)))
        XCTAssertEqual(errorCode(out), "not_found")
    }
}
