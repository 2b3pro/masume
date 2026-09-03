import AppKit
import CoreGraphics
import AnnotationModel

/// How the grid thins as the view zooms out: labels every k-th cell so they
/// stay about 24 points apart, and nothing at all once a cell is under six
/// screen points. Pure, so it is testable without a view.
enum GridOverlayMath {
    static let minimumCellPoints: CGFloat = 6
    static let labelSpacingPoints: CGFloat = 24
    /// Space between the canvas edge and a label chip.
    static let labelGap: CGFloat = 10
    /// Height of a label chip (and the width of a one-letter one).
    static let chipSize: CGFloat = 18
    /// What fit mode reserves above and left of the canvas for the labels.
    static var gutter: CGFloat { chipSize + labelGap + 4 }

    /// Label every `k`-th column or row; nil when the grid hides entirely.
    static func labelStride(cellPoints: CGFloat) -> Int? {
        guard cellPoints >= minimumCellPoints else { return nil }
        return max(1, Int((labelSpacingPoints / cellPoints).rounded(.up)))
    }

    /// Where a chip of `extent` starts when it sits `labelGap` beyond
    /// `edge` in the positive direction (above the canvas, in a y-up view),
    /// pinned back inside the view when the canvas edge is too close to or
    /// past `viewMax`.
    static func chipStart(beyond edge: CGFloat, extent: CGFloat, viewMax: CGFloat) -> CGFloat {
        min(edge + labelGap, viewMax - 2 - extent)
    }

    /// Where a chip of `extent` starts when it sits `labelGap` before
    /// `edge` (left of the canvas), pinned inside the view at `viewMin`.
    static func chipStart(before edge: CGFloat, extent: CGFloat, viewMin: CGFloat) -> CGFloat {
        max(edge - labelGap - extent, viewMin + 2)
    }
}

// The grid overlay for CanvasNSView: lines at the exact cell edges mapped
// through the live zoom and pan, column letters along the top margin and
// row numbers down the left, the way a ruler sits beside a page. Drawn on
// screen only; the renderer never sees it, so exports never carry it.

extension CanvasNSView {
    private static let gridLineColor = NSColor.miroBlue.withAlphaComponent(0.35)
    private static let gridEdgeColor = NSColor.miroBlue.withAlphaComponent(0.6)
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    /// Navy ink on a 35% gray chip: reads against the light and the dark
    /// workspace alike, and against any image pixels when pinned inside.
    private static let labelInk = NSColor(srgbRed: 0.12, green: 0.16, blue: 0.36, alpha: 1)
    private static let labelChip = NSColor(white: 0.65, alpha: 1)

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

    /// Column letters in chips above the canvas and row numbers in chips to
    /// its left, every `stride`-th one, spaced `labelGap` from the edge like
    /// a ruler beside a page (fit mode reserves that room). When the canvas
    /// edge is at or past the view's edge, the chips ride just inside the
    /// view over the image, so the axes stay readable while zoomed in.
    /// Chips outside the visible span are skipped. AppKit string drawing
    /// uses the current context, this view's during `draw`.
    private func drawGridLabels(_ grid: GridDefinition, size: CGSize, stride: Int, info: DisplayInfo, bounds: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: Self.labelInk]
        let chip = GridOverlayMath.chipSize
        let view = self.bounds
        // Non-flipped view: above the canvas is the larger y.
        let rowY = GridOverlayMath.chipStart(beyond: bounds.maxY, extent: chip, viewMax: view.maxY)
        let columnsPinned = rowY < bounds.maxY + GridOverlayMath.labelGap
        let rowsPinned = bounds.minX - GridOverlayMath.labelGap < view.minX + 2
        // Pinned on both axes, the two bands cross at the corner; the row
        // band yields there, so a column letter never hides a row number.
        let rowBandWidth = Self.chipWidth(for: "\(grid.rows)", attrs: attrs) + 4
        for c in Swift.stride(from: 0, to: grid.columns, by: stride) {
            let cell = grid.rect(of: GridCell(column: c, row: 0), in: size)
            let center = info.modelToView(CGPoint(x: cell.midX, y: 0))
            guard view.minX...view.maxX ~= center.x else { continue }
            if columnsPinned, rowsPinned, center.x - chip / 2 < view.minX + rowBandWidth { continue }
            drawChip(GridCell.columnName(c), centerX: center.x, minY: rowY, attrs: attrs)
        }
        for r in Swift.stride(from: 0, to: grid.rows, by: stride) {
            let cell = grid.rect(of: GridCell(column: 0, row: r), in: size)
            let center = info.modelToView(CGPoint(x: 0, y: cell.midY))
            guard view.minY...view.maxY ~= center.y else { continue }
            let label = "\(r + 1)"
            let width = Self.chipWidth(for: label, attrs: attrs)
            let x = GridOverlayMath.chipStart(before: bounds.minX, extent: width, viewMin: view.minX)
            drawChip(label, minX: x, centerY: center.y, attrs: attrs)
        }
    }

    private static func chipWidth(for label: String, attrs: [NSAttributedString.Key: Any]) -> CGFloat {
        max(GridOverlayMath.chipSize, ((label as NSString).size(withAttributes: attrs).width + 8).rounded(.up))
    }

    private func drawChip(_ label: String, centerX: CGFloat, minY: CGFloat, attrs: [NSAttributedString.Key: Any]) {
        let width = Self.chipWidth(for: label, attrs: attrs)
        drawChip(label, minX: centerX - width / 2, centerY: minY + GridOverlayMath.chipSize / 2, attrs: attrs)
    }

    /// A rounded square (wider for longer labels) with the label centered.
    private func drawChip(_ label: String, minX: CGFloat, centerY: CGFloat, attrs: [NSAttributedString.Key: Any]) {
        let width = Self.chipWidth(for: label, attrs: attrs)
        let chip = NSRect(x: minX.rounded(), y: (centerY - GridOverlayMath.chipSize / 2).rounded(),
                          width: width, height: GridOverlayMath.chipSize)
        Self.labelChip.setFill()
        NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        let text = label as NSString
        let textSize = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: chip.midX - textSize.width / 2, y: chip.midY - textSize.height / 2), withAttributes: attrs)
    }
}
