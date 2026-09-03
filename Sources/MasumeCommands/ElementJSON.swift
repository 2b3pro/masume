import Foundation
import CoreGraphics
import AnnotationModel
import AnnotationRender

// The agent-facing shape of an annotation: `{"id", "type", "bounds",
// "color", ...}` with points as {x, y} and colors as #RRGGBB. Not the
// Codable enum shape, which is a storage detail.

// MARK: - Colors

extension RGBAColor {
    public static let named: [String: RGBAColor] = [
        "red": .red, "orange": .orange, "yellow": .yellow, "green": .green,
        "blue": .blue, "pink": .pink, "white": .white, "black": .black,
    ]

    /// `#RRGGBB`, or `#RRGGBBAA` when not fully opaque.
    public var hex: String {
        func byte(_ v: Double) -> String { String(format: "%02X", Int((min(1, max(0, v)) * 255).rounded())) }
        let rgb = "#\(byte(r))\(byte(g))\(byte(b))"
        return a >= 0.999 ? rgb : rgb + byte(a)
    }

    /// A palette name or `#RGB`, `#RRGGBB`, `#RRGGBBAA`.
    public init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let named = Self.named[trimmed.lowercased()] { self = named; return }
        guard trimmed.hasPrefix("#") else { return nil }
        var digits = String(trimmed.dropFirst())
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let shift: (Int) -> Double = { Double((value >> UInt64($0)) & 0xFF) / 255 }
        self.init(r: shift(hasAlpha ? 24 : 16), g: shift(hasAlpha ? 16 : 8), b: shift(hasAlpha ? 8 : 0),
                  a: hasAlpha ? shift(0) : 1)
    }
}

// MARK: - Output

public enum ElementJSON {
    public static func typeName(_ a: Annotation) -> String {
        switch a {
        case .arrow: return "arrow"
        case .line: return "line"
        case .rectangle: return "rectangle"
        case .ellipse: return "ellipse"
        case .pen: return "pen"
        case .text(let t): return t.isCallout ? "callout" : "text"
        case .stamp: return "stamp"
        case .pixelate: return "pixelate"
        case .magnifier: return "magnifier"
        case .image: return "image"
        }
    }

    private static func stampFields(_ e: StampElement, into fields: inout [String: JSONValue]) {
        fields["center"] = .point(e.center); fields["radius"] = .number(e.radius)
        fields["kind"] = .string(e.kind.rawValue); fields["pointerAngle"] = .number(e.pointerAngle)
        fields["tailTip"] = .point(e.tailTip)
        if let label = e.label { fields["label"] = .string(label) }
        if e.kind.isOrdinal { fields["ordinal"] = .int(e.ordinal) }
        if e.kind == .emoji { fields["emoji"] = .string(e.emoji) }
    }

    public static func json(_ a: Annotation) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string(a.id.uuidString),
            "type": .string(typeName(a)),
            "bounds": .rect(a.boundingBox()),
        ]
        if let color = a.color { fields["color"] = .string(color.hex) }
        switch a {
        case .arrow(let e), .line(let e):
            fields["start"] = .point(e.start); fields["end"] = .point(e.end); fields["width"] = .number(e.width)
        case .rectangle(let e), .ellipse(let e):
            fields["rect"] = .rect(e.rect); fields["width"] = .number(e.width)
            fields["fill"] = .optional(e.fill.map { .string($0.hex) })
        case .pen(let e):
            fields["points"] = .array(e.points.map(JSONValue.point)); fields["width"] = .number(e.width)
            fields["opacity"] = .number(e.opacity)
        case .text(let t):
            textFields(t, into: &fields)
        case .stamp(let e):
            stampFields(e, into: &fields)
        case .pixelate(let e):
            fields["rect"] = .rect(e.rect); fields["amount"] = .number(e.amount)
        case .magnifier(let e):
            fields["rect"] = .rect(e.rect); fields["shape"] = .string(e.shape.rawValue)
            fields["zoom"] = .number(e.zoom); fields["width"] = .number(e.width)
        case .image(let e):
            fields["rect"] = .rect(e.rect); fields["assetId"] = .string(e.assetID.uuidString)
            fields["naturalSize"] = .size(e.naturalSize); fields["mask"] = .string(e.mask.rawValue)
            fields["borderWidth"] = .number(e.borderWidth); fields["shadow"] = .bool(e.shadow)
        }
        return .object(fields)
    }

    private static func textFields(_ t: TextElement, into fields: inout [String: JSONValue]) {
        fields["rect"] = .rect(t.rect)
        fields["text"] = .string(t.string)
        fields["fontSize"] = .number(t.font.pointSize)
        fields["bold"] = .bool(t.font.bold)
        fields["alignment"] = .string(t.alignment.rawValue)
        fields["style"] = .string(t.style.rawValue)
        fields["outlineColor"] = .string(t.outlineColor.hex)
        if let container = t.container {
            fields["shape"] = .string(container.shape.rawValue)
            fields["tailTip"] = .point(container.tailTip)
        }
    }
}

