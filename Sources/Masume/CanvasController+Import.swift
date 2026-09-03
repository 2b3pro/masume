import AppKit
import CoreGraphics
import AnnotationModel

// Image and PDF import paths for CanvasController: file, drop, and paste.
// Split from CanvasController.swift for size.

extension CanvasController {
    func loadImage(at url: URL) {
        if PDFPageSource.isPDF(url) {
            guard let source = PDFPageSource(url: url) else {
                NSSound.beep()
                return
            }
            loadPDF(source)
            return
        }
        guard let image = ImageLoader.cgImage(from: url) else {
            NSSound.beep()
            return
        }
        load(image: image, sourceURL: url)
    }

    // MARK: PDF import

    /// Imports a one-page PDF straight away; a longer one waits for a page.
    func loadPDF(_ source: PDFPageSource) {
        if source.pageCount == 1 {
            choosePDFPage(1, from: source)
        } else {
            pendingPDF = source
        }
    }

    /// Rasterizes `page` of `source` (or of the pending PDF) at the import
    /// scale and makes it the base image. Beeps and keeps the current
    /// document when the page cannot be rendered.
    func choosePDFPage(_ page: Int, from source: PDFPageSource? = nil) {
        guard let source = source ?? pendingPDF else { return }
        pendingPDF = nil
        guard let image = source.render(page: page) else {
            NSSound.beep()
            return
        }
        load(image: image, sourceURL: source.sourceURL)
    }

    func cancelPDFImport() {
        pendingPDF = nil
    }

    func loadImage(_ image: CGImage, sourceURL: URL? = nil) {
        load(image: image, sourceURL: sourceURL)
    }

    /// Loads the first readable image among dropped payloads; beeps if none.
    @discardableResult
    func loadDroppedImage(_ items: [DroppedImage]) -> Bool {
        for item in items {
            if let pdf = item.pdfSource {
                loadPDF(pdf)
                return true
            }
            guard let image = item.cgImage else { continue }
            load(image: image, sourceURL: item.sourceURL)
            return true
        }
        NSSound.beep()
        return false
    }

    /// Loads an image from the pasteboard, if present. PDF data is imported
    /// through the page path (2×, page picker) rather than as a blurry
    /// first-page NSImage.
    @discardableResult
    func pasteImage(from pb: NSPasteboard = .general) -> Bool {
        if let data = pb.data(forType: .pdf), let source = PDFPageSource(data: data) {
            loadPDF(source)
            return true
        }
        if let objs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let nsImage = objs.first,
           let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            load(image: cg, sourceURL: nil)
            return true
        }
        return false
    }
}
