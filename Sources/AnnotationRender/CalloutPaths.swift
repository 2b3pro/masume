import Foundation
import CoreGraphics
import AnnotationModel

/// Outline geometry for callout bubbles. Paths are built in model space
/// (y-down) from pure geometry, so they render the same on screen and in
/// exports and need no orientation-aware arc flags.
enum CalloutPaths {

    /// The bubble body. A speech bubble is a rounded rectangle with the
    /// tail folded into its outline so one stroke traces both; a thought
    /// cloud is a scalloped rectangle (its tail is drawn as separate
    /// circles, see `thoughtTailCircles`).
    static func bodyPath(for e: TextElement) -> CGPath {
        switch e.container?.shape {
        case .thought: return cloudPath(for: e)
        case .speech, nil: return speechPath(for: e)
        }
    }

    // MARK: Speech

    private static func speechPath(for e: TextElement) -> CGPath {
        let r = e.rect
        let radius = max(0, e.cornerRadius)
        let tail = e.calloutTail()
        let path = CGMutablePath()

        // Walk the perimeter clockwise in image terms: top edge left to
        // right, right edge top to bottom, bottom edge right to left, left
        // edge bottom to top. `addArc(tangent1End:tangent2End:)` draws the
        // straight run up to each corner and then rounds it.
        func corner(_ tangent: CGPoint, _ next: CGPoint) {
            if radius > 0.5 {
                path.addArc(tangent1End: tangent, tangent2End: next, radius: radius)
            } else {
                path.addLine(to: tangent)
            }
        }
        // Detours through the tail when it leaves from `edge`; `first` and
        // `second` are the base ends in walking order.
        func detour(on edge: RectEdge, _ first: CGPoint, _ second: CGPoint) {
            guard let tail, tail.edge == edge else { return }
            path.addLine(to: first)
            path.addLine(to: tail.tip)
            path.addLine(to: second)
        }

        path.move(to: CGPoint(x: r.minX + radius, y: r.minY))
        if let tail { detour(on: .top, tail.left, tail.right) }
        corner(CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.minY + radius))
        if let tail { detour(on: .right, tail.left, tail.right) }
        corner(CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX - radius, y: r.maxY))
        if let tail { detour(on: .bottom, tail.right, tail.left) }
        corner(CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY - radius))
        if let tail { detour(on: .left, tail.right, tail.left) }
        corner(CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX + radius, y: r.minY))
        path.closeSubpath()
        return path
    }

    // MARK: Thought

    private static func cloudPath(for e: TextElement) -> CGPath {
        let r = e.rect
        let bump = e.bumpRadius
        let path = CGMutablePath()
        let c = r.corners
        // Edges in walking order with their outward normals (y-down space).
        let edges: [(from: CGPoint, to: CGPoint, normal: CGVector)] = [
            (c.topLeft, c.topRight, CGVector(dx: 0, dy: -1)),
            (c.topRight, c.bottomRight, CGVector(dx: 1, dy: 0)),
            (c.bottomRight, c.bottomLeft, CGVector(dx: 0, dy: 1)),
            (c.bottomLeft, c.topLeft, CGVector(dx: -1, dy: 0)),
        ]
        path.move(to: c.topLeft)
        for edge in edges {
            let length = GeometryMath.distance(from: edge.from, to: edge.to)
            let count = max(1, Int((length / (bump * 1.7)).rounded()))
            let chord = length / CGFloat(count)
            let bulge = min(bump, chord * 0.45)
            let dir = CGVector(dx: (edge.to.x - edge.from.x) / length, dy: (edge.to.y - edge.from.y) / length)
            for i in 0..<count {
                let a = CGPoint(x: edge.from.x + dir.dx * chord * CGFloat(i),
                                y: edge.from.y + dir.dy * chord * CGFloat(i))
                let m = CGPoint(x: a.x + dir.dx * chord / 2, y: a.y + dir.dy * chord / 2)
                // Sample an outward-bulging arc from a to the next anchor.
                let steps = 10
                for s in 1...steps {
                    let t = CGFloat(s) / CGFloat(steps)
                    let along = cos(.pi * t), out = sin(.pi * t)
                    path.addLine(to: CGPoint(x: m.x + (a.x - m.x) * along + edge.normal.dx * bulge * out,
                                             y: m.y + (a.y - m.y) * along + edge.normal.dy * bulge * out))
                }
            }
        }
        path.closeSubpath()
        return path
    }

    /// The thought cloud's tail: circles shrinking from the box toward the
    /// tip, spread along the line between them. Empty when there is no tail.
    static func thoughtTailCircles(for e: TextElement) -> [(center: CGPoint, radius: CGFloat)] {
        guard e.container?.shape == .thought, let tail = e.calloutTail() else { return [] }
        let size = CGFloat(e.font.pointSize)
        let fractions: [CGFloat] = [0.22, 0.55, 0.88]
        let radii: [CGFloat] = [0.32, 0.22, 0.13]
        return zip(fractions, radii).map { f, k in
            (CGPoint(x: tail.base.x + (tail.tip.x - tail.base.x) * f,
                     y: tail.base.y + (tail.tip.y - tail.base.y) * f),
             max(2, size * k))
        }
    }
}
