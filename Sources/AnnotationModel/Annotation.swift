import Foundation
import CoreGraphics

/// A single annotation, discriminated by kind. Value type → cheap snapshots
/// for undo, free Codable/Equatable.
public enum Annotation: Codable, Equatable, Sendable, Identifiable {
    case arrow(SegmentElement)
    case line(SegmentElement)
    case rectangle(ShapeElement)
    case ellipse(ShapeElement)
    case pen(PenElement)
    case text(TextElement)
    case stamp(StampElement)
    case pixelate(RedactionElement)

    public var id: ElementID { geometry.id }

    /// Read-only access to the element's geometry behaviour.
    public var geometry: AnnotationGeometry {
        switch self {
        case .arrow(let e): return e
        case .line(let e): return e
        case .rectangle(let e): return e
        case .ellipse(let e): return e
        case .pen(let e): return e
        case .text(let e): return e
        case .stamp(let e): return e
        case .pixelate(let e): return e
        }
    }

    public func boundingBox() -> CGRect { geometry.boundingBox() }
    public func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool { geometry.hitTest(p, tolerance: tolerance) }
    public func handles() -> [Handle] { geometry.handles() }

    /// Stroke width of the wrapped element; nil for kinds without one
    /// (text, pixelate). Setting is a no-op for those kinds and for nil.
    public var strokeWidth: CGFloat? {
        get {
            switch self {
            case .arrow(let e), .line(let e): return e.width
            case .rectangle(let e), .ellipse(let e): return e.width
            case .pen(let e): return e.width
            case .text, .stamp, .pixelate: return nil
            }
        }
        set {
            guard let width = newValue else { return }
            switch self {
            case .arrow(var e): e.width = width; self = .arrow(e)
            case .line(var e): e.width = width; self = .line(e)
            case .rectangle(var e): e.width = width; self = .rectangle(e)
            case .ellipse(var e): e.width = width; self = .ellipse(e)
            case .pen(var e): e.width = width; self = .pen(e)
            case .text, .stamp, .pixelate: break
            }
        }
    }

    /// Opacity of a pen stroke; nil for other kinds. Setting is a no-op for
    /// those kinds and for nil.
    public var opacity: CGFloat? {
        get {
            guard case .pen(let e) = self else { return nil }
            return e.opacity
        }
        set {
            guard case .pen(var e) = self, let opacity = newValue else { return }
            e.opacity = opacity
            self = .pen(e)
        }
    }

    /// Stamp glyph of a stamp element; nil for other kinds. Setting is a
    /// no-op for those kinds and for nil.
    public var stampKind: StampKind? {
        get {
            guard case .stamp(let e) = self else { return nil }
            return e.kind
        }
        set {
            guard case .stamp(var e) = self, let kind = newValue else { return }
            e.kind = kind
            self = .stamp(e)
        }
    }

    /// Pixel block size of a pixelate element; nil for other kinds. Setting
    /// is a no-op for those kinds and for nil.
    public var pixelateAmount: CGFloat? {
        get {
            guard case .pixelate(let e) = self else { return nil }
            return e.amount
        }
        set {
            guard case .pixelate(var e) = self, let amount = newValue else { return }
            e.amount = amount
            self = .pixelate(e)
        }
    }

    /// Text style of a text element; nil for other kinds. Setting is a no-op
    /// for those kinds and for nil.
    public var textStyle: TextStyle? {
        get {
            guard case .text(let e) = self else { return nil }
            return e.style
        }
        set {
            guard case .text(var e) = self, let style = newValue else { return }
            e.style = style
            self = .text(e)
        }
    }

    /// Halo/outline color of a text element; nil for other kinds. Setting is
    /// a no-op for those kinds and for nil.
    public var textOutlineColor: RGBAColor? {
        get {
            guard case .text(let e) = self else { return nil }
            return e.outlineColor
        }
        set {
            guard case .text(var e) = self, let color = newValue else { return }
            e.outlineColor = color
            self = .text(e)
        }
    }

    /// Line alignment of a text element; nil for other kinds. Setting is a
    /// no-op for those kinds and for nil.
    public var textAlignment: TextAlignment? {
        get {
            guard case .text(let e) = self else { return nil }
            return e.alignment
        }
        set {
            guard case .text(var e) = self, let alignment = newValue else { return }
            e.alignment = alignment
            self = .text(e)
        }
    }

    /// Bubble shape of a callout; nil for plain text and other kinds.
    /// Setting changes an existing bubble's shape and is a no-op otherwise;
    /// wrapping plain text is `TextElement.makeCallout`.
    public var calloutShape: CalloutShape? {
        get {
            guard case .text(let e) = self else { return nil }
            return e.container?.shape
        }
        set {
            guard case .text(var e) = self, e.container != nil, let shape = newValue else { return }
            e.container?.shape = shape
            self = .text(e)
        }
    }

