import XCTest
import CoreGraphics
import AnnotationModel
import AnnotationRender
@testable import Masume

/// Pasting onto an open document adds an image layer whose pixels travel
/// with the project; replacing is a separate, explicit act.
@MainActor
final class ImageLayerTests: XCTestCase {

    private var scratch: URL!
    private var store: RecoveryStore!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("masume-layers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = RecoveryStore(directory: scratch.appendingPathComponent("recovery"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func image(_ w: Int, _ h: Int, red: CGFloat = 1) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: red, green: 0, blue: 1 - red, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func makeController() -> CanvasController {
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore(), recoveryStore: store)
        controller.loadImage(image(1200, 800, red: 0))   // blue base
        return controller
    }

    private func pasteboard(with cg: CGImage) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("masume.layers.\(UUID().uuidString)"))
        pb.clearContents()
        pb.writeObjects([NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))])
        return pb
    }

    func testPasteOntoADocumentAddsASelectedLayerAndKeepsTheBase() throws {
        let controller = makeController()
        let base = controller.project?.id
        XCTAssertTrue(controller.pasteImage(from: pasteboard(with: image(400, 200))))
        XCTAssertEqual(controller.project?.id, base, "same document")
        XCTAssertEqual(controller.document?.canvasSize, CGSize(width: 1200, height: 800), "base untouched")
        guard case .image(let layer)? = controller.document?.elements.first else { return XCTFail("no layer") }
        XCTAssertEqual(controller.selection, layer.id)
        XCTAssertEqual(layer.naturalSize, CGSize(width: 400, height: 200))
        XCTAssertEqual(layer.rect, CGRect(x: 400, y: 300, width: 400, height: 200), "centered, fits half")
        XCTAssertEqual(controller.project?.assetImages[layer.assetID]?.width, 400)
        XCTAssertEqual(controller.project?.revision, 1)
        XCTAssertTrue(controller.project?.history.last?.summary.contains("added image") == true)
        XCTAssertTrue(controller.canUndo)
    }

    func testPasteWithoutADocumentStillOpensOne() {
        let controller = CanvasController(preferencesStore: InMemoryToolPreferencesStore(), recoveryStore: store)
        XCTAssertTrue(controller.pasteImage(from: pasteboard(with: image(300, 100))))
        XCTAssertEqual(controller.document?.canvasSize, CGSize(width: 300, height: 100))
        XCTAssertEqual(controller.document?.elements.count, 0)
    }

    func testReplaceIsExplicit() {
        let controller = makeController()
        let before = controller.project?.id
        XCTAssertTrue(controller.pasteImage(from: pasteboard(with: image(300, 100)), replacing: true))
        XCTAssertNotEqual(controller.project?.id, before)
        XCTAssertEqual(controller.document?.canvasSize, CGSize(width: 300, height: 100))
    }

    func testDropOntoADocumentAddsALayerToo() throws {
        let controller = makeController()
        let png = try XCTUnwrap(Renderer.encode(image(50, 50), as: .png))
        XCTAssertTrue(controller.loadDroppedImage([.data(png)]))
        XCTAssertEqual(controller.document?.elements.count, 1)
        XCTAssertEqual(controller.document?.canvasSize, CGSize(width: 1200, height: 800))
    }

    func testLayerAssetsSurviveRecoverySaveAndOpen() throws {
        let controller = makeController()
        controller.imageMask = .circle
        controller.imageBorder = true
        controller.strokeWidth = 6
        controller.strokeColor = .yellow
        controller.pasteImage(from: pasteboard(with: image(400, 200)))
        guard case .image(let layer)? = controller.document?.elements.first else { return XCTFail("no layer") }
        XCTAssertEqual(layer.mask, .circle)
        XCTAssertEqual(layer.borderWidth, 6)
        XCTAssertEqual(layer.borderColor, .yellow)

        let recovered = try ProjectPackage.read(at: try XCTUnwrap(controller.project).recoveryURL)
        XCTAssertEqual(recovered.assets.count, 1)
        XCTAssertEqual(recovered.manifest.assets.first?.id, layer.assetID)

        let url = scratch.appendingPathComponent("Layers.masume")
        try controller.saveProject(to: url, newIdentity: false)
        let reader = CanvasController(preferencesStore: InMemoryToolPreferencesStore(),
                                      recoveryStore: RecoveryStore(directory: scratch.appendingPathComponent("r2")))
        try reader.openProject(at: url)
        XCTAssertEqual(reader.document?.elements, controller.document?.elements)
        XCTAssertEqual(reader.project?.assetImages[layer.assetID]?.width, 400)
        // The flattened export shows the layer: red pixels at its center over the blue base.
        let png = try XCTUnwrap(ExportService.pngData(reader))
        let flat = try XCTUnwrap(ImageLoader.cgImage(from: png))
        var buf = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(flat, in: CGRect(x: -600 + 0.5, y: -400 + 0.5, width: 1200, height: 800))
        XCTAssertGreaterThan(Int(buf[0]), 200, "red layer at the center")
    }

    func testControlsEditTheSelectedLayer() throws {
        let controller = makeController()
        controller.pasteImage(from: pasteboard(with: image(400, 200)))
        XCTAssertTrue(controller.editsImageLayer)
        controller.imageMask = .rounded
        controller.imageShadow = false
        controller.imageBorder = true
        guard case .image(let layer)? = controller.document?.elements.first else { return XCTFail("no layer") }
        XCTAssertEqual(layer.mask, .rounded)
        XCTAssertFalse(layer.shadow)
        XCTAssertGreaterThan(layer.borderWidth, 0)
        controller.imageBorder = false
        guard case .image(let bare)? = controller.document?.elements.first else { return XCTFail("no layer") }
        XCTAssertEqual(bare.borderWidth, 0)
        controller.selection = nil
        XCTAssertFalse(controller.editsImageLayer)
    }
}

