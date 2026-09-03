import Foundation
import CoreGraphics

/// A resolved cell or range: pixel rectangle, center, corners, and the same
/// normalized to the image (0...1), for APIs that want any of them.
public struct GridGeometry: Equatable, Sendable {
    public var rect: CGRect
    public var normalized: CGRect

    public var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    public var corners: [CGPoint] {
        let c = rect.corners
        return [c.topLeft, c.topRight, c.bottomRight, c.bottomLeft]
    }
}

extension GridDefinition {
    /// Edges as integer products divided last: `c * W / cols`, so no float
    /// cell width accumulates drift across the image.
    public func edgeX(_ c: Int, in canvasSize: CGSize) -> CGFloat {
        CGFloat(c) * canvasSize.width / CGFloat(columns)
    }

    public func edgeY(_ r: Int, in canvasSize: CGSize) -> CGFloat {
        CGFloat(r) * canvasSize.height / CGFloat(rows)
    }

    public func contains(_ cell: GridCell) -> Bool {
        (0..<columns).contains(cell.column) && (0..<rows).contains(cell.row)
    }

    /// The cell's (or quadrant's) pixel rectangle; the cell must lie on
    /// this grid. Edges come from the unit rect the same way whole-cell
    /// edges do, so a quadrant's outer edges coincide with its cell's.
    public func rect(of cell: GridCell, in canvasSize: CGSize) -> CGRect {
        let unit = cell.unitRect
        let minX = unit.minX * canvasSize.width / CGFloat(columns)
        let minY = unit.minY * canvasSize.height / CGFloat(rows)
        return CGRect(x: minX, y: minY,
                      width: unit.maxX * canvasSize.width / CGFloat(columns) - minX,
                      height: unit.maxY * canvasSize.height / CGFloat(rows) - minY)
    }

    /// From `first`'s upper-left edge through `last`'s lower-right edge.
    public func rect(of range: GridRange, in canvasSize: CGSize) -> CGRect {
        let a = rect(of: range.first, in: canvasSize)
        let b = rect(of: range.last, in: canvasSize)
        return CGRect(x: a.minX, y: a.minY, width: b.maxX - a.minX, height: b.maxY - a.minY)
    }

    /// Parses and validates a cell against this grid.
    public func cell(_ text: String) throws -> GridCell {
        let cell = try GridCell.parse(text)
        guard contains(cell) else { throw GridError.outOfRange(text, columns: columns, rows: rows) }
        return cell
    }

    /// Parses and validates a cell or range against this grid.
    public func range(_ text: String) throws -> GridRange {
        let range = try GridRange.parse(text)
        for cell in [range.first, range.last] where !contains(cell) {
            throw GridError.outOfRange(cell.name, columns: columns, rows: rows)
        }
        return range
    }

    /// Full geometry for a cell or range written as text.
    public func resolve(_ text: String, in canvasSize: CGSize) throws -> GridGeometry {
        geometry(of: try range(text), in: canvasSize)
    }

    public func geometry(of range: GridRange, in canvasSize: CGSize) -> GridGeometry {
        let r = rect(of: range, in: canvasSize)
        return GridGeometry(rect: r, normalized: normalized(r, in: canvasSize))
    }

    public func normalized(_ rect: CGRect, in canvasSize: CGSize) -> CGRect {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        return CGRect(x: rect.minX / canvasSize.width, y: rect.minY / canvasSize.height,
                      width: rect.width / canvasSize.width, height: rect.height / canvasSize.height)
    }

    /// The cell under an image point; points on or past the far edge land in
    /// the last cell, points before the first edge in the first.
    public func cell(containing point: CGPoint, in canvasSize: CGSize) -> GridCell {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return GridCell(column: 0, row: 0) }
        let c = Int((point.x * CGFloat(columns) / canvasSize.width).rounded(.down))
        let r = Int((point.y * CGFloat(rows) / canvasSize.height).rounded(.down))
        return GridCell(column: min(columns - 1, max(0, c)), row: min(rows - 1, max(0, r)))
    }
}
