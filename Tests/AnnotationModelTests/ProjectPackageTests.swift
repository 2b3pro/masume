import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AnnotationModel

/// The `.masume` package codec: manifest round trip with unknown keys kept,
/// history diffs and their sentences, atomic create and update, and every
/// way `read` refuses a package it cannot trust.
final class ProjectPackageTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("masume-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Fixtures

    private func png(width: Int, height: Int) -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    private let actor = Actor(id: "human", name: "Ian")

    private func manifest(elements: [Annotation] = [], png: Data, width: Int = 40, height: Int = 30) -> ProjectManifest {
        ProjectManifest(id: UUID(), revision: 3, canvasSize: CGSize(width: width, height: height),
                        crop: CGRect(x: 1, y: 2, width: 10, height: 5), elements: elements,
                        createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 2_000),
                        baseImage: BaseImageInfo(fileName: ProjectPackage.baseImageName,
                                                 sha256: ProjectPackage.sha256Hex(png), width: width, height: height))
    }

    private var sampleElements: [Annotation] {
        [.arrow(SegmentElement(start: CGPoint(x: 1, y: 1), end: CGPoint(x: 9, y: 9))),
         .text(TextElement(origin: CGPoint(x: 3, y: 3), string: "hi", alignment: .center,
                           container: TextContainer(shape: .speech, tailTip: CGPoint(x: 0, y: 0))))]
    }

    // MARK: Manifest

    func testManifestRoundTripsAndKeepsUnknownKeys() throws {
        var m = manifest(elements: sampleElements, png: png(width: 40, height: 30))
        m.extra = ["grid": .object(["columns": .number(12), "rows": .number(9)]), "note": .string("keep me")]
        let data = try ProjectPackage.encodeManifest(m)
        let back = try ProjectPackage.decodeManifest(data)
        XCTAssertEqual(back, m)
        // The JSON is the agent-facing shape: readable sizes, not arrays.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["canvasSize"] as? [String: Any])?["width"] as? Double, 40)
        XCTAssertEqual((json["crop"] as? [String: Any])?["x"] as? Double, 1)
        XCTAssertEqual(json["formatVersion"] as? Int, ProjectManifest.currentFormatVersion)
        XCTAssertNotNil(json["grid"], "unknown keys are written back at the top level")
    }

    func testNewerFormatVersionIsRejectedBeforeAnythingElse() throws {
        let data = Data("""
        {"formatVersion": 99, "id": "not even a uuid"}
        """.utf8)
        XCTAssertThrowsError(try ProjectPackage.decodeManifest(data)) { error in
            XCTAssertEqual(error as? ProjectError, .unsupportedVersion(99))
        }
    }

    func testMalformedManifestIsCorrupt() {
        XCTAssertThrowsError(try ProjectPackage.decodeManifest(Data("{".utf8))) { error in
            guard case .corruptManifest? = error as? ProjectError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try ProjectPackage.decodeManifest(Data(#"{"formatVersion": 1}"#.utf8))) { error in
            guard case .corruptManifest? = error as? ProjectError else { return XCTFail("\(error)") }
        }
    }

    // MARK: History

    func testDiffRecordsAddedChangedAndDeletedWithBeforeAndAfter() {
        let arrow = SegmentElement(start: CGPoint(x: 1, y: 1), end: CGPoint(x: 9, y: 9))
        let text = TextElement(origin: .zero, string: "a")
        let stamp = StampElement(center: CGPoint(x: 5, y: 5))
        let old = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 40, height: 30),
                           elements: [.arrow(arrow), .text(text)])
        var movedArrow = arrow
        movedArrow.end = CGPoint(x: 20, y: 20)
        let new = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 40, height: 30),
                           elements: [.arrow(movedArrow), .stamp(stamp)])
        let entry = HistoryEntry.diff(from: old, to: new, actor: actor, revisionBefore: 4,
                                      timestamp: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(entry.revisionBefore, 4)
        XCTAssertEqual(entry.revisionAfter, 5)
        XCTAssertEqual(Set(entry.affected), [arrow.id, text.id, stamp.id])
        XCTAssertEqual(entry.before, [.arrow(arrow), .text(text)], "before holds the old objects, in old order")
        XCTAssertEqual(entry.after, [.arrow(movedArrow), .stamp(stamp)], "after holds the new objects, in new order")
        XCTAssertNil(entry.cropBefore)
        XCTAssertNil(entry.cropAfter)
        let short = { (id: UUID) in id.uuidString.prefix(4) }
        XCTAssertEqual(entry.summary,
                       "Ian changed arrow \(short(arrow.id)), added stamp \(short(stamp.id)), and deleted text \(short(text.id))")
    }

    func testSummarySentences() {
        let base = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 40, height: 30))
        let arrow = Annotation.arrow(SegmentElement(start: .zero, end: CGPoint(x: 1, y: 1)))
        var added = base
        added.add(arrow)
        XCTAssertEqual(HistoryEntry.diff(from: base, to: added, actor: actor, revisionBefore: 0).summary,
                       "Ian added arrow \(arrow.id.uuidString.prefix(4))")
        XCTAssertEqual(HistoryEntry.diff(from: added, to: base, actor: actor, revisionBefore: 1).summary,
                       "Ian deleted arrow \(arrow.id.uuidString.prefix(4))")

        var cropped = base
        cropped.crop = CGRect(x: 0, y: 0, width: 5, height: 5)
        let cropEntry = HistoryEntry.diff(from: base, to: cropped, actor: actor, revisionBefore: 1)
        XCTAssertEqual(cropEntry.summary, "Ian changed the crop")
        XCTAssertEqual(cropEntry.cropAfter, cropped.crop)
        XCTAssertEqual(HistoryEntry.diff(from: cropped, to: base, actor: actor, revisionBefore: 2).summary,
                       "Ian cleared the crop")

        var many = base
        for _ in 0..<3 { many.add(.line(SegmentElement(start: .zero, end: CGPoint(x: 1, y: 1)))) }
        XCTAssertEqual(HistoryEntry.diff(from: base, to: many, actor: actor, revisionBefore: 0).summary,
                       "Ian added 3 elements")
        XCTAssertEqual(HistoryEntry.diff(from: base, to: base, actor: actor, revisionBefore: 0).summary,
                       "Ian made no change")

        var callout = base
        callout.add(.text(TextElement(origin: .zero, container: TextContainer(shape: .thought, tailTip: .zero))))
        XCTAssertTrue(HistoryEntry.diff(from: base, to: callout, actor: actor, revisionBefore: 0).summary.contains("added callout "))
    }

    func testReorderCountsAsAChange() {
        let a = Annotation.arrow(SegmentElement(start: .zero, end: CGPoint(x: 1, y: 1)))
        let b = Annotation.line(SegmentElement(start: .zero, end: CGPoint(x: 2, y: 2)))
        let old = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 40, height: 30), elements: [a, b])
        let new = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 40, height: 30), elements: [b, a])
        let entry = HistoryEntry.diff(from: old, to: new, actor: actor, revisionBefore: 0)
        XCTAssertEqual(Set(entry.affected), [a.id, b.id])
        XCTAssertEqual(entry.summary, "Ian changed 2 elements")
    }

    // MARK: Package create / read

    func testCreateThenReadRoundTrips() throws {
        let image = png(width: 40, height: 30)
        let m = manifest(elements: sampleElements, png: image)
        let entry = HistoryEntry.diff(from: Document(baseImage: .pngData(Data()), canvasSize: m.canvasSize),
                                      to: Document(baseImage: .pngData(Data()), canvasSize: m.canvasSize, elements: sampleElements),
                                      actor: actor, revisionBefore: 2)
        let url = scratch.appendingPathComponent("Doc.masume")
        try ProjectPackage.create(at: url, manifest: m, baseImagePNG: image, preview: png(width: 4, height: 3), history: [entry])

        let contents = try ProjectPackage.read(at: url)
        XCTAssertEqual(contents.manifest, m)
        XCTAssertEqual(contents.baseImagePNG, image)
        XCTAssertEqual(contents.history, [entry])
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        XCTAssertEqual(names, ["base-image.png", "history.jsonl", "manifest.json", "preview.png"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent(".Doc.masume.tmp").path))
    }

    func testCreateReplacesAnExistingPackageAtomically() throws {
        let image = png(width: 40, height: 30)
        let url = scratch.appendingPathComponent("Doc.masume")
        try ProjectPackage.create(at: url, manifest: manifest(png: image), baseImagePNG: image, preview: nil, history: [])
        var second = manifest(elements: sampleElements, png: image)
        second.revision = 9
        try ProjectPackage.create(at: url, manifest: second, baseImagePNG: image, preview: nil, history: [])
        XCTAssertEqual(try ProjectPackage.read(at: url).manifest.revision, 9)
        // No leftovers from either write.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        XCTAssertEqual(siblings, ["Doc.masume"])
    }

    func testCreateIntoAMissingParentLeavesNothingBehind() throws {
        let image = png(width: 40, height: 30)
        let url = scratch.appendingPathComponent("nope/Doc.masume")
        XCTAssertThrowsError(try ProjectPackage.create(at: url, manifest: manifest(png: image),
                                                       baseImagePNG: image, preview: nil, history: []))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
    }

    func testUpdateRewritesManifestAndAppendsHistoryButNotTheImage() throws {
        let image = png(width: 40, height: 30)
        let url = scratch.appendingPathComponent("Doc.masume")
        var m = manifest(png: image)
        let doc0 = Document(baseImage: .pngData(Data()), canvasSize: m.canvasSize)
        var doc1 = doc0
        doc1.add(sampleElements[0])
        let e1 = HistoryEntry.diff(from: doc0, to: doc1, actor: actor, revisionBefore: 3)
        try ProjectPackage.create(at: url, manifest: m, baseImagePNG: image, preview: nil, history: [e1])
        let imagePath = url.appendingPathComponent("base-image.png").path
        let imageStamp = try FileManager.default.attributesOfItem(atPath: imagePath)[.modificationDate] as? Date
        let firstLine = try String(contentsOf: url.appendingPathComponent("history.jsonl"), encoding: .utf8)

        var doc2 = doc1
        doc2.add(sampleElements[1])
        let e2 = HistoryEntry.diff(from: doc1, to: doc2, actor: actor, revisionBefore: 4)
        m.revision = 5
        m.elements = doc2.elements
        try ProjectPackage.update(at: url, manifest: m, preview: png(width: 4, height: 3), appending: [e2])

        let contents = try ProjectPackage.read(at: url)
        XCTAssertEqual(contents.manifest.revision, 5)
        XCTAssertEqual(contents.history, [e1, e2])
        let all = try String(contentsOf: url.appendingPathComponent("history.jsonl"), encoding: .utf8)
        XCTAssertTrue(all.hasPrefix(firstLine), "earlier lines are untouched")
        XCTAssertEqual(all.split(separator: "\n").count, 2)
        let laterStamp = try FileManager.default.attributesOfItem(atPath: imagePath)[.modificationDate] as? Date
        XCTAssertEqual(imageStamp, laterStamp, "the base image is never rewritten")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("preview.png").path))
    }

    // MARK: Verification on read

    private func writePackage(mutate: (URL) throws -> Void) throws -> URL {
        let image = png(width: 40, height: 30)
        let url = scratch.appendingPathComponent("Doc.masume")
        try ProjectPackage.create(at: url, manifest: manifest(elements: sampleElements, png: image),
                                  baseImagePNG: image, preview: nil, history: [])
        try mutate(url)
        return url
    }

    func testChecksumMismatchIsRefused() throws {
        let url = try writePackage { url in
            // Same length, last bytes zeroed: the checksum is the only guard.
            try Data(png(width: 40, height: 30).dropLast(8) + [0, 0, 0, 0, 0, 0, 0, 0])
                .write(to: url.appendingPathComponent("base-image.png"))
        }
        XCTAssertThrowsError(try ProjectPackage.read(at: url)) { error in
            XCTAssertEqual(error as? ProjectError, .checksumMismatch)
        }
    }

    func testSizeMismatchIsRefused() throws {
        let url = try writePackage { url in
            // Swap in a different-size image and update the checksum so only
            // the size check can catch it.
            let other = png(width: 20, height: 30)
            try other.write(to: url.appendingPathComponent("base-image.png"))
            var m = try ProjectPackage.decodeManifest(Data(contentsOf: url.appendingPathComponent("manifest.json")))
            m.baseImage.sha256 = ProjectPackage.sha256Hex(other)
            try ProjectPackage.encodeManifest(m).write(to: url.appendingPathComponent("manifest.json"))
        }
        XCTAssertThrowsError(try ProjectPackage.read(at: url)) { error in
            XCTAssertEqual(error as? ProjectError, .sizeMismatch)
        }
    }

    func testMissingBaseImageIsRefused() throws {
        let url = try writePackage { url in
            try FileManager.default.removeItem(at: url.appendingPathComponent("base-image.png"))
        }
        XCTAssertThrowsError(try ProjectPackage.read(at: url)) { error in
            XCTAssertEqual(error as? ProjectError, .missingBaseImage)
        }
    }

    func testDuplicateElementIDsAreRefused() throws {
        let url = try writePackage { url in
            var m = try ProjectPackage.decodeManifest(Data(contentsOf: url.appendingPathComponent("manifest.json")))
            m.elements.append(m.elements[0])
            try ProjectPackage.encodeManifest(m).write(to: url.appendingPathComponent("manifest.json"))
        }
        XCTAssertThrowsError(try ProjectPackage.read(at: url)) { error in
            XCTAssertEqual(error as? ProjectError, .duplicateElementIDs)
        }
    }

    func testMissingPackageIsAnIOError() {
        XCTAssertThrowsError(try ProjectPackage.read(at: scratch.appendingPathComponent("Nope.masume"))) { error in
            guard case .io? = error as? ProjectError else { return XCTFail("\(error)") }
        }
    }

    func testPNGSizeIsReadFromTheHeader() {
        XCTAssertEqual(ProjectPackage.pngPixelSize(png(width: 37, height: 11))?.width, 37)
        XCTAssertEqual(ProjectPackage.pngPixelSize(png(width: 37, height: 11))?.height, 11)
        XCTAssertNil(ProjectPackage.pngPixelSize(Data("not a png".utf8)))
    }
}
