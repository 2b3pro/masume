import AppKit
import CoreGraphics
import AnnotationModel
import AnnotationRender

// Mouse helpers for CanvasNSView: element creation, crop grab, the pen's
// Shift-click straight line, and the per-drag update and finish steps.
// Split from CanvasView.swift for size.

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
        case .magnifier:
            // The click is the loupe's center; the drag grows it around that
            // point (moveHandle(.end)). A plain click gets the default size.
            new = .magnifier(MagnifierElement(rect: zeroRect, shape: controller.magnifierShape,
                                              zoom: controller.magnifierZoom, color: color, width: width))
            role = .end
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

    /// Callout tool: the mouse-down point is the tail tip. The bubble starts
    /// above and to the right of it and follows the pointer while dragging
    /// (`Drag.placingCallout`); mouse-up opens the inline editor.
    func createCallout(at tip: CGPoint) {
        guard let controller else { return }
        let canvasSize = controller.document?.canvasSize ?? DefaultSizeScale.referenceCanvasSize
        var element = TextElement(origin: .zero,
                                  size: CGSize(width: DefaultInitialSize.textWidth(forCanvasSize: canvasSize), height: 0),
                                  string: "",
                                  font: FontSpec(pointSize: FontSpec.suggestedPointSize(forStrokeWidth: controller.strokeWidth)),
                                  color: controller.strokeColor,
                                  style: .plain,
                                  outlineColor: controller.textOutlineColor,
                                  alignment: .center,
                                  container: TextContainer(shape: controller.calloutShape, tailTip: tip))
        element.size.width += 2 * element.padding
        element.size.height = Renderer.suggestedSize(for: element).height
        let offset = DefaultInitialSize.calloutOffset(forCanvasSize: canvasSize)
        element.origin = CGPoint(x: tip.x + offset.dx, y: tip.y - offset.dy - element.size.height)
        controller.document?.add(.text(element))
        controller.selection = element.id
        drag = .placingCallout(element.id)
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

// MARK: - Drag updates and finish

extension CanvasNSView {
    /// Applies a model-space drag (`p` in image coordinates): element moves
    /// and handles, crop edits, the pen's straight line, and callout placement.
    func dragModel(to p: CGPoint, controller: CanvasController) {
        switch drag {
        case .moving(let id, let last):
            let delta = CGVector(dx: p.x - last.x, dy: p.y - last.y)
            controller.document?.mutate(id) { $0.translate(by: delta) }
            drag = .moving(id, last: p)
        case .handle(let id, let role), .creating(let id, let role):
            controller.document?.mutate(id) { Self.moveHandle(&$0, role, to: p) }
        case .cropping(let anchor):
            controller.document?.crop = CGRect(corner: anchor, p)
        case .movingCrop(let last):
            if let crop = controller.document?.crop {
                controller.document?.crop = crop.offsetBy(dx: p.x - last.x, dy: p.y - last.y)
            }
            drag = .movingCrop(last: p)
        case .lining(let id, let anchor):
            controller.document?.mutate(id) { Self.setStraightLine(&$0, from: anchor, to: p) }
        case .placingCallout(let id):
            controller.document?.mutate(id) { Self.placeCallout(&$0, centeredAt: p) }
        case .none, .magnifierZoom, .panning:
            break
        }
    }

    /// Settles what a finished drag leaves behind, before it is committed: a
    /// plain click (no real drag) leaves a degenerate element and gets a
    /// default initial size, Skitch-style, rather than being dropped (drag-
    /// created elements keep their size; the helper is a no-op for them), and
    /// a crop rect is kept within the canvas with degenerate ones dropped.
    func finishDrag(_ finished: Drag, controller: CanvasController) {
        switch finished {
        case .creating(let id, _):
            guard let canvasSize = controller.document?.canvasSize else { return }
            controller.document?.mutate(id) { $0 = $0.applyingDefaultInitialSize(canvasSize: canvasSize) }
        case .cropping, .movingCrop:
            guard let doc = controller.document, let crop = doc.crop else { return }
            controller.document?.crop = doc.clampedCrop(crop)
        default:
            break
        }
    }

    private static func setStraightLine(_ element: inout Annotation, from anchor: CGPoint, to p: CGPoint) {
        guard case .pen(var line) = element else { return }
        line.points = [anchor, p]
        element = .pen(line)
    }

    private static func placeCallout(_ element: inout Annotation, centeredAt p: CGPoint) {
        guard case .text(var t) = element else { return }
        t.origin = CGPoint(x: p.x - t.size.width / 2, y: p.y - t.size.height / 2)
        element = .text(t)
    }
}
