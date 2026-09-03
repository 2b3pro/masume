import CoreGraphics
import Foundation

/// Rasterizes PDF pages with Core Graphics, honoring each page's rotation,
/// on a white background. Shared by the app's PDF import and the CLI.
public enum PDFRasterizer {
    /// Pixels per point for an imported page: 2×, so text stays legible.
    public static let importScale: CGFloat = 2

    public static func document(at url: URL) -> CGPDFDocument? {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else { return nil }
        return document
    }

    public static func document(data: Data) -> CGPDFDocument? {
        guard looksLikePDF(data), let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages > 0 else { return nil }
        return document
    }

    public static func looksLikePDF(_ data: Data) -> Bool {
        data.starts(with: Array("%PDF".utf8))
    }

    /// Size of a page in points once its `/Rotate` is applied.
    public static func pageSize(_ document: CGPDFDocument, page number: Int) -> CGSize? {
        guard let page = document.page(at: number) else { return nil }
        let box = page.getBoxRect(.cropBox)
        let quarterTurns = ((page.rotationAngle % 360) + 360) % 360 / 90
        return quarterTurns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// Rasterizes page `number` (1-based) at `scale` pixels per point.
    public static func render(_ document: CGPDFDocument, page number: Int,
                              scale: CGFloat = PDFRasterizer.importScale) -> CGImage? {
        guard let page = document.page(at: number), let size = pageSize(document, page: number),
              size.width > 0, size.height > 0 else { return nil }
        let pixelW = Int((size.width * scale).rounded(.up))
        let pixelH = Int((size.height * scale).rounded(.up))
        guard pixelW > 0, pixelH > 0, pixelW * pixelH <= 64 * 1024 * 1024 else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: pixelW, height: pixelH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        ctx.interpolationQuality = .high
        // PDF space is y-up like the bitmap, so no flip: scale, then let
        // Core Graphics fit the (rotated) page into the point-sized rect.
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                 rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }
}
