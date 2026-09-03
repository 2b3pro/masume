import Foundation
import CoreGraphics

/// The outline a zone is drawn with.
public enum ZoneShape: String, Codable, Equatable, Sendable, CaseIterable {
    case rectangle, ellipse
}

/// A zone: a region either participant marks out for the other to look
/// at or work from, shown as marching ants and never exported. It is not
/// an annotation: not in the document, not in history, not undoable. The
/// person draws one with the Select tool; an agent sets one through
/// `set_zone` and reads it back as a rect, a grid range, and the address
/// `zone` that any geometry parameter accepts.
public struct Zone: Equatable, Sendable, Codable {
    public var rect: CGRect
    public var shape: ZoneShape

    public init(rect: CGRect, shape: ZoneShape = .rectangle) {
        self.rect = rect.standardized
        self.shape = shape
    }

    /// Smaller than this either way is a click, not a zone.
    public static let minimumSide: CGFloat = 4

    public var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
}

extension GridDefinition {
    /// The smallest range of cells that covers `rect`: the cells holding
    /// its upper-left and lower-right corners (a corner exactly on a cell
    /// edge belongs to the cell before it, so `A1:B2` covers `A1:B2`'s rect).
    /// Nil when `rect` misses the canvas.
    public func range(covering rect: CGRect, in canvasSize: CGSize) -> GridRange? {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let rect = rect.standardized
        guard rect.intersects(canvas) || canvas.contains(rect.origin) else { return nil }
        let first = cell(containing: CGPoint(x: rect.minX, y: rect.minY), in: canvasSize)
        let last = cell(containing: CGPoint(x: rect.maxX - 0.001, y: rect.maxY - 0.001), in: canvasSize)
        return GridRange(first: first, last: last)
    }
}