    /// True for a text element with a bubble.
    public var isCallout: Bool { calloutShape != nil }

    /// Color of the wrapped element; nil for kinds without one (pixelate).
    /// Setting is a no-op for those kinds and for nil.
    public var color: RGBAColor? {
        get {
            switch self {
            case .arrow(let e), .line(let e): return e.color
            case .rectangle(let e), .ellipse(let e): return e.color
            case .pen(let e): return e.color
            case .text(let e): return e.color
            case .stamp(let e): return e.color
            case .pixelate: return nil
            }
        }
        set {
            guard let color = newValue else { return }
            switch self {
            case .arrow(var e): e.color = color; self = .arrow(e)
            case .line(var e): e.color = color; self = .line(e)
            case .rectangle(var e): e.color = color; self = .rectangle(e)
            case .ellipse(var e): e.color = color; self = .ellipse(e)
            case .pen(var e): e.color = color; self = .pen(e)
            case .text(var e): e.color = color; self = .text(e)
            case .stamp(var e): e.color = color; self = .stamp(e)
            case .pixelate: break
            }
        }
    }

    /// Skitch-style placement: a plain click drops a degenerate (zero-size)
    /// element; give it a sensible default size anchored at the click point so
    /// the object appears without a drag. Non-degenerate (drag-created)
    /// elements and text (already placed at a default size) are unchanged.
    public func applyingDefaultInitialSize(canvasSize: CGSize) -> Annotation {
        switch self {
        case .arrow(let e):     return .arrow(Self.defaultSized(e, canvasSize: canvasSize))
        case .line(let e):      return .line(Self.defaultSized(e, canvasSize: canvasSize))
        case .rectangle(let e): return .rectangle(Self.defaultSized(e, canvasSize: canvasSize))
        case .ellipse(let e):   return .ellipse(Self.defaultSized(e, canvasSize: canvasSize))
        case .pixelate(let e):  return .pixelate(Self.defaultSized(e, canvasSize: canvasSize))
        case .text, .stamp:     return self   // already placed at a default size
        case .pen:              return self   // a plain click is a dot
        }
    }

    // Degeneracy is judged on raw geometry (not boundingBox, whose -width inset
    // would make a zero-length segment look non-degenerate).
    private static func defaultSized(_ e: SegmentElement, canvasSize: CGSize) -> SegmentElement {
        guard GeometryMath.distance(from: e.start, to: e.end) < DefaultInitialSize.degenerateThreshold else { return e }
        var e = e
        let vector = DefaultInitialSize.segment(forCanvasSize: canvasSize)
        e.end = CGPoint(x: e.start.x + vector.dx,
                        y: e.start.y + vector.dy)
        return e
    }

    private static func defaultSized<T: RectGeometry>(_ e: T, canvasSize: CGSize) -> T {
        guard max(e.rect.width, e.rect.height) < DefaultInitialSize.degenerateThreshold else { return e }
        var e = e
        e.rect = DefaultInitialSize.rect(centeredOn: e.rect.origin, canvasSize: canvasSize)
        return e
    }

    public mutating func moveHandle(_ role: HandleRole, to point: CGPoint) {
        mutate { $0.moveHandle(role, to: point) }
    }

    public mutating func translate(by delta: CGVector) {
        mutate { $0.translate(by: delta) }
    }

    /// Applies a mutation to the wrapped element while preserving its kind.
    private mutating func mutate(_ body: (inout AnnotationGeometry) -> Void) {
        switch self {
        case .arrow(var e): var g: AnnotationGeometry = e; body(&g); e = g as! SegmentElement; self = .arrow(e)
        case .line(var e): var g: AnnotationGeometry = e; body(&g); e = g as! SegmentElement; self = .line(e)
        case .rectangle(var e): var g: AnnotationGeometry = e; body(&g); e = g as! ShapeElement; self = .rectangle(e)
        case .ellipse(var e): var g: AnnotationGeometry = e; body(&g); e = g as! ShapeElement; self = .ellipse(e)
        case .pen(var e): var g: AnnotationGeometry = e; body(&g); e = g as! PenElement; self = .pen(e)
        case .text(var e): var g: AnnotationGeometry = e; body(&g); e = g as! TextElement; self = .text(e)
        case .stamp(var e): var g: AnnotationGeometry = e; body(&g); e = g as! StampElement; self = .stamp(e)
        case .pixelate(var e): var g: AnnotationGeometry = e; body(&g); e = g as! RedactionElement; self = .pixelate(e)
        }
    }
}
