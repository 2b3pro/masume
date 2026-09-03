import AppKit
import CoreGraphics
import AnnotationModel

/// How the grid thins as the view zooms out: labels every k-th cell so they
/// stay about 24 points apart, and nothing at all once a cell is under six
/// screen points. Pure, so it is testable without a view.
enum GridOverlayMath {
    static let minimumCellPoints: CGFloat = 6
    static let labelSpacingPoints: CGFloat = 24

    /// Label every `k`-th column or row; nil when the grid hides entirely.
    static func labelStride(cellPoints: CGFloat) -> Int? {
        guard cellPoints >= minimumCellPoints else { return nil }
        return max(1, Int((labelSpacingPoints / cellPoints).rounded(.up)))
    }
}

// The grid overlay for CanvasNSView: lines at the exact cell edges mapped
// through the live zoom and pan, column letters along the top margin and
// row numbers down the left, the way a ruler sits beside a page. Drawn on
// screen only; the renderer never sees it, so exports never carry it.

extension CanvasNSView {
    private static let gridLineColor = NSColor.miroBlue.withAlphaComponent(0.35)
    private static let gridEdgeColor = NSColor.miroBlue.withAlphaComponent(0.6)
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    private static let labelGap: CGFloat = 3

    func drawGrid(_ doc: Document, info: DisplayInfo, in ctx: CGContext) {
        let grid = doc.grid
        let size = doc.canvasSize
        guard size.width > 0, size.height > 0 else { return }
        let cellPoints = min(size.width / CGFloat(grid.columns), size.height / CGFloat(grid.rows)) * info.scale
        guard let stride = GridOverlayMath.labelStride(cellPoints: cellPoints) else { return }
        let bounds = info.viewRect(forModelRect: CGRect(origin: .zero, size: size))

        ctx.saveGState()
        ctx.setLineWidth(1)
        for c in 0...grid.columns {
            let x = info.modelToView(CGPoint(x: grid.edgeX(c, in: size), y: 0)).x.rounded() + 0.5
            ctx.setStrokeColor((c == 0 || c == grid.columns ? Self.gridEdgeColor : Self.gridLineColor).cgColor)
            ctx.move(to: CGPoint(x: x, y: bounds.minY))
            ctx.addLine(to: CGPoint(x: x, y: bounds.maxY))
            ctx.strokePath()
        }
        for r in 0...grid.rows {
            let y = info.modelToView(CGPoint(x: 0, y: grid.edgeY(r, in: size))).y.rounded() + 0.5
            ctx.setStrokeColor((r == 0 || r == grid.rows ? Self.gridEdgeColor : Self.gridLineColor).cgColor)
            ctx.move(to: CGPoint(x: bounds.minX, y: y))
            ctx.addLine(to: CGPoint(x: bounds.maxX, y: y))
            ctx.strokePath()
        }
        ctx.restoreGState()

        drawGridLabels(grid, size: size, stride: stride, info: info, bounds: bounds)
    }

    /// Column letters above the image and row numbers to its left, every
    /// `stride`-th one, like a ruler in the margin. When the image touches
    /// the view's edge (fit mode does this) the labels move just inside it,
    /// on a small translucent backing so they read over any pixels. AppKit
    /// string drawing uses the current context, this view's during `draw`.
    private func drawGridLabels(_ grid: GridDefinition, size: CGSize, stride: Int, info: DisplayInfo, bounds: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: NSColor.miroBlue,
        ]
        let sample = ("88" as NSString).size(withAttributes: attrs)
        // Non-flipped view: above the image is the larger y.
        let roomAbove = self.bounds.maxY - bounds.maxY >= sample.height + Self.labelGap
        let roomLeft = bounds.minX - self.bounds.minX >= sample.width + Self.labelGap
        for c in Swift.stride(from: 0, to: grid.columns, by: stride) {
            let cell = grid.rect(of: GridCell(column: c, row: 0), in: size)
            let center = info.modelToView(CGPoint(x: cell.midX, y: 0))
            let label = GridCell.columnName(c) as NSString
            let labelSize = label.size(withAttributes: attrs)
            let y = roomAbove ? bounds.maxY + Self.labelGap : bounds.maxY - Self.labelGap - labelSize.height
            drawLabel(label, at: NSPoint(x: center.x - labelSize.width / 2, y: y), size: labelSize,
                      attrs: attrs, backed: !roomAbove)
        }
        for r in Swift.stride(from: 0, to: grid.rows, by: stride) {
            let cell = grid.rect(of: GridCell(column: 0, row: r), in: size)
            let center = info.modelToView(CGPoint(x: 0, y: cell.midY))
            let label = "\(r + 1)" as NSString
            let labelSize = label.size(withAttributes: attrs)
            let x = roomLeft ? bounds.minX - Self.labelGap - labelSize.width : bounds.minX + Self.labelGap
            drawLabel(label, at: NSPoint(x: x, y: center.y - labelSize.height / 2), size: labelSize,
                      attrs: attrs, backed: !roomLeft)
        }
    }

    private func drawLabel(_ label: NSString, at origin: NSPoint, size: NSSize,
                           attrs: [NSAttributedString.Key: Any], backed: Bool) {
        if backed {
            let pill = NSRect(x: origin.x - 3, y: origin.y - 1, width: size.width + 6, height: size.height + 2)
            NSColor.white.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
        }
        label.draw(at: origin, withAttributes: attrs)
    }
}
