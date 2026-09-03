import CoreGraphics
import AnnotationModel

/// Original vector stamp glyphs (drawn from scratch, no imported artwork),
/// laid out in a unit square in model space (y-down).
enum StampPaths {
    static func path(for kind: StampKind, in rect: CGRect) -> CGPath {
        let p = CGMutablePath()
        let w = rect.width, h = rect.height
        func pt(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + fx * w, y: rect.minY + fy * h)
        }
        switch kind {
        case .check:
            p.move(to: pt(0.12, 0.55))
            p.addLine(to: pt(0.40, 0.82))
            p.addLine(to: pt(0.88, 0.20))
            p.addLine(to: pt(0.78, 0.10))
            p.addLine(to: pt(0.40, 0.62))
            p.addLine(to: pt(0.22, 0.45))
            p.closeSubpath()
        case .cross:
            let t: CGFloat = 0.16
            p.move(to: pt(0.10, 0.10 + t))
            p.addLine(to: pt(0.10 + t, 0.10))
            p.addLine(to: pt(0.50, 0.50 - t))
            p.addLine(to: pt(0.90 - t, 0.10))
            p.addLine(to: pt(0.90, 0.10 + t))
            p.addLine(to: pt(0.50 + t, 0.50))
            p.addLine(to: pt(0.90, 0.90 - t))
            p.addLine(to: pt(0.90 - t, 0.90))
            p.addLine(to: pt(0.50, 0.50 + t))
            p.addLine(to: pt(0.10 + t, 0.90))
            p.addLine(to: pt(0.10, 0.90 - t))
            p.addLine(to: pt(0.50 - t, 0.50))
            p.closeSubpath()
        case .exclaim:
            p.addRoundedRect(in: CGRect(x: rect.minX + 0.40 * w, y: rect.minY + 0.08 * h,
                                        width: 0.20 * w, height: 0.56 * h),
                             cornerWidth: 0.10 * w, cornerHeight: 0.10 * w)
            p.addEllipse(in: CGRect(x: rect.minX + 0.38 * w, y: rect.minY + 0.74 * h,
                                    width: 0.24 * w, height: 0.18 * h))
        case .question:
            p.addPath(questionMark(in: rect))
        case .heart:
            p.move(to: pt(0.50, 0.90))
            p.addCurve(to: pt(0.02, 0.32), control1: pt(0.20, 0.70), control2: pt(0.02, 0.50))
            p.addArc(center: pt(0.26, 0.28), radius: 0.24 * w, startAngle: .pi, endAngle: 0, clockwise: false)
            p.addArc(center: pt(0.74, 0.28), radius: 0.24 * w, startAngle: .pi, endAngle: 0, clockwise: false)
            p.addCurve(to: pt(0.50, 0.90), control1: pt(0.98, 0.50), control2: pt(0.80, 0.70))
            p.closeSubpath()
        case .number, .letter, .emoji:
            break   // drawn as text by the renderer, not as a path
        }
        return p
    }

    /// Hook: an arc from the left, over the top, down the right side, then a
    /// short stem, plus the dot. The arc is sampled point by point so its
    /// direction is unambiguous under the y-down CTM.
    private static func questionMark(in rect: CGRect) -> CGPath {
        let w = rect.width, h = rect.height
        func pt(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + fx * w, y: rect.minY + fy * h)
        }
        let hook = CGMutablePath()
        let cx: CGFloat = 0.5, cy: CGFloat = 0.34, r: CGFloat = 0.2
        let steps = 24
        for i in 0...steps {
            let a = (200 + 250 * CGFloat(i) / CGFloat(steps)) * .pi / 180
            let point = pt(cx + r * cos(a), cy + r * sin(a))
            if i == 0 { hook.move(to: point) } else { hook.addLine(to: point) }
        }
        hook.addLine(to: pt(0.5, 0.66))
        let p = CGMutablePath()
        p.addPath(hook.copy(strokingWithWidth: 0.14 * w, lineCap: .round, lineJoin: .round, miterLimit: 10))
        p.addEllipse(in: CGRect(x: rect.minX + 0.40 * w, y: rect.minY + 0.76 * h,
                                width: 0.20 * w, height: 0.20 * h))
        return p
    }

    /// The pin silhouette: the disk plus a tail whose sides leave the disk
    /// tangentially and meet at the tip.
    static func pinPath(for e: StampElement) -> CGPath {
        let p = CGMutablePath()
        p.addEllipse(in: e.diskRect)
        let a = e.pointerAngle, half = StampElement.tailHalfAngle
        func onDisk(_ angle: CGFloat) -> CGPoint {
            CGPoint(x: e.center.x + cos(angle) * e.radius, y: e.center.y + sin(angle) * e.radius)
        }
        p.move(to: onDisk(a - half))
        p.addLine(to: e.tailTip)
        p.addLine(to: onDisk(a + half))
        p.closeSubpath()
        return p
    }
}
