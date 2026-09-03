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
    case magnifier(MagnifierElement)
    case image(ImageElement)

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
        case .magnifier(let e): return e
        case .image(let e): return e
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
            case .magnifier(let e): return e.width
            case .image(let e): return e.borderWidth
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
            case .magnifier(var e): e.width = width; self = .magnifier(e)
            case .image(var e): e.borderWidth = width; self = .image(e)
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
    public var textAlignment: LineAlignment? {
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

    /// Mask of an image layer; nil for other kinds. Setting is a no-op for
    /// those kinds and for nil.
    public var imageMask: ImageMask? {
        get {
            guard case .image(let e) = self else { return nil }
            return e.mask
        }
        set {
            guard case .image(var e) = self, let mask = newValue else { return }
            e.mask = mask
            self = .image(e)
        }
    }

    /// Whether an image layer casts a shadow; nil for other kinds.
    public var imageShadow: Bool? {
        get {
            guard case .image(let e) = self else { return nil }
            return e.shadow
        }
        set {
            guard case .image(var e) = self, let shadow = newValue else { return }
            e.shadow = shadow
            self = .image(e)
        }
    }

    /// Zoom factor of a magnifier; nil for other kinds. Setting clamps to
    /// `MagnifierElement.zoomRange` and is a no-op for other kinds and nil.
    public var magnifierZoom: CGFloat? {
        get {
            guard case .magnifier(let e) = self else { return nil }
            return e.zoom
        }
        set {
            guard case .magnifier(var e) = self, let zoom = newValue else { return }
            e.zoom = zoom
            self = .magnifier(e)
        }
    }

    /// Outline shape of a magnifier; nil for other kinds. Setting is a no-op
    /// for those kinds and for nil.
    public var magnifierShape: MagnifierShape? {
        get {
            guard case .magnifier(let e) = self else { return nil }
            return e.shape
        }
        set {
            guard case .magnifier(var e) = self, let shape = newValue else { return }
            e.shape = shape
            self = .magnifier(e)
        }
    }

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
            case .magnifier(let e): return e.color
            case .image(let e): return e.borderColor
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
            case .magnifier(var e): e.color = color; self = .magnifier(e)
            case .image(var e): e.borderColor = color; self = .image(e)
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
        case .magnifier(let e): return .magnifier(Self.defaultSizedMagnifier(e, canvasSize: canvasSize))
        case .text, .stamp, .image: return self   // already placed at a default size
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

    /// A clicked loupe becomes a default-size square centered on the click.
    private static func defaultSizedMagnifier(_ e: MagnifierElement, canvasSize: CGSize) -> MagnifierElement {
        guard max(e.rect.width, e.rect.height) < DefaultInitialSize.degenerateThreshold else { return e }
        var e = e
        e.rect = DefaultInitialSize.magnifierRect(centeredOn: e.center, canvasSize: canvasSize)
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

    /// A copy of this annotation under a new identity: same kind, geometry,
    /// and style (an image copy shares its asset). What Option-drag and a
    /// Duplicate command hand out.
    public func duplicated(id newID: ElementID = UUID()) -> Annotation {
        switch self {
        case .arrow(var e): e.id = newID; return .arrow(e)
        case .line(var e): e.id = newID; return .line(e)
        case .rectangle(var e): e.id = newID; return .rectangle(e)
        case .ellipse(var e): e.id = newID; return .ellipse(e)
        case .pen(var e): e.id = newID; return .pen(e)
        case .text(var e): e.id = newID; return .text(e)
        case .stamp(var e): e.id = newID; return .stamp(e)
        case .pixelate(var e): e.id = newID; return .pixelate(e)
        case .magnifier(var e): e.id = newID; return .magnifier(e)
        case .image(var e): e.id = newID; return .image(e)
        }
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
        case .magnifier(var e): var g: AnnotationGeometry = e; body(&g); e = g as! MagnifierElement; self = .magnifier(e)
        case .image(var e): var g: AnnotationGeometry = e; body(&g); e = g as! ImageElement; self = .image(e)
        }
    }
}