// MARK: - Input

/// Geometry and style for `create_element` and `update_element`. Pixel
/// geometry and grid addresses are both accepted; addresses resolve through
/// the document's grid at call time.
public struct ElementInput {
    public let params: Params
    public let document: Document

    public init(params: Params, document: Document) {
        self.params = params
        self.document = document
    }

    public var type: String? { try? params.optionalString("type") }

    // Geometry, pixels or grid.

    public func startPoint() throws -> CGPoint? { try params.optionalPoint("start") ?? (try cellCenter("from")) }
    public func endPoint() throws -> CGPoint? { try params.optionalPoint("end") ?? (try cellCenter("to")) }

    /// Both ends, for creation; nil when neither is given.
    public func segmentEnds() throws -> (start: CGPoint, end: CGPoint)? {
        let start = try startPoint()
        let end = try endPoint()
        switch (start, end) {
        case (nil, nil): return nil
        case (let s?, let e?): return (s, e)
        default: throw CommandError.invalidArgument("both ends are required: start/end points or from/to cells")
        }
    }

    public func box() throws -> CGRect? {
        if let rect = try params.optionalRect("rect") { return rect }
        if let over = try params.optionalString("over") { return try resolve(over).rect }
        if let at = try params.optionalString("at") { return try resolve(at).rect }
        return nil
    }

    public func centerPoint() throws -> CGPoint? {
        try params.optionalPoint("center") ?? (try cellCenter("at"))
    }

    public func tailTip() throws -> CGPoint? {
        try params.optionalPoint("tailTip") ?? (try cellCenter("tail"))
    }

    public func cellCenter(_ key: String) throws -> CGPoint? {
        guard let address = try params.optionalString(key) else { return nil }
        return try resolve(address).center
    }

    public func resolve(_ address: String) throws -> GridGeometry {
        do {
            return try document.grid.resolve(address, in: document.canvasSize)
        } catch {
            throw CommandError.wrap(error)
        }
    }

    // Style.

    public func color(_ key: String = "color") throws -> RGBAColor? {
        guard let text = try params.optionalString(key) else { return nil }
        guard let color = RGBAColor(text: text) else {
            throw CommandError.invalidArgument("\(key) must be a palette name or #RRGGBB, not \(text)")
        }
        return color
    }

    public func width() throws -> CGFloat? { try params.optionalDouble("width").map { CGFloat($0) } }

    public func enumValue<T: RawRepresentable>(_ key: String, _ type: T.Type) throws -> T? where T.RawValue == String {
        guard let raw = try params.optionalString(key) else { return nil }
        guard let value = T(rawValue: raw.lowercased()) else {
            throw CommandError.invalidArgument("\(key) cannot be \(raw)")
        }
        return value
    }
}

// MARK: - Factory

