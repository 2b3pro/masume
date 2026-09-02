import AppKit
import CoreGraphics
import AnnotationModel
import AnnotationRender

// Mouse-down helpers for CanvasNSView: element creation, crop grab, and the
// pen's Shift-click straight line. Split from CanvasView.swift for size.

extension CanvasNSView {
    /// Pen tool with Shift held: the first click sets an anchor, the second
    /// creates a straight two-point stroke from the anchor to the click and
    /// lets the end follow the pointer until mouse-up.
    func handlePenLineClick(at p: CGPoint) {
        guard let controller else { return }
        guard let anchor = penLineAnchor else {
            penLineAnchor = p
            controller.selection = nil
            drag = .none
            return
        }
        let line = PenElement(points: [anchor, p], color: controller.strokeColor,
                              width: controller.strokeWidth, opacity: controller.penOpacity)
        controller.document?.add(.pen(line))
        controller.selection = line.id
        penLineAnchor = nil
        drag = .lining(line.id, anchor: anchor)
    }

    /// Crop tool: grab a corner of an existing crop rect (drag resizes against
    /// the opposite corner), drag inside it to move it, or start a new rect.
    func handleCropMouseDown(at p: CGPoint, viewPoint: CGPoint, info: DisplayInfo) {
        if let crop = controller?.document?.crop, crop.width > 0, crop.height > 0 {
            let handles = crop.cornerHandles()
            for handle in handles {
                let v = info.modelToView(handle.position)
                if hypot(v.x - viewPoint.x, v.y - viewPoint.y) <= 8,
                   let anchor = handles.first(where: { $0.role == handle.role.opposite }) {
                    drag = .cropping(anchor: anchor.position)
                    return
                }
            }
            if crop.contains(p) {
                drag = .movingCrop(last: p)
                return
            }
        }
        controller?.document?.crop = CGRect(corner: p, p)
        drag = .cropping(anchor: p)
    }

    func createElement(tool: Tool, at p: CGPoint) {
        guard let controller else { return }
        let color = controller.strokeColor
        let width = controller.strokeWidth
        let zeroRect = CGRect(corner: p, p)
        let new: Annotation
        var role: HandleRole = .bottomRight
        switch tool {
        case .arrow:
            new = .arrow(SegmentElement(start: p, end: p, color: color, width: width)); role = .end
        case .line:
            new = .line(SegmentElement(start: p, end: p, color: color, width: width)); role = .end
        case .rectangle:
            new = .rectangle(ShapeElement(rect: zeroRect, color: color, width: width))
        case .ellipse:
            new = .ellipse(ShapeElement(rect: zeroRect, color: color, width: width))
        case .pen:
            // The drag appends points through moveHandle(.end).
            new = .pen(PenElement(points: [p], color: color, width: width, opacity: controller.penOpacity)); role = .end
        case .pixelate:
            new = .pixelate(RedactionElement(rect: zeroRect, amount: controller.pixelateAmount))
        case .stamp:
            // Stamps are placed at a default size at the click point; the
            // click-drag swings the tail so it points the way you drag. A
            // plain click keeps the default (down) direction.
            let canvasSize = controller.document?.canvasSize ?? DefaultSizeScale.referenceCanvasSize
            let stamp = StampElement(center: p, radius: StampElement.defaultRadius(forCanvasSize: canvasSize),
                                     kind: controller.stampKind, color: color)
            controller.document?.add(.stamp(stamp))
            controller.selection = stamp.id
            drag = .creating(stamp.id, .end)
            return
        default:
            return
        }
        controller.document?.add(new)
        controller.selection = new.id
        drag = .creating(new.id, role)
    }

    /// Moves a handle. Text wraps at its width, so its height is re-measured
    /// afterwards: a narrower box grows instead of clipping lines.
    static func moveHandle(_ element: inout Annotation, _ role: HandleRole, to p: CGPoint) {
        element.moveHandle(role, to: p)
        if case .text(var t) = element {
            t.size.height = Renderer.suggestedSize(for: t).height
            element = .text(t)
        }
    }

    func createText(at p: CGPoint) {
        guard let controller else { return }
        let canvasSize = controller.document?.canvasSize ?? DefaultSizeScale.referenceCanvasSize
        let element = TextElement(origin: p,
                                  size: CGSize(width: DefaultInitialSize.textWidth(forCanvasSize: canvasSize), height: 44),
                                  string: "",
                                  font: FontSpec(pointSize: FontSpec.suggestedPointSize(forStrokeWidth: controller.strokeWidth)),
                                  color: controller.strokeColor,
                                  style: controller.textStyle,
                                  outlineColor: controller.textOutlineColor)
        controller.document?.add(.text(element))
        controller.selection = element.id
        drag = .none
        refresh()
        beginTextEditing(for: element.id)
    }
}
