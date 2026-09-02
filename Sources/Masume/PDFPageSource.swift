import CoreGraphics
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A PDF waiting to become a base image. Pages are rasterized on demand at
/// `importScale` pixels per point (2×, so text in a screenshot-sized page
/// stays legible), honoring each page's rotation, on a white background.
struct PDFPageSource: Identifiable {
    static let importScale: CGFloat = 2

    let id = UUID()
    let document: CGPDFDocument
    /// Where the PDF came from, for export naming; nil for pasted bytes.
    let sourceURL: URL?

    init?(url: URL) {
        guard Self.isPDF(url), let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else {
            return nil
        }
        self.document = document
        self.sourceURL = url
    }

    init?(data: Data) {
        guard Self.looksLikePDF(data), let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages > 0 else { return nil }
        self.document = document
        self.sourceURL = nil
    }

    var pageCount: Int { document.numberOfPages }

    static func isPDF(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .pdf)
        }
        return url.pathExtension.lowercased() == "pdf"
    }

    static func looksLikePDF(_ data: Data) -> Bool {
        data.starts(with: Array("%PDF".utf8))
    }

    /// Size of a page in points once its `/Rotate` is applied.
    func pageSize(_ number: Int) -> CGSize? {
        guard let page = document.page(at: number) else { return nil }
        let box = page.getBoxRect(.cropBox)
        let quarterTurns = ((page.rotationAngle % 360) + 360) % 360 / 90
        return quarterTurns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// Rasterizes page `number` (1-based) at `scale` pixels per point.
    func render(page number: Int, scale: CGFloat = PDFPageSource.importScale) -> CGImage? {
        guard let page = document.page(at: number), let size = pageSize(number),
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

/// Sheet for a multi-page PDF: click a page to import it at 2×.
struct PDFPagePicker: View {
    let source: PDFPageSource
    let choose: (Int) -> Void
    let cancel: () -> Void
    @Environment(\.colorScheme) private var scheme

    private static let thumbnailWidth: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a page")
                .font(.headline)
            Text("\(source.pageCount) pages. The page is imported as an image at 2×.")
                .font(.miroCaption)
                .foregroundStyle(MiroTheme.textSecondary(scheme))
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.thumbnailWidth), spacing: 16)], spacing: 16) {
                    ForEach(1...source.pageCount, id: \.self) { number in
                        Button {
                            choose(number)
                        } label: {
                            VStack(spacing: 6) {
                                PDFPageThumbnail(source: source, number: number, width: Self.thumbnailWidth)
                                Text("\(number)")
                                    .font(.miroCaption)
                                    .foregroundStyle(MiroTheme.textSecondary(scheme))
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Import page \(number)")
                    }
                }
                .padding(4)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 720, minHeight: 420, idealHeight: 560)
    }
}

/// One page rendered small enough for the picker grid.
private struct PDFPageThumbnail: View {
    let source: PDFPageSource
    let number: Int
    let width: CGFloat

    var body: some View {
        let size = source.pageSize(number) ?? CGSize(width: 1, height: 1.4)
        let scale = width / max(1, size.width)
        Group {
            if let image = source.render(page: number, scale: scale) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.miroDivider
            }
        }
        .frame(width: width, height: width * size.height / max(1, size.width))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.miroDivider, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}
