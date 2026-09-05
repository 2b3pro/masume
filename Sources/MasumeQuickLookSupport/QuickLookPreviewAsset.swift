import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum QuickLookPreviewError: LocalizedError, Equatable {
    case missingPreview
    case invalidPreview
    case previewTooLarge

    public var errorDescription: String? {
        switch self {
        case .missingPreview:
            "This Masume project does not contain a Quick Look preview."
        case .invalidPreview:
            "The Masume project's Quick Look preview is invalid."
        case .previewTooLarge:
            "The Masume project's Quick Look preview is too large."
        }
    }
}

public struct QuickLookPreviewAsset {
    public let data: Data
    public let image: CGImage
    public let pixelSize: CGSize

    public init(data: Data, image: CGImage, pixelSize: CGSize) {
        self.data = data
        self.image = image
        self.pixelSize = pixelSize
    }
}

/// The only package reader used by the Quick Look extensions. In particular,
/// it never opens manifest.json, base-image.png, or an image-layer asset.
public enum QuickLookPreviewLoader {
    public static let previewFileName = "preview.png"
    public static let disclosure = "Editable Masume project · contains the original image"
    public static let extensionBadge = "MASUME"
    public static let maximumByteCount = 16 * 1_024 * 1_024
    public static let maximumPixelDimension = 4_096

    public static func load(from packageURL: URL, fileManager: FileManager = .default) throws -> QuickLookPreviewAsset {
        let previewURL = packageURL.appendingPathComponent(previewFileName, isDirectory: false)
        guard fileManager.fileExists(atPath: previewURL.path) else {
            throw QuickLookPreviewError.missingPreview
        }

        let values: URLResourceValues
        do {
            values = try previewURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch {
            throw QuickLookPreviewError.invalidPreview
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw QuickLookPreviewError.invalidPreview
        }
        guard let byteCount = values.fileSize, byteCount <= maximumByteCount else {
            throw QuickLookPreviewError.previewTooLarge
        }

        let data: Data
        do {
            data = try Data(contentsOf: previewURL, options: .mappedIfSafe)
        } catch {
            throw QuickLookPreviewError.invalidPreview
        }
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let typeIdentifier = CGImageSourceGetType(source),
              UTType(typeIdentifier as String) == .png,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw QuickLookPreviewError.invalidPreview
        }
        guard width <= maximumPixelDimension, height <= maximumPixelDimension else {
            throw QuickLookPreviewError.previewTooLarge
        }

        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            throw QuickLookPreviewError.invalidPreview
        }
        return QuickLookPreviewAsset(
            data: data,
            image: image,
            pixelSize: CGSize(width: width, height: height)
        )
    }

    public static func aspectFit(_ imageSize: CGSize, within maximumSize: CGSize) -> CGSize {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              maximumSize.width.isFinite, maximumSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              maximumSize.width > 0, maximumSize.height > 0 else { return .zero }
        let scale = min(maximumSize.width / imageSize.width, maximumSize.height / imageSize.height)
        return CGSize(width: floor(imageSize.width * scale), height: floor(imageSize.height * scale))
    }

    public static func previewTitle(for packageURL: URL) -> String {
        "\(packageURL.lastPathComponent) — \(disclosure)"
    }
}
