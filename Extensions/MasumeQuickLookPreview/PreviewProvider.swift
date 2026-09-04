import AppKit
import Quartz
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let asset = try QuickLookPreviewLoader.load(from: request.fileURL)
        let imageSize = QuickLookPreviewLoader.aspectFit(
            asset.pixelSize,
            within: CGSize(width: 1_200, height: 800)
        )
        let contentSize = CGSize(width: max(520, imageSize.width), height: imageSize.height + 54)
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: contentSize) { reply in
            reply.title = QuickLookPreviewLoader.previewTitle(for: request.fileURL)
            reply.stringEncoding = .utf8
            reply.attachments = [
                "preview": QLPreviewReplyAttachment(data: asset.data, contentType: .png),
            ]
            return Data(Self.html.utf8)
        }
        return reply
    }

    private static let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            * { box-sizing: border-box; }
            html, body { width: 100%; height: 100%; margin: 0; }
            body {
              display: flex;
              flex-direction: column;
              align-items: stretch;
              overflow: hidden;
              background: #1b1b1d;
              color: #f7f7f8;
              font: 600 13px -apple-system, BlinkMacSystemFont, sans-serif;
            }
            .preview {
              min-height: 0;
              flex: 1;
              display: flex;
              align-items: center;
              justify-content: center;
              padding: 16px;
            }
            img {
              display: block;
              max-width: 100%;
              max-height: 100%;
              object-fit: contain;
              box-shadow: 0 4px 18px rgba(0, 0, 0, .35);
            }
            .disclosure {
              flex: none;
              min-height: 38px;
              padding: 10px 16px;
              text-align: center;
              background: #f2b544;
              color: #241b0c;
            }
          </style>
        </head>
        <body>
          <div class="preview"><img src="cid:preview" alt="Masume project preview"></div>
          <div class="disclosure">Editable Masume project · contains the original image</div>
        </body>
        </html>
        """
}