/// Builds and updates annotations from `ElementInput`. Defaults match what
/// the palette would give a new element on this canvas.
public enum ElementFactory {
    public static func make(_ input: ElementInput) throws -> Annotation {
        guard let type = input.type else { throw CommandError.invalidArgument("type is required") }
        switch type {
        case "arrow", "line": return try makeSegment(input, arrow: type == "arrow")
        case "rectangle", "ellipse": return try makeShape(input, rectangle: type == "rectangle")
        case "pen": return try makePen(input)
        case "text", "callout": return .text(try makeText(input, callout: type == "callout"))
        case "stamp": return try makeStamp(input)
        case "pixelate": return try makePixelate(input)
        case "magnifier": return try makeMagnifier(input)
        case "image": return try makeImage(input)
        default: throw CommandError.unsupported("unknown element type \(type)")
        }
    }

    private static func defaultWidth(_ reference: CGFloat, _ input: ElementInput) throws -> CGFloat {
        try input.width() ?? DefaultStrokeWidth.width(reference: reference, forCanvasSize: input.document.canvasSize)
    }

    private static func makeSegment(_ input: ElementInput, arrow: Bool) throws -> Annotation {
        guard let ends = try input.segmentEnds() else {
            throw CommandError.invalidArgument("\(arrow ? "arrow" : "line") needs start/end points or from/to cells")
        }
        let segment = SegmentElement(start: ends.start, end: ends.end, color: try input.color() ?? .red,
                                     width: try defaultWidth(DefaultStrokeWidth.segmentReferenceWidth, input))
        return arrow ? .arrow(segment) : .line(segment)
    }

    private static func makeShape(_ input: ElementInput, rectangle: Bool) throws -> Annotation {
        guard let rect = try input.box() else {
            throw CommandError.invalidArgument("\(rectangle ? "rectangle" : "ellipse") needs rect or over")
        }
        let shape = ShapeElement(rect: rect, color: try input.color() ?? .red,
                                 width: try defaultWidth(DefaultStrokeWidth.shapeReferenceWidth, input),
                                 fill: try input.color("fill"))
        return rectangle ? .rectangle(shape) : .ellipse(shape)
    }

    private static func makePen(_ input: ElementInput) throws -> Annotation {
        guard let points = try input.params.optionalPoints("points"), !points.isEmpty else {
            throw CommandError.invalidArgument("pen needs points")
        }
        return .pen(PenElement(points: points, color: try input.color() ?? .red,
                               width: try defaultWidth(DefaultStrokeWidth.penReferenceWidth, input),
                               opacity: CGFloat(try input.params.optionalDouble("opacity") ?? 1)))
    }

    private static func makeStamp(_ input: ElementInput) throws -> Annotation {
        guard let center = try input.centerPoint() else { throw CommandError.invalidArgument("stamp needs center or at") }
        let radius = try input.params.optionalDouble("radius").map { CGFloat($0) }
            ?? StampElement.defaultRadius(forCanvasSize: input.document.canvasSize)
        let kind = try input.enumValue("kind", StampKind.self) ?? .check
        var stamp = StampElement(center: center, radius: radius, kind: kind, color: try input.color() ?? .red,
                                 ordinal: try ordinal(input) ?? input.document.nextStampOrdinal(for: kind),
                                 emoji: try emoji(input) ?? StampElement.defaultEmoji)
        if let angle = try input.params.optionalDouble("pointerAngle") { stamp.pointerAngle = CGFloat(angle) }
        return .stamp(stamp)
    }

    /// `emoji`, the character an emoji stamp shows; one grapheme cluster.
    private static func emoji(_ input: ElementInput) throws -> String? {
        guard let text = try input.params.optionalString("emoji") else { return nil }
        guard let emoji = StampElement.normalizedEmoji(text), emoji == text else {
            throw CommandError.invalidArgument("emoji must be a single character")
        }
        return emoji
    }

    /// `ordinal`, the count a numbered or lettered stamp shows, 1 to 999.
    private static func ordinal(_ input: ElementInput) throws -> Int? {
        guard let value = try input.params.optionalInt("ordinal") else { return nil }
        guard StampElement.ordinalRange.contains(value) else {
            throw CommandError.invalidArgument("ordinal must be \(StampElement.ordinalRange.lowerBound) to \(StampElement.ordinalRange.upperBound)")
        }
        return value
    }

