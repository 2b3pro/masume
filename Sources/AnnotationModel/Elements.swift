import Foundation
import CoreGraphics

public typealias ElementID = UUID

// MARK: - Segment (arrow / line share geometry)

public struct SegmentElement: Codable, Equatable, Sendable, AnnotationGeometry {
    public var id: ElementID
    public var start: CGPoint
    public var end: CGPoint
    public var color: RGBAColor
    public var width: CGFloat

    public init(id: ElementID = UUID(), start: CGPoint, end: CGPoint,
                color: RGBAColor = .red, width: CGFloat = 6) {
        self.id = id; self.start = start; self.end = end
        self.color = color; self.width = width
    }

    public func boundingBox() -> CGRect {
        CGRect(corner: start, end).insetBy(dx: -width, dy: -width)
    }

    public func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        GeometryMath.distance(from: point, toSegment: start, end) <= max(tolerance, width)
    }

    public func handles() -> [Handle] {
        [Handle(role: .start, position: start), Handle(role: .end, position: end)]
    }

    /// Skitch-style arrow outline: a single filled polygon with a pointed tail,
    /// a shaft that tapers toward the head, and a wide head with backward barbs
    /// and a concave notch. Whole shape scales with `width`. Returns the 6
    /// points in winding order [tip, barbUpper, notchUpper, tail, notchLower,
    /// barbLower], or `[]` for a degenerate (zero-length) arrow.
    public func arrowOutline() -> [CGPoint] {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return [] }   // rendering floor

        let ux = dx / length, uy = dy / length      // axis unit vector
        let px = -uy, py = ux                        // perpendicular unit vector

        let shaftHalf = max(1, width * 0.5)          // shaft half-width at the head base
        let headHalf = max(shaftHalf * 2.4, width * 1.8) // barb half-span
        let headLen = min(max(width * 4.0, 14), length * 0.85)
        let notch = headLen * 0.30                    // concave inset toward the tip
        let baseX = length - headLen
        let notchX = baseX + notch

        func pt(_ t: CGFloat, _ o: CGFloat) -> CGPoint {
            CGPoint(x: start.x + ux * t + px * o, y: start.y + uy * t + py * o)
        }
        return [
            pt(length, 0),       // tip
            pt(baseX, headHalf), // upper barb
            pt(notchX, shaftHalf), // upper notch
            pt(0, 0),            // tail
            pt(notchX, -shaftHalf), // lower notch
            pt(baseX, -headHalf),   // lower barb
        ]
    }

    public mutating func moveHandle(_ role: HandleRole, to point: CGPoint) {
        switch role {
        case .start: start = point
        case .end: end = point
        default: break
        }
    }

    public mutating func translate(by delta: CGVector) {
        start.x += delta.dx; start.y += delta.dy
        end.x += delta.dx; end.y += delta.dy
    }
}

// MARK: - Shape (rectangle / ellipse share geometry)

public struct ShapeElement: Codable, Equatable, Sendable, RectGeometry {
    public var id: ElementID
    public var rect: CGRect
    public var color: RGBAColor
    public var width: CGFloat
    public var fill: RGBAColor?

    public init(id: ElementID = UUID(), rect: CGRect,
                color: RGBAColor = .red, width: CGFloat = 6, fill: RGBAColor? = nil) {
        self.id = id; self.rect = rect; self.color = color
        self.width = width; self.fill = fill
    }

    public func boundingBox() -> CGRect { rect.insetBy(dx: -width, dy: -width) }

    public func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        if fill != nil { return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
        // Stroked: hit if near the edge band but not deep inside.
        let outer = rect.insetBy(dx: -max(tolerance, width), dy: -max(tolerance, width))
        let inner = rect.insetBy(dx: max(tolerance, width), dy: max(tolerance, width))
        return outer.contains(point) && !inner.contains(point)
    }
}

// MARK: - Text

/// Skitch's three text treatments.
public enum TextStyle: String, Codable, Equatable, Sendable, CaseIterable {
    /// Fill plus a thin white halo and a drop shadow; Skitch's default.
    case shadow
    /// Fill plus a heavy black outline, no shadow; Skitch's "highlighted" look.
    case outline
    /// Fill only.
    case plain

    /// The style after this one in the toggle cycle (shadow → outline → plain → shadow).
    public var next: TextStyle {
        let all = Self.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }
}

public struct TextElement: Codable, Equatable, Sendable, RectGeometry {
    public var id: ElementID
    public var origin: CGPoint        // top-left of the text box
    public var size: CGSize           // measured/last-known box size
    public var string: String
    public var font: FontSpec
    public var color: RGBAColor
    public var style: TextStyle
    /// Color of the halo (shadow style) or outline (outline style); white
    /// or black in the UI, ignored by the plain style. On a callout it is
    /// the ink: the border and the text, over a body filled with `color`.
    public var outlineColor: RGBAColor
    public var alignment: LineAlignment
    /// Present when the text is a callout; see `Callout.swift`.
    public var container: TextContainer?