/// Pixel checks for the mask, border, and shadow.
final class ImageLayerRenderTests: XCTestCase {

    private func solid(_ w: Int, _ h: Int, r: CGFloat, g: CGFloat, b: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        var buf = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &buf, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let i = (y * image.width + x) * 4
        return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
    }

    func testMaskClipsBorderTracesAndShadowIsOptional() {
        let base = solid(200, 200, r: 1, g: 1, b: 1)
        let asset = solid(50, 50, r: 1, g: 0, b: 0)
        let id = UUID()
        func render(_ mask: ImageMask, border: CGFloat, shadow: Bool) -> CGImage {
            var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 200, height: 200))
            doc.add(.image(ImageElement(rect: CGRect(x: 50, y: 50, width: 100, height: 100), assetID: id,
                                        naturalSize: CGSize(width: 50, height: 50), mask: mask,
                                        borderColor: .blue, borderWidth: border, shadow: shadow)))
            return Renderer.flatten(doc, baseImage: base, scale: 1, assets: [id: asset])!
        }
        let rect = render(.rectangle, border: 0, shadow: false)
        XCTAssertGreaterThan(pixel(rect, 100, 100).r, 200)
        XCTAssertLessThan(pixel(rect, 52, 52).g, 60, "rectangle mask keeps the corner")
        XCTAssertGreaterThan(pixel(rect, 100, 152).g, 240, "no shadow below")

        let circle = render(.circle, border: 0, shadow: false)
        XCTAssertGreaterThan(pixel(circle, 52, 52).g, 240, "circle mask drops the corner")
        XCTAssertLessThan(pixel(circle, 100, 100).g, 60)

        let bordered = render(.rectangle, border: 6, shadow: false)
        let edge = pixel(bordered, 100, 50)
        XCTAssertGreaterThan(edge.b, 200, "blue border on the edge")
        XCTAssertLessThan(edge.r, 80)

        let shadowed = render(.rectangle, border: 0, shadow: true)
        XCTAssertLessThan(pixel(shadowed, 100, 152).g, 240, "shadow darkens just below")
    }
}

@MainActor
final class OptionDropTests: XCTestCase {
    func testOptionDropOpensANewTabAndPlainDropLayers() throws {
        let store = RecoveryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("masume-optdrop-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let workspace = WorkspaceController(confirmDiscard: { _, _, _ in true }, confirmSave: { _ in .discard },
                                            requestTermination: {}, recoveryStore: store)
        let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = ctx.makeImage()!
        let png = try XCTUnwrap(Renderer.encode(image, as: .png))
        workspace.active.loadImage(image)
        let first = workspace.active

        workspace.openDroppedInNewTab([.data(png)])
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertTrue(workspace.active !== first)
        XCTAssertEqual(workspace.active.document?.elements.count, 0, "a new document, not a layer")
        XCTAssertEqual(first.document?.elements.count, 0, "the first tab was not touched")

        XCTAssertTrue(workspace.active.loadDroppedImage([.data(png)]))
        XCTAssertEqual(workspace.active.document?.elements.count, 1, "a plain drop is a layer")

        workspace.openDroppedInNewTab([.data(Data([1, 2, 3]))])
        XCTAssertEqual(workspace.tabs.count, 2, "an unreadable drop leaves no empty tab")
        workspace.discardAllRecovery()
    }
}
