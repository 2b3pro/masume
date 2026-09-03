import Foundation
import CoreGraphics

/// Identifies an editable control point on an element.
public enum HandleRole: Codable, Equatable, Hashable, Sendable {
    case move          // body drag (whole-element translate)
    case start         // vector start point
    case end           // vector end point
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case left          // mid-left edge (text width, frame edge)
    case right         // mid-right edge (text width, frame edge)
    case top           // mid-top edge (frame edge)
    case bottom        // mid-bottom edge (frame edge)

    /// The diagonally opposite corner, or the facing edge: the anchor when
    /// resizing by this handle. Nil for the point roles.
    public var opposite: HandleRole? {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        case .move, .start, .end: return nil
        }
    }
}

public struct Handle: Equatable, Sendable {
    public let role: HandleRole
    public let position: CGPoint

    public init(role: HandleRole, position: CGPoint) {
        self.role = role
        self.position = position
    }
}

/// Shared geometric behaviour every element implements. Kept pure so it is
/// unit-testable without any UI framework.
public protocol AnnotationGeometry {
    var id: ElementID { get }
    func boundingBox() -> CGRect
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool
    func handles() -> [Handle]
    mutating func moveHandle(_ role: HandleRole, to point: CGPoint)
    mutating func translate(by delta: CGVector)
}

/// A rect-backed element. Conformers get corner handles, opposite-corner
/// resizing, translation, and an inset-contains hit test for free.
public protocol RectGeometry: AnnotationGeometry {
    var rect: CGRect { get set }
}

public extension RectGeometry {
    func boundingBox() -> CGRect { rect }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    func handles() -> [Handle] { rect.cornerHandles() }

    mutating func moveHandle(_ role: HandleRole, to point: CGPoint) {
        rect = rect.movingCorner(role, to: point)
    }

    mutating func translate(by delta: CGVector) {
        rect = rect.offsetBy(dx: delta.dx, dy: delta.dy)
    }
}

extension CGRect {
    public func cornerHandles() -> [Handle] {
        let c = corners
        return [
            Handle(role: .topLeft, position: c.topLeft),
            Handle(role: .topRight, position: c.topRight),
            Handle(role: .bottomLeft, position: c.bottomLeft),
            Handle(role: .bottomRight, position: c.bottomRight),
        ]
    }

    /// Midpoint handles of the four edges (y-down: top is `minY`).
    public func edgeHandles() -> [Handle] {
        [
            Handle(role: .top, position: CGPoint(x: midX, y: minY)),
            Handle(role: .right, position: CGPoint(x: maxX, y: midY)),
            Handle(role: .bottom, position: CGPoint(x: midX, y: maxY)),
            Handle(role: .left, position: CGPoint(x: minX, y: midY)),
        ]
    }

    /// Corners and edge midpoints: what a frame being resized shows.
    public func frameHandles() -> [Handle] { cornerHandles() + edgeHandles() }

    /// Returns a copy of this rect with the given corner moved to `point`.
    public func movingCorner(_ role: HandleRole, to point: CGPoint) -> CGRect {
        let c = corners
        switch role {
        case .topLeft:     return CGRect(corner: point, c.bottomRight)
        case .topRight:    return CGRect(corner: point, c.bottomLeft)
        case .bottomLeft:  return CGRect(corner: point, c.topRight)
        case .bottomRight: return CGRect(corner: point, c.topLeft)
        default:           return self
        }
    }

    /// A corner moved to `point`, or one edge moved to `point`'s coordinate
    /// on its axis; the rect stays normalized when a side crosses over.
    public func movingHandle(_ role: HandleRole, to point: CGPoint) -> CGRect {
        switch role {
        case .top:    return CGRect(corner: CGPoint(x: minX, y: point.y), CGPoint(x: maxX, y: maxY))
        case .bottom: return CGRect(corner: CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: point.y))
        case .left:   return CGRect(corner: CGPoint(x: point.x, y: minY), CGPoint(x: maxX, y: maxY))
        case .right:  return CGRect(corner: CGPoint(x: minX, y: minY), CGPoint(x: point.x, y: maxY))
        default:      return movingCorner(role, to: point)
        }
    }
}
