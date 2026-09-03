import AppKit
import CoreGraphics
import AnnotationModel
import AnnotationRender

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
        if pendingPDFReplaces {
            pendingPDFReplaces = false
            load(image: image, sourceURL: source.sourceURL)
        } else {
            receive(image, sourceURL: source.sourceURL)
        }
    }

    func cancelPDFImport() {
        pendingPDF = nil
    }

    func loadImage(_ image: CGImage, sourceURL: URL? = nil) {
        load(image: image, sourceURL: sourceURL)
    }

    /// Loads the first readable image among dropped payloads; beeps if none.
    /// With a document open the image lands on it as a layer.
    @discardableResult
    func loadDroppedImage(_ items: [DroppedImage]) -> Bool {
        for item in items {
            if let pdf = item.pdfSource {
                loadPDF(pdf)
                return true
            }
            guard let image = item.cgImage else { continue }
            receive(image, sourceURL: item.sourceURL)
            return true
        }
        NSSound.beep()
        return false
    }

    /// An incoming image becomes the document when there is none, else a
    /// layer on the open one. Replacing is a separate, explicit command.
    func receive(_ image: CGImage, sourceURL: URL?) {
        if document != nil {
            addImageLayer(image)
        } else {
            load(image: image, sourceURL: sourceURL)
        }
    }

    /// Pastes `image` onto the open document as a selected image layer,
    /// centered and scaled to fit half the canvas, with the remembered mask,
    /// border, and shadow. The pixels join the project's asset store.
    func addImageLayer(_ image: CGImage) {
        guard let project, let document, let png = Renderer.encode(image, as: .png) else { return }
        let assetID = project.registerAsset(png: png, image: image)
        let natural = CGSize(width: image.width, height: image.height)
        let element = ImageElement(rect: ImageElement.placement(naturalSize: natural, in: document.canvasSize),
                                   assetID: assetID, naturalSize: natural, mask: imageMask,
                                   borderColor: strokeColor, borderWidth: imageBorder ? max(strokeWidth, 1) : 0,
                                   shadow: imageShadow)
        perform { $0.add(.image(element)) }
        selection = element.id
    }

    /// Loads an image from the pasteboard, if present. PDF data is imported
    /// through the page path (2×, page picker) rather than as a blurry
    /// first-page NSImage.
    @discardableResult
    func pasteImage(from pb: NSPasteboard = .general, replacing: Bool = false) -> Bool {
        if let data = pb.data(forType: .pdf), let source = PDFPageSource(data: data) {
            pendingPDFReplaces = replacing
            loadPDF(source)
            return true
        }
        if let objs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let nsImage = objs.first,
           let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            if replacing { load(image: cg, sourceURL: nil) } else { receive(cg, sourceURL: nil) }
            return true
        }
        return false
    }
}
