import CoreGraphics
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AnnotationRender

/// A PDF waiting to become a base image. Pages are rasterized on demand at
/// `importScale` pixels per point (2×, so text in a screenshot-sized page
/// stays legible), honoring each page's rotation, on a white background.
struct PDFPageSource: Identifiable {
    static let importScale = PDFRasterizer.importScale

    let id = UUID()
    let document: CGPDFDocument
    /// Where the PDF came from, for export naming; nil for pasted bytes.
    let sourceURL: URL?

    init?(url: URL) {
        guard Self.isPDF(url), let document = PDFRasterizer.document(at: url) else { return nil }
        self.document = document
        self.sourceURL = url
    }

    init?(data: Data) {
        guard let document = PDFRasterizer.document(data: data) else { return nil }
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

    static func looksLikePDF(_ data: Data) -> Bool { PDFRasterizer.looksLikePDF(data) }

    func pageSize(_ number: Int) -> CGSize? { PDFRasterizer.pageSize(document, page: number) }

    func render(page number: Int, scale: CGFloat = PDFRasterizer.importScale) -> CGImage? {
        PDFRasterizer.render(document, page: number, scale: scale)
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
                .foregroundStyle(Theme.textSecondary(scheme))
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
                                    .foregroundStyle(Theme.textSecondary(scheme))
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
                    .scaledToFit()
            } else {
                Color.miroDivider
            }
        }
        .frame(width: width, height: width * size.height / max(1, size.width))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.miroDivider, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}
