import QuickLookThumbnailing

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, (any Error)?) -> Void
    ) {
        do {
            let asset = try QuickLookPreviewLoader.load(from: request.fileURL)
            let contextSize = QuickLookPreviewLoader.aspectFit(asset.pixelSize, within: request.maximumSize)
            guard contextSize != .zero else {
                throw QuickLookPreviewError.invalidPreview
            }
            let reply = QLThumbnailReply(contextSize: contextSize) { context in
                context.interpolationQuality = .high
                context.draw(asset.image, in: CGRect(origin: .zero, size: contextSize))
                return true
            }
            reply.extensionBadge = QuickLookPreviewLoader.extensionBadge
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }
}
