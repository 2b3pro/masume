import AppKit
import CoreGraphics
import CoreText
import XCTest
@testable import Masume

final class TextRecognitionTests: XCTestCase {
    func testVisionRecognizesSyntheticTextWithConfidenceAndBounds() throws {
        let image = try XCTUnwrap(syntheticImage(text: "MASUME"))

        let lines = try VisionTextRecognizer().recognize(in: image, languages: ["en-US"], customWords: ["MASUME"])
        let match = try XCTUnwrap(lines.first { $0.text.uppercased().contains("MASUME") })

        XCTAssertGreaterThan(match.confidence, 0)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(match.bounds))
    }

    private func syntheticImage(text: String) -> CGImage? {
        let width = 1000
        let height = 240
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: CTFontCreateWithName("Helvetica-Bold" as CFString, 120, nil),
                .foregroundColor: NSColor.black.cgColor,
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 60, y: 60)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