    private static func makePixelate(_ input: ElementInput) throws -> Annotation {
        guard let rect = try input.box() else { throw CommandError.invalidArgument("pixelate needs rect or over") }
        let amount = try input.params.optionalDouble("amount").map { CGFloat($0) }
            ?? RedactionElement.defaultAmount(forCanvasSize: input.document.canvasSize)
        return .pixelate(RedactionElement(rect: rect, amount: amount))
    }

    private static func makeMagnifier(_ input: ElementInput) throws -> Annotation {
        guard let rect = try input.box() else { throw CommandError.invalidArgument("magnifier needs rect or over") }
        return .magnifier(MagnifierElement(rect: rect, shape: try input.enumValue("shape", MagnifierShape.self) ?? .circle,
                                           zoom: CGFloat(try input.params.optionalDouble("zoom") ?? MagnifierElement.defaultZoom),
                                           color: try input.color() ?? .red,
                                           width: try defaultWidth(DefaultStrokeWidth.shapeReferenceWidth, input)))
    }

    /// An image layer. The command service registers the asset first and
    /// passes `assetId` and `naturalSize`; a caller cannot invent them.
    private static func makeImage(_ input: ElementInput) throws -> Annotation {
        guard let id = try input.params.optionalString("assetId"), let assetID = UUID(uuidString: id),
              let natural = try input.params.optionalObject("naturalSize") else {
            throw CommandError.invalidArgument("image needs imagePath (the service turns it into assetId and naturalSize)")
        }
        let naturalSize = CGSize(width: try natural.double("width"), height: try natural.double("height"))
        let rect = try input.box() ?? ImageElement.placement(naturalSize: naturalSize, in: input.document.canvasSize)
        return .image(ImageElement(rect: rect, assetID: assetID, naturalSize: naturalSize,
                                   mask: try input.enumValue("mask", ImageMask.self) ?? .rectangle,
                                   borderColor: try input.color() ?? .white,
                                   borderWidth: try input.width() ?? 0,
                                   shadow: try input.params.optionalBool("shadow") ?? true))
    }

    private static func makeText(_ input: ElementInput, callout: Bool) throws -> TextElement {
        let canvas = input.document.canvasSize
        let box = try input.box()
        let origin = try box?.origin ?? input.centerPoint() ?? CGPoint(x: canvas.width * 0.1, y: canvas.height * 0.1)
        var text = TextElement(origin: origin,
                               size: CGSize(width: box?.width ?? DefaultInitialSize.textWidth(forCanvasSize: canvas), height: 0),
                               string: try input.params.optionalString("text") ?? "",
                               font: FontSpec(pointSize: try input.params.optionalDouble("fontSize") ?? 28,
                                              bold: try input.params.optionalBool("bold") ?? true),
                               color: try input.color() ?? .red,
                               style: try input.enumValue("style", TextStyle.self) ?? (callout ? .plain : .shadow),
                               outlineColor: try input.color("outlineColor") ?? .white,
                               alignment: try input.enumValue("alignment", LineAlignment.self) ?? (callout ? .center : .left))
        if callout {
            text.container = TextContainer(shape: try input.enumValue("shape", CalloutShape.self) ?? .speech,
                                           tailTip: try input.tailTip() ?? CGPoint(x: origin.x, y: origin.y + 80))
            text.size.width += 2 * text.padding
        }
        text.size.height = Renderer.suggestedSize(for: text).height
        return text
    }

    // MARK: Update

    /// Applies the provided keys of `input` to `element`; untouched keys keep
    /// their values. Geometry keys follow the element's kind.
    public static func apply(_ input: ElementInput, to element: inout Annotation) throws {
        try applyCommon(input, to: &element)
        switch element {
        case .arrow(var e): try applySegment(input, to: &e); element = .arrow(e)
        case .line(var e): try applySegment(input, to: &e); element = .line(e)
        case .rectangle(var e): try applyShape(input, to: &e); element = .rectangle(e)
        case .ellipse(var e): try applyShape(input, to: &e); element = .ellipse(e)
        case .pen(var e): try applyPen(input, to: &e); element = .pen(e)
        case .text(var t): try applyText(input, to: &t); element = .text(t)
        case .stamp(var e): try applyStamp(input, to: &e); element = .stamp(e)
        case .pixelate(var e): try applyPixelate(input, to: &e); element = .pixelate(e)
        case .magnifier(var e): try applyMagnifier(input, to: &e); element = .magnifier(e)
        case .image(var e): try applyImage(input, to: &e); element = .image(e)
        }
    }

