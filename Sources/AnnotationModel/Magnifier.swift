import Foundation
import CoreGraphics

/// Outline of a magnifier loupe.
public enum MagnifierShape: String, Codable, Equatable, Sendable, CaseIterable {
    case circle
    /// Rounded square (or rectangle once resized).
    case square
}

/// A loupe: shows the base image under its center magnified by `zoom`,
/// clipped to its shape, with a ring in the stroke color. Only the base
/// image and redactions are magnified, never other annotations.
public struct MagnifierElement: Codable, Equatable, Sendable, RectGeometry {
    public static let zoomRange: ClosedRange<CGFloat> = 1.5...8
    public static let defaultZoom: CGFloat = 2

    public var id: ElementID
    public var rect: CGRect
    public var shape: MagnifierShape
    public var zoom: CGFloat {
        didSet { zoom = Self.clampedZoom(zoom) }
    }
    public var color: RGBAColor
    public var width: CGFloat

    public init(id: ElementID = UUID(), rect: CGRect, shape: MagnifierShape = .circle,
                zoom: CGFloat = MagnifierElement.defaultZoom, color: RGBAColor = .red, width: CGFloat = 6) {
        self.id = id; self.rect = rect; self.shape = shape
        self.zoom = Self.clampedZoom(zoom); self.color = color; self.width = width
    }

    public static func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        min(zoomRange.upperBound, max(zoomRange.lowerBound, zoom))
    }

    public var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    /// Corner radius of the square shape; zero for the circle.
    public var cornerRadius: CGFloat {
        shape == .square ? min(rect.width, rect.height) * 0.18 : 0
    }

    public func boundingBox() -> CGRect { rect.insetBy(dx: -width, dy: -width) }

    /// Creation drags the `.end` handle: the loupe grows as a circle or
    /// square around the mouse-down point, which stays its center. Corner
    /// handles resize freely afterwards.
    public mutating func moveHandle(_ role: HandleRole, to point: CGPoint) {
        switch role {
        case .end:
            let c = center
            let r = GeometryMath.distance(from: point, to: c)
            rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        default:
            rect = rect.movingCorner(role, to: point)
        }
    }
}