    /// Rect-backed view over the stored origin/size (which stay the encoded
    /// representation). For a callout this is the bubble body; the text
    /// sits inside it at `textRect`.
    public var rect: CGRect {
        get { CGRect(origin: origin, size: size) }
        set { origin = newValue.origin; size = newValue.size }
    }

    /// Narrowest a text box can be dragged.
    public static let minimumWidth: CGFloat = 40
    public static let pointSizeRange: ClosedRange<Double> = 8...400

    /// Plain text is exactly its rect. A callout's box spills past the rect
    /// (border, shadow, scallops) and its tail may reach anywhere.
    public func boundingBox() -> CGRect {
        guard let container else { return rect }
        return rect.union(CGRect(origin: container.tailTip, size: .zero))
            .insetBy(dx: -outerMargin, dy: -outerMargin)
    }

    public func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        if rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) { return true }
        guard let tail = calloutTail() else { return false }
        return GeometryMath.distance(from: point, toSegment: tail.base, tail.tip) <= tailBaseHalfWidth + tolerance
    }

    /// Skitch text handles: left and right edges set the width (the box
    /// wraps at its width and re-measures its height), and the bottom-right
    /// corner scales the font. There are no height handles. A callout adds
    /// its tail tip.
    public func handles() -> [Handle] {
        var handles = [Handle(role: .left, position: CGPoint(x: rect.minX, y: rect.midY)),
                       Handle(role: .right, position: CGPoint(x: rect.maxX, y: rect.midY)),
                       Handle(role: .bottomRight, position: CGPoint(x: rect.maxX, y: rect.maxY))]
        if let container {
            handles.append(Handle(role: .end, position: container.tailTip))
        }
        return handles
    }

    public mutating func moveHandle(_ role: HandleRole, to point: CGPoint) {
        switch role {
        case .right:
            size.width = max(minimumBoxWidth, point.x - origin.x)
        case .left:
            let maxX = rect.maxX
            let newMinX = min(point.x, maxX - minimumBoxWidth)
            origin.x = newMinX
            size.width = maxX - newMinX
        case .bottomRight:
            // Keep the bottom edge under the pointer for the current
            // height-to-size ratio; the caller re-measures the height.
            guard size.height > 0 else { return }
            let scaled = Double((point.y - origin.y) / size.height) * font.pointSize
            font.pointSize = min(Self.pointSizeRange.upperBound, max(Self.pointSizeRange.lowerBound, scaled))
        case .end:
            container?.tailTip = point
        default:
            break
        }
    }

    public mutating func translate(by delta: CGVector) {
        origin.x += delta.dx; origin.y += delta.dy
        container?.tailTip.x += delta.dx
        container?.tailTip.y += delta.dy
    }

    public init(id: ElementID = UUID(), origin: CGPoint, size: CGSize = CGSize(width: 160, height: 40),
                string: String = "", font: FontSpec = FontSpec(), color: RGBAColor = .red,
                style: TextStyle = .shadow, outlineColor: RGBAColor = .white,
                alignment: LineAlignment = .left, container: TextContainer? = nil) {
        self.id = id; self.origin = origin; self.size = size
        self.string = string; self.font = font; self.color = color
        self.style = style; self.outlineColor = outlineColor
        self.alignment = alignment; self.container = container
    }

    /// Text encoded before alignment and containers existed decodes as
    /// left-aligned plain text.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ElementID.self, forKey: .id)
        origin = try c.decode(CGPoint.self, forKey: .origin)
        size = try c.decode(CGSize.self, forKey: .size)
        string = try c.decode(String.self, forKey: .string)
        font = try c.decode(FontSpec.self, forKey: .font)
        color = try c.decode(RGBAColor.self, forKey: .color)
        style = try c.decode(TextStyle.self, forKey: .style)
        outlineColor = try c.decode(RGBAColor.self, forKey: .outlineColor)
        alignment = try c.decodeIfPresent(LineAlignment.self, forKey: .alignment) ?? .left
        container = try c.decodeIfPresent(TextContainer.self, forKey: .container)
    }
}

// MARK: - Redaction (pixelate)

public struct RedactionElement: Codable, Equatable, Sendable, RectGeometry {
    /// Default strengths for freshly created redactions.
    public static let defaultPixelateAmount: CGFloat = 14
    /// Valid pixel-block-size range; scaled defaults are clamped to it.
    public static let amountRange: ClosedRange<CGFloat> = 4...60

    /// The default block size scaled to the canvas (like stroke widths); at
    /// the reference canvas size this is `defaultPixelateAmount` itself.
    public static func defaultAmount(forCanvasSize size: CGSize) -> CGFloat {
        DefaultSizeScale.scaledDefault(reference: defaultPixelateAmount, clampedTo: amountRange,
                                       forCanvasSize: size)
    }

    public var id: ElementID
    public var rect: CGRect
    public var amount: CGFloat        // pixel block size

    public init(id: ElementID = UUID(), rect: CGRect, amount: CGFloat = Self.defaultPixelateAmount) {
        self.id = id; self.rect = rect; self.amount = amount
    }
}
