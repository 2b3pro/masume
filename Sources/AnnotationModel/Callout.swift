import Foundation
import CoreGraphics

/// Horizontal alignment of the lines inside a text box.
public enum LineAlignment: String, Codable, Equatable, Sendable, CaseIterable {
    case left, center, right
}

/// The bubble drawn around a callout's text.
public enum CalloutShape: String, Codable, Equatable, Sendable, CaseIterable {
    /// Rounded rectangle with a triangular tail.
    case speech
    /// Scalloped cloud with a trail of shrinking circles for a tail.
    case thought
}

/// What turns a text box into a callout: a bubble shape and the point its
/// tail points at, in image space. The tail is derived from the box and the
/// tip, so moving either keeps the tail attached.
public struct TextContainer: Codable, Equatable, Sendable {
    public var shape: CalloutShape
    public var tailTip: CGPoint

    public init(shape: CalloutShape, tailTip: CGPoint) {
        self.shape = shape
        self.tailTip = tailTip
    }
}

public enum RectEdge: Equatable, Sendable {
    case top, bottom, left, right
}

/// Where a callout's tail meets its box. `left` and `right` are the ends of
/// the base in ascending order along the edge (x on the top and bottom
/// edges, y on the left and right edges), straddling `base`.
public struct CalloutTail: Equatable, Sendable {
    public var edge: RectEdge
    public var base: CGPoint
    public var left: CGPoint
    public var right: CGPoint
    public var tip: CGPoint
}

// MARK: - Callout geometry on a text box

extension TextElement {
    public var isCallout: Bool { container != nil }

    /// Space between the bubble edge and the text; zero for plain text so
    /// its rect stays the text rect.
    public var padding: CGFloat {
        isCallout ? (font.pointSize * 0.45).rounded() : 0
    }

    /// The rect the text is laid out in: the box inset by the padding. Never
    /// null: a box shorter than twice the padding (one whose height has not
    /// been measured yet) gives a zero-height rect at full inner width, so
    /// measuring against it still wraps at the right width.
    public var textRect: CGRect {
        let pad = padding
        return CGRect(x: rect.minX + pad, y: rect.minY + pad,
                      width: max(0, rect.width - 2 * pad), height: max(0, rect.height - 2 * pad))
    }

    /// Narrowest the box can be dragged, keeping `minimumWidth` for the text.
    public var minimumBoxWidth: CGFloat { Self.minimumWidth + 2 * padding }

    /// Width of the bubble's border stroke.
    public var borderWidth: CGFloat { max(1.5, font.pointSize * 0.09) }

    /// Corner radius of a speech bubble; zero for other shapes.
    public var cornerRadius: CGFloat {
        guard container?.shape == .speech else { return 0 }
        return min(font.pointSize * 0.5, min(rect.width, rect.height) / 3)
    }

    /// Radius of a thought cloud's scallops; zero for other shapes.
    public var bumpRadius: CGFloat {
        guard container?.shape == .thought else { return 0 }
        return max(4, (font.pointSize * 0.4).rounded())
    }

    /// Half the width of the tail where it meets the box.
    public var tailBaseHalfWidth: CGFloat { font.pointSize * 0.55 }

    /// How far the bubble's shadow and scallops spill past the box.
    public var outerMargin: CGFloat { bumpRadius + borderWidth * 2 }

    /// The tail, or nil when the tip is inside the box (or the text is not a
    /// callout). The tail leaves from the edge nearest the tip, its base
    /// centered under the tip but pulled in from the corners so it always
    /// meets a flat stretch of edge.
    public func calloutTail() -> CalloutTail? {
        guard let container else { return nil }
        let tip = container.tailTip
        let dx = tip.x < rect.minX ? rect.minX - tip.x : (tip.x > rect.maxX ? tip.x - rect.maxX : 0)
        let dy = tip.y < rect.minY ? rect.minY - tip.y : (tip.y > rect.maxY ? tip.y - rect.maxY : 0)
        guard dx > 0 || dy > 0 else { return nil }

        let inset = max(cornerRadius, bumpRadius)
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(hi, max(lo, v)) }

        if dx >= dy {
            let edge: RectEdge = tip.x < rect.minX ? .left : .right
            let x = edge == .left ? rect.minX : rect.maxX
            let half = max(0, min(tailBaseHalfWidth, (rect.height - 2 * inset) * 0.45))
            let cy = clamp(tip.y, rect.minY + inset + half, rect.maxY - inset - half)
            return CalloutTail(edge: edge, base: CGPoint(x: x, y: cy),
                               left: CGPoint(x: x, y: cy - half), right: CGPoint(x: x, y: cy + half), tip: tip)
        } else {
            let edge: RectEdge = tip.y < rect.minY ? .top : .bottom
            let y = edge == .top ? rect.minY : rect.maxY
            let half = max(0, min(tailBaseHalfWidth, (rect.width - 2 * inset) * 0.45))
            let cx = clamp(tip.x, rect.minX + inset + half, rect.maxX - inset - half)
            return CalloutTail(edge: edge, base: CGPoint(x: cx, y: y),
                               left: CGPoint(x: cx - half, y: y), right: CGPoint(x: cx + half, y: y), tip: tip)
        }
    }

    /// Wraps the text in a bubble. A box that is already a callout only
    /// changes shape; a plain text box grows by the padding so the text keeps
    /// its width, and gets a tail pointing down and to the left.
    public mutating func makeCallout(_ shape: CalloutShape) {
        if container != nil {
            container?.shape = shape
            return
        }
        container = TextContainer(shape: shape, tailTip: .zero)
        rect = rect.insetBy(dx: -padding, dy: -padding)
        let tip = CGPoint(x: rect.minX + rect.width * 0.25, y: rect.maxY + font.pointSize * 1.2)
        container?.tailTip = tip
    }

    /// Removes the bubble, shrinking the box back to the text rect.
    public mutating func removeCallout() {
        guard isCallout else { return }
        let inner = textRect
        container = nil
        rect = inner
    }
}
