import XCTest
import AppKit
import AnnotationModel
@testable import Masume

/// PDF import: pages rasterize at 2× with the page's rotation applied, a
/// one-page PDF loads straight in, and a longer one waits for a page choice
/// from the picker. Paste and drop route PDFs the same way.
@MainActor
final class PDFImportTests: XCTestCase {

    /// A PDF whose page N is a solid color of the given size in points.
    private func makePDF(pages: [(size: CGSize, color: (CGFloat, CGFloat, CGFloat))]) -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        var mediaBox = CGRect(origin: .zero, size: pages[0].size)
        let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        for page in pages {
            var box = CGRect(origin: .zero, size: page.size)
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)]
            ctx.beginPDFPage(info as CFDictionary)
            ctx.setFillColor(red: page.color.0, green: page.color.1, blue: page.color.2, alpha: 1)
            ctx.fill(box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    private let twoPages: [(size: CGSize, color: (CGFloat, CGFloat, CGFloat))] = [
        (CGSize(width: 200, height: 100), (1, 0, 0)),
        (CGSize(width: 100, height: 200), (0, 0, 1)),
    ]

    private func centerPixel(_ image: CGImage) -> (r: Int, g: Int, b: Int) {
        var buf = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2 + 0.5, y: -CGFloat(image.height) / 2 + 0.5,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(buf[0]), Int(buf[1]), Int(buf[2]))
    }

    private func makeController() -> CanvasController {
        CanvasController(preferencesStore: InMemoryToolPreferencesStore())
    }

    private func tempURL(_ data: Data, ext: String = "pdf") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("masume-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    // MARK: Rasterizing

    func testPagesRenderAtTwoXWithTheirOwnSizeAndContent() throws {
        let source = try XCTUnwrap(PDFPageSource(data: makePDF(pages: twoPages)))
        XCTAssertEqual(source.pageCount, 2)
        let first = try XCTUnwrap(source.render(page: 1))
        XCTAssertEqual(first.width, 400)
        XCTAssertEqual(first.height, 200)
        XCTAssertGreaterThan(centerPixel(first).r, 200)
        XCTAssertLessThan(centerPixel(first).b, 60)
        let second = try XCTUnwrap(source.render(page: 2))
        XCTAssertEqual(second.width, 200)
        XCTAssertEqual(second.height, 400)
        XCTAssertGreaterThan(centerPixel(second).b, 200)
        XCTAssertNil(source.render(page: 3))
        XCTAssertEqual(source.pageSize(2), CGSize(width: 100, height: 200))
    }

    func testThumbnailScaleIsHonored() throws {
        let source = try XCTUnwrap(PDFPageSource(data: makePDF(pages: twoPages)))
        let thumb = try XCTUnwrap(source.render(page: 1, scale: 0.5))
        XCTAssertEqual(thumb.width, 100)
        XCTAssertEqual(thumb.height, 50)
    }

    func testNonPDFBytesAndFilesAreRejected() throws {
        XCTAssertNil(PDFPageSource(data: Data("hello".utf8)))
        XCTAssertFalse(PDFPageSource.looksLikePDF(Data("hello".utf8)))
        XCTAssertTrue(PDFPageSource.looksLikePDF(makePDF(pages: twoPages)))
        let png = try tempURL(Data([0x89, 0x50, 0x4E, 0x47]), ext: "png")
        XCTAssertFalse(PDFPageSource.isPDF(png))
        XCTAssertNil(PDFPageSource(url: png))
        let pdf = try tempURL(makePDF(pages: twoPages))
        XCTAssertTrue(PDFPageSource.isPDF(pdf))
        XCTAssertEqual(PDFPageSource(url: pdf)?.sourceURL, pdf)
    }

    // MARK: Controller flow

    func testSinglePagePDFLoadsDirectly() throws {
        let controller = makeController()
        let url = try tempURL(makePDF(pages: [twoPages[0]]))
        controller.loadImage(at: url)
        XCTAssertNil(controller.pendingPDF)
        XCTAssertEqual(controller.document?.canvasSize, CGSize(width: 400, height: 200))
        XCTAssertEqual(controller.sourceURL, url, "export naming follows the PDF")
    }

    func testMultiPagePDFWaitsForAPageChoice() throws {
        let controller = makeController()
        controller.loadImage(at: try tempURL(makePDF(pages: twoPages)))
        XCTAssertNil(controller.document, "nothing loads until a page is chosen")
        XCTAssertEqual(controller.pendingPDF?.pageCount, 2)

        controller.choosePDFPage(2)
        XCTAssertNil(controller.pendingPDF)
        XCTAssertEqual(controller.document?.canvasSize, CGSize(width: 200, height: 400))
    }

    func testCancellingKeepsTheCurrentDocument() throws {
        let controller = makeController()
        let ctx = CGContext(data: nil, width: 30, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        controller.loadImage(ctx.makeImage()!)
        controller.loadImage(at: try tempURL(makePDF(pages: twoPages)))
        XCTAssertNotNil(controller.pendingPDF)
        controller.cancelPDFImport()
        XCTAssertNil(controller.pendingPDF)
        XCTAssertEqual(controller.document?.canvasSize, CGSize(width: 30, height: 20))
    }

    func testDroppedPDFBytesAndFilesUseThePagePath() throws {
        let controller = makeController()
        let data = makePDF(pages: twoPages)
        XCTAssertEqual(DroppedImage.data(data).pdfSource?.pageCount, 2)
        XCTAssertNil(DroppedImage.data(Data([1, 2, 3])).pdfSource)
        XCTAssertTrue(controller.loadDroppedImage([.data(data)]))
        XCTAssertEqual(controller.pendingPDF?.pageCount, 2)
        controller.cancelPDFImport()

        let url = try tempURL(makePDF(pages: [twoPages[1]]))
        XCTAssertTrue(controller.loadDroppedImage([.file(url)]))
        XCTAssertNil(controller.pendingPDF)
        XCTAssertEqual(controller.document?.canvasSize, CGSize(width: 200, height: 400))
    }

    func testPastedPDFDataIsImportedAtTwoXNotAsABlurryImage() {
        let controller = makeController()
        let pb = NSPasteboard(name: NSPasteboard.Name("masume.test.\(UUID().uuidString)"))
        pb.declareTypes([.pdf], owner: nil)
        pb.setData(makePDF(pages: [twoPages[0]]), forType: .pdf)
        XCTAssertTrue(controller.pasteImage(from: pb))
        XCTAssertEqual(controller.document?.canvasSize, CGSize(width: 400, height: 200),
                       "2× the 200×100pt page, not the 72dpi NSImage rasterization")
        pb.releaseGlobally()
    }
}