    private static func applyImage(_ input: ElementInput, to e: inout ImageElement) throws {
        if let rect = try input.box() { e.rect = rect }
        if let mask = try input.enumValue("mask", ImageMask.self) { e.mask = mask }
        if let shadow = try input.params.optionalBool("shadow") { e.shadow = shadow }
    }

    private static func applyCommon(_ input: ElementInput, to element: inout Annotation) throws {
        if let color = try input.color() { element.color = color }
        if let width = try input.width() { element.strokeWidth = width }
    }

    /// Either end may change on its own.
    private static func applySegment(_ input: ElementInput, to e: inout SegmentElement) throws {
        if let start = try input.startPoint() { e.start = start }
        if let end = try input.endPoint() { e.end = end }
    }

    private static func applyShape(_ input: ElementInput, to e: inout ShapeElement) throws {
        if let rect = try input.box() { e.rect = rect }
        if input.params.has("fill") { e.fill = try input.color("fill") }
    }

    private static func applyPen(_ input: ElementInput, to e: inout PenElement) throws {
        if let points = try input.params.optionalPoints("points") { e.points = points }
        if let opacity = try input.params.optionalDouble("opacity") { e.opacity = CGFloat(opacity) }
    }

    private static func applyStamp(_ input: ElementInput, to e: inout StampElement) throws {
        if let center = try input.centerPoint() { e.center = center }
        if let radius = try input.params.optionalDouble("radius") { e.radius = CGFloat(radius) }
        if let kind = try input.enumValue("kind", StampKind.self) { e.kind = kind }
        if let angle = try input.params.optionalDouble("pointerAngle") { e.pointerAngle = CGFloat(angle) }
        if let ordinal = try ordinal(input) { e.ordinal = ordinal }
        if let emoji = try emoji(input) { e.emoji = emoji }
    }

    private static func applyPixelate(_ input: ElementInput, to e: inout RedactionElement) throws {
        if let rect = try input.box() { e.rect = rect }
        if let amount = try input.params.optionalDouble("amount") { e.amount = CGFloat(amount) }
    }

    private static func applyMagnifier(_ input: ElementInput, to e: inout MagnifierElement) throws {
        if let rect = try input.box() { e.rect = rect }
        if let shape = try input.enumValue("shape", MagnifierShape.self) { e.shape = shape }
        if let zoom = try input.params.optionalDouble("zoom") { e.zoom = CGFloat(zoom) }
    }

    private static func applyText(_ input: ElementInput, to t: inout TextElement) throws {
        if let box = try input.box() { t.origin = box.origin; t.size.width = box.width }
        if let string = try input.params.optionalString("text") { t.string = string }
        if let size = try input.params.optionalDouble("fontSize") { t.font.pointSize = size }
        if let bold = try input.params.optionalBool("bold") { t.font.bold = bold }
        try applyTextStyle(input, to: &t)
        t.size.height = Renderer.suggestedSize(for: t).height
    }

    private static func applyTextStyle(_ input: ElementInput, to t: inout TextElement) throws {
        if let style = try input.enumValue("style", TextStyle.self) { t.style = style }
        if let outline = try input.color("outlineColor") { t.outlineColor = outline }
        if let alignment = try input.enumValue("alignment", LineAlignment.self) { t.alignment = alignment }
        if let shape = try input.enumValue("shape", CalloutShape.self) { t.makeCallout(shape) }
        if let tip = try input.tailTip() {
            if t.container == nil { t.makeCallout(.speech) }
            t.container?.tailTip = tip
        }
    }
}
