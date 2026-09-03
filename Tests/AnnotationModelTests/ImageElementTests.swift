import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AnnotationModel

/// Image layers: aspect-keeping resize, placement, the package's asset
/// store, and the element's place in the annotation vocabulary.
final class ImageElementTests: XCTestCase {

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

    func testCornerDragKeepsTheAspectRatio() {
        var e = ImageElement(rect: CGRect(x: 100, y: 100, width: 200, height: 100), assetID: UUID(),
                             naturalSize: CGSize(width: 400, height: 200))
        e.moveHandle(.bottomRight, to: CGPoint(x: 500, y: 150))   // wider than tall: width drives
        XCTAssertEqual(e.rect, CGRect(x: 100, y: 100, width: 400, height: 200))
        e.moveHandle(.bottomRight, to: CGPoint(x: 150, y: 400))   // taller: height drives
        XCTAssertEqual(e.rect, CGRect(x: 100, y: 100, width: 600, height: 300))
        e.moveHandle(.topLeft, to: CGPoint(x: 500, y: 350))       // toward the anchor: shrinks, anchor fixed
        XCTAssertEqual(e.rect.maxX, 700)
        XCTAssertEqual(e.rect.maxY, 400)
        XCTAssertEqual(e.rect.width / e.rect.height, 2, accuracy: 0.001)
        e.moveHandle(.topLeft, to: CGPoint(x: 699, y: 399))
        XCTAssertGreaterThanOrEqual(e.rect.width, ImageElement.minimumSide)
        XCTAssertEqual(Set(e.handles().map(\.role)), [.topLeft, .topRight, .bottomLeft, .bottomRight])
    }

    func testPlacementFitsHalfTheCanvasAndNeverScalesUp() {
        let big = ImageElement.placement(naturalSize: CGSize(width: 4000, height: 1000), in: CGSize(width: 1200, height: 800))
        XCTAssertEqual(big.width, 600, accuracy: 0.001)
        XCTAssertEqual(big.height, 150, accuracy: 0.001)
        XCTAssertEqual(big.midX, 600, accuracy: 0.001)
        XCTAssertEqual(big.midY, 400, accuracy: 0.001)
        let small = ImageElement.placement(naturalSize: CGSize(width: 100, height: 50), in: CGSize(width: 1200, height: 800))
        XCTAssertEqual(small.size, CGSize(width: 100, height: 50))
        XCTAssertEqual(ImageElement.placement(naturalSize: .zero, in: CGSize(width: 10, height: 10)), .zero)
    }

    func testAccessorsBorderAndShadow() {
        var a = Annotation.image(ImageElement(rect: CGRect(x: 0, y: 0, width: 10, height: 10), assetID: UUID(),
                                              naturalSize: CGSize(width: 10, height: 10)))
        XCTAssertEqual(a.strokeWidth, 0, "no border by default")
        XCTAssertEqual(a.color, .white)
        XCTAssertEqual(a.imageMask, .rectangle)
        XCTAssertEqual(a.imageShadow, true)
        a.strokeWidth = 6; a.color = .red; a.imageMask = .circle; a.imageShadow = false
        guard case .image(let e) = a else { return XCTFail("kind changed") }
        XCTAssertEqual(e.borderWidth, 6)
        XCTAssertEqual(e.borderColor, .red)
        XCTAssertEqual(e.mask, .circle)
        XCTAssertFalse(e.shadow)
        XCTAssertEqual(a.kindName, "image")
        XCTAssertGreaterThan(a.boundingBox().width, 10, "border pads the bounds")
        var text = Annotation.text(TextElement(origin: .zero))
        XCTAssertNil(text.imageMask)
        text.imageMask = .circle
        XCTAssertNil(text.imageMask)
    }

    func testPackageStoresAssetsOnceAndVerifiesThem() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("masume-assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let base = png(width: 40, height: 30)
        let asset = png(width: 8, height: 6)
        let assetID = UUID()
        let element = ImageElement(rect: CGRect(x: 1, y: 1, width: 8, height: 6), assetID: assetID,
                                   naturalSize: CGSize(width: 8, height: 6))
        var manifest = ProjectManifest(
            id: UUID(), revision: 1, canvasSize: CGSize(width: 40, height: 30), crop: nil, elements: [.image(element)],
            createdAt: Date(), updatedAt: Date(),
            baseImage: BaseImageInfo(fileName: ProjectPackage.baseImageName, sha256: ProjectPackage.sha256Hex(base),
                                     width: 40, height: 30),
            assets: [AssetInfo(id: assetID, fileName: ProjectPackage.assetFileName(for: assetID),
                               sha256: ProjectPackage.sha256Hex(asset), width: 8, height: 6)])
        let url = scratch.appendingPathComponent("Layers.masume")
        try ProjectPackage.create(at: url, manifest: manifest, baseImagePNG: base, preview: nil, history: [],
                                  assets: [assetID: asset])
        let contents = try ProjectPackage.read(at: url)
        XCTAssertEqual(contents.assets[assetID], asset)
        XCTAssertEqual(contents.manifest.elements, [.image(element)])
        let file = url.appendingPathComponent("assets").appendingPathComponent(ProjectPackage.assetFileName(for: assetID))
        let stamp = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date

        // Update with a second asset: the first file is untouched, the new one lands.
        let second = UUID()
        let secondPNG = png(width: 5, height: 5)
        manifest.assets.append(AssetInfo(id: second, fileName: ProjectPackage.assetFileName(for: second),
                                         sha256: ProjectPackage.sha256Hex(secondPNG), width: 5, height: 5))
        manifest.revision = 2
        try ProjectPackage.update(at: url, manifest: manifest, preview: nil, appending: [], assets: [second: secondPNG])
        XCTAssertEqual(try ProjectPackage.read(at: url).assets.count, 2)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, stamp)

        // Tampered asset: refused by name.
        try Data(asset.dropLast(4) + [0, 0, 0, 0]).write(to: file)
        XCTAssertThrowsError(try ProjectPackage.read(at: url)) { error in
            XCTAssertEqual(error as? ProjectError, .badAsset(ProjectPackage.assetFileName(for: assetID)))
        }
        // Missing bytes for a listed asset at create time: refused.
        XCTAssertThrowsError(try ProjectPackage.create(at: scratch.appendingPathComponent("X.masume"), manifest: manifest,
                                                       baseImagePNG: base, preview: nil, history: [], assets: [:]))
    }

    func testManifestWithoutAssetsStillDecodes() throws {
        let m = ProjectManifest(id: UUID(), revision: 0, canvasSize: CGSize(width: 4, height: 4), crop: nil, elements: [],
                                createdAt: Date(), updatedAt: Date(),
                                baseImage: BaseImageInfo(fileName: "base-image.png", sha256: "", width: 4, height: 4))
        let data = try ProjectPackage.encodeManifest(m)
        XCTAssertFalse((String(data: data, encoding: .utf8) ?? "").contains("\"assets\""), "no assets key when there are none")
        XCTAssertEqual(try ProjectPackage.decodeManifest(data).assets, [])
    }
}
