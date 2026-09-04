import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MasumeQuickLookSupport

final class QuickLookPreviewLoaderTests: XCTestCase {
    private var scratch: URL!
    private var package: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("masume-quick-look-tests-\(UUID().uuidString)", isDirectory: true)
        package = scratch.appendingPathComponent("Yearbook.masume", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testLoadsAValidPNGPreview() throws {
        let data = png(width: 320, height: 180)
        try data.write(to: package.appendingPathComponent("preview.png"))

        let asset = try QuickLookPreviewLoader.load(from: package)

        XCTAssertEqual(asset.data, data)
        XCTAssertEqual(asset.pixelSize, CGSize(width: 320, height: 180))
        XCTAssertEqual(asset.image.width, 320)
        XCTAssertEqual(asset.image.height, 180)
    }

    func testMissingPreviewNeverFallsBackToTheEmbeddedOriginal() throws {
        try png(width: 640, height: 480).write(to: package.appendingPathComponent("base-image.png"))

        XCTAssertThrowsError(try QuickLookPreviewLoader.load(from: package)) { error in
            XCTAssertEqual(error as? QuickLookPreviewError, .missingPreview)
        }
    }

    func testRejectsCorruptPreview() throws {
        try Data("not an image".utf8).write(to: package.appendingPathComponent("preview.png"))

        XCTAssertThrowsError(try QuickLookPreviewLoader.load(from: package)) { error in
            XCTAssertEqual(error as? QuickLookPreviewError, .invalidPreview)
        }
    }

    func testRejectsPreviewSymlinkEvenWhenItTargetsAValidImage() throws {
        let original = package.appendingPathComponent("base-image.png")
        try png(width: 640, height: 480).write(to: original)
        try FileManager.default.createSymbolicLink(
            at: package.appendingPathComponent("preview.png"),
            withDestinationURL: original
        )

        XCTAssertThrowsError(try QuickLookPreviewLoader.load(from: package)) { error in
            XCTAssertEqual(error as? QuickLookPreviewError, .invalidPreview)
        }
    }

    func testRejectsAnOversizedPreviewBeforeDecoding() throws {
        let side = QuickLookPreviewLoader.maximumPixelDimension + 1
        try png(width: side, height: 1).write(to: package.appendingPathComponent("preview.png"))

        XCTAssertThrowsError(try QuickLookPreviewLoader.load(from: package)) { error in
            XCTAssertEqual(error as? QuickLookPreviewError, .previewTooLarge)
        }
    }

    func testAspectFitPreservesRatioAndHonorsMaximumSize() {
        XCTAssertEqual(
            QuickLookPreviewLoader.aspectFit(
                CGSize(width: 1_600, height: 900),
                within: CGSize(width: 320, height: 320)
            ),
            CGSize(width: 320, height: 180)
        )
        XCTAssertEqual(
            QuickLookPreviewLoader.aspectFit(
                CGSize(width: 400, height: 800),
                within: CGSize(width: 300, height: 150)
            ),
            CGSize(width: 75, height: 150)
        )
        XCTAssertEqual(QuickLookPreviewLoader.aspectFit(.zero, within: CGSize(width: 300, height: 150)), .zero)
    }

    func testDisclosureTitleMakesEditableProjectRiskExplicit() {
        XCTAssertEqual(
            QuickLookPreviewLoader.previewTitle(for: package),
            "Yearbook.masume — Editable Masume project · contains the original image"
        )
    }

    private func png(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
