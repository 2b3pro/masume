import Foundation
import CoreGraphics

/// The five Skitch stamp glyphs, two that carry a count (`number` shows
/// the stamp's ordinal as digits, `letter` as A, B, C then AA), and
/// `emoji`, which shows whatever character the user picked.
public enum StampKind: String, Codable, Equatable, Sendable, CaseIterable {
    case check, cross, exclaim, question, heart, number, letter, emoji

    /// Whether the stamp shows its `ordinal` rather than a fixed glyph.
    public var isOrdinal: Bool { self == .number || self == .letter }
}

/// A Skitch-style icon stamp: a colored disk with a white glyph and a
/// map-pin tail that can be swung around the disk to point at something.
/// Geometry is a center plus a radius; the tail direction is an angle in
/// model space (y-down, so `π/2` points down the image).
public struct StampElement: Codable, Equatable, Sendable, AnnotationGeometry {
    /// Default disk radius at the reference canvas size.
    public static let referenceRadius: CGFloat = 30
    public static let radiusRange: ClosedRange<CGFloat> = 8...300
    /// Tail tip distance from the center, in radii.
    public static let tailReach: CGFloat = 1.7
    /// Half-angle of the tail's base on the disk, in radians.
    public static let tailHalfAngle: CGFloat = .pi / 4
    /// Tail drags closer to the center than this many radii are ignored.
    public static let tailDeadZone: CGFloat = 0.25

    public static func defaultRadius(forCanvasSize size: CGSize) -> CGFloat {
        DefaultSizeScale.scaledDefault(reference: referenceRadius, clampedTo: radiusRange, forCanvasSize: size)
    }

    /// What a numbered or lettered stamp may count to.
    public static let ordinalRange = 1...999
    /// Shift-drag snaps the tail to multiples of this.
    public static let snapAngle: CGFloat = .pi / 4
    /// What an `emoji` stamp shows until the user picks one.
    public static let defaultEmoji = "\u{1F44D}"

    /// One character from what the user typed or pasted: the last grapheme
    /// cluster, so a flag or skin-toned emoji stays whole and typing a new
    /// emoji after the old one replaces it. Nil when there is none.
    public static func normalizedEmoji(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).last.map(String.init)
    }

    public var id: ElementID
    public var center: CGPoint
    public var radius: CGFloat
    public var kind: StampKind
    public var color: RGBAColor
    /// Tail direction in radians, model space (y-down). Defaults to pointing down.
    public var pointerAngle: CGFloat
    /// The count a `number` or `letter` stamp shows, from 1. Kept through
    /// kind changes so a stamp can switch between digits and letters.
    public var ordinal: Int
    /// What an `emoji` stamp shows: one grapheme cluster.
    public var emoji: String

    public init(id: ElementID = UUID(), center: CGPoint, radius: CGFloat = StampElement.referenceRadius,
                kind: StampKind = .check, color: RGBAColor = .red, pointerAngle: CGFloat = .pi / 2,
                ordinal: Int = 1, emoji: String = StampElement.defaultEmoji) {
        self.id = id; self.center = center; self.radius = radius
        self.kind = kind; self.color = color; self.pointerAngle = pointerAngle
        self.ordinal = ordinal; self.emoji = emoji
    }

    private enum CodingKeys: String, CodingKey { case id, center, radius, kind, color, pointerAngle, ordinal, emoji }

    /// `ordinal` is absent in projects saved before numbered stamps.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ElementID.self, forKey: .id)
        center = try c.decode(CGPoint.self, forKey: .center)
        radius = try c.decode(CGFloat.self, forKey: .radius)
        kind = try c.decode(StampKind.self, forKey: .kind)
        color = try c.decode(RGBAColor.self, forKey: .color)
        pointerAngle = try c.decode(CGFloat.self, forKey: .pointerAngle)
        ordinal = try c.decodeIfPresent(Int.self, forKey: .ordinal) ?? 1
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? Self.defaultEmoji
    }

    /// The text a `number`, `letter`, or `emoji` stamp shows; nil for the
    /// glyph stamps. Letters run A to Z then AA, like grid columns.
    public var label: String? {
        switch kind {
        case .number: return String(ordinal)
        case .letter: return GridCell.columnName(ordinal - 1)
        case .emoji: return emoji
        default: return nil
        }
    }

    /// Moves the count by `delta`, staying within `ordinalRange`.
    public mutating func step(by delta: Int) {
        ordinal = min(Self.ordinalRange.upperBound, max(Self.ordinalRange.lowerBound, ordinal + delta))
    }

    /// Aims the tail at `point`; with `snapping`, to the nearest 45°.
    public mutating func aimTail(at point: CGPoint, snapping: Bool) {
        guard GeometryMath.distance(from: point, to: center) >= Self.tailDeadZone * radius else { return }
        let angle = atan2(point.y - center.y, point.x - center.x)
        pointerAngle = snapping ? (angle / Self.snapAngle).rounded() * Self.snapAngle : angle
    }

    /// Where the tail ends.
    public var tailTip: CGPoint {
        CGPoint(x: center.x + cos(pointerAngle) * radius * Self.tailReach,
                y: center.y + sin(pointerAngle) * radius * Self.tailReach)
    }

    /// The disk's bounding square.
    public var diskRect: CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    /// Resize handle position: on the disk edge, upper-right in image terms.
    private var resizeHandlePosition: CGPoint {
        let a = -CGFloat.pi / 4
        return CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
    }

    public func boundingBox() -> CGRect {
        // The halo and shadow spill a little past the disk and tail.
        let margin = radius * 0.15
        return diskRect.union(CGRect(origin: tailTip, size: .zero)).insetBy(dx: -margin, dy: -margin)
    }

    public func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        if GeometryMath.distance(from: point, to: center) <= radius + tolerance { return true }
        return GeometryMath.distance(from: point, toSegment: center, tailTip) <= radius * 0.35 + tolerance
    }

    public func handles() -> [Handle] {
        [Handle(role: .end, position: tailTip),
         Handle(role: .topRight, position: resizeHandlePosition)]
    }

    public mutating func moveHandle(_ role: HandleRole, to point: CGPoint) {
        switch role {
        case .end:
            // Inside the dead zone the direction is noise: a plain click that
            // wobbles a pixel or two must not swing the tail.
            aimTail(at: point, snapping: false)
        case .topRight:
            radius = min(Self.radiusRange.upperBound,
                         max(Self.radiusRange.lowerBound, GeometryMath.distance(from: point, to: center)))
        default:
            break
        }
    }

    public mutating func translate(by delta: CGVector) {
        center.x += delta.dx; center.y += delta.dy
    }
}

extension Document {
    /// The count the next `number` or `letter` stamp gets: one past the
    /// highest of its kind, so a new stamp never repeats a label that is
    /// still on the canvas; 1 when there are none.
    public func nextStampOrdinal(for kind: StampKind) -> Int {
        let highest = elements.compactMap { element -> Int? in
            guard case .stamp(let e) = element, e.kind == kind else { return nil }
            return e.ordinal
        }.max() ?? 0
        return min(StampElement.ordinalRange.upperBound, highest + 1)
    }
}
