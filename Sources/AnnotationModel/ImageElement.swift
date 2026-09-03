import Foundation
import CoreGraphics

/// How a pasted image layer is clipped.
public enum ImageMask: String, Codable, Equatable, Sendable, CaseIterable {
    case rectangle
    case rounded
    case circle
}

/// A pasted image laid over the base image: an ordered element like any
/// other, so it is undoable, attributed, and saved. The pixels live in the
/// package's asset store under `assetID`; the element holds only the
/// reference and its natural size. Corner handles keep the aspect ratio.
public struct ImageElement: Codable, Equatable, Sendable, RectGeometry {
    public static let minimumSide: CGFloat = 8

    public var id: ElementID
    public var rect: CGRect
    public var assetID: UUID
    /// Pixel size of the asset, the aspect the handles preserve.
    public var naturalSize: CGSize
    public var mask: ImageMask
    public var borderColor: RGBAColor
    /// Zero means no border.
    public var borderWidth: CGFloat
    public var shadow: Bool

    public init(id: ElementID = UUID(), rect: CGRect, assetID: UUID, naturalSize: CGSize,
                mask: ImageMask = .rectangle, borderColor: RGBAColor = .white, borderWidth: CGFloat = 0,
                shadow: Bool = true) {
        self.id = id; self.rect = rect; self.assetID = assetID; self.naturalSize = naturalSize
        self.mask = mask; self.borderColor = borderColor; self.borderWidth = borderWidth; self.shadow = shadow
    }

    /// Corner radius of the rounded mask; zero for the others.
    public var cornerRadius: CGFloat {
        mask == .rounded ? min(rect.width, rect.height) * 0.12 : 0
    }

    public func boundingBox() -> CGRect {
        let margin = max(borderWidth, shadow ? 6 : 0)
        return rect.insetBy(dx: -margin, dy: -margin)
    }

    /// Corner drags keep the current aspect ratio, driven by whichever axis
    /// the pointer moved more along; the opposite corner stays put.
    public mutating func moveHandle(_ role: HandleRole, to point: CGPoint) {
        guard let opposite = role.opposite else { return }
        let c = rect.corners
        let anchor: CGPoint
        switch opposite {
        case .topLeft: anchor = c.topLeft
        case .topRight: anchor = c.topRight
        case .bottomLeft: anchor = c.bottomLeft
        default: anchor = c.bottomRight
        }
        let aspect = max(rect.width, 1) / max(rect.height, 1)
        var width = abs(point.x - anchor.x)
        var height = abs(point.y - anchor.y)
        if width / aspect >= height { height = width / aspect } else { width = height * aspect }
        width = max(width, Self.minimumSide)
        height = max(height, Self.minimumSide / aspect)
        let x = point.x >= anchor.x ? anchor.x : anchor.x - width
        let y = point.y >= anchor.y ? anchor.y : anchor.y - height
        rect = CGRect(x: x, y: y, width: width, height: height)
    }

    /// Where a pasted image lands: centered, scaled down (never up) so it
    /// covers at most `fraction` of the canvas on either axis.
    public static func placement(naturalSize: CGSize, in canvasSize: CGSize, fraction: CGFloat = 0.5) -> CGRect {
        guard naturalSize.width > 0, naturalSize.height > 0 else { return .zero }
        let scale = min(1, canvasSize.width * fraction / naturalSize.width, canvasSize.height * fraction / naturalSize.height)
        let size = CGSize(width: naturalSize.width * scale, height: naturalSize.height * scale)
        return CGRect(x: (canvasSize.width - size.width) / 2, y: (canvasSize.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

/// An image asset as stored in the package: `assets/<fileName>`, verified by
/// checksum on read.
public struct AssetInfo: Codable, Equatable, Sendable {
    public var id: UUID
    public var fileName: String
    public var sha256: String
    public var width: Int
    public var height: Int

    public init(id: UUID, fileName: String, sha256: String, width: Int, height: Int) {
        self.id = id; self.fileName = fileName; self.sha256 = sha256; self.width = width; self.height = height
    }
}
