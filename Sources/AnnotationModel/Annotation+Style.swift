import Foundation
import CoreGraphics

extension Annotation {
    /// Missing overrides preserve the appearance of older projects.
    public var shadowEnabled: Bool? {
        get {
            switch self {
            case .arrow(let e), .line(let e): return e.shadow ?? true
            case .rectangle(let e), .ellipse(let e): return e.shadow ?? (e.highlightOpacity == nil)
            case .text(let e): return e.shadow ?? (e.isCallout || e.style == .shadow)
            case .stamp(let e): return e.shadow ?? true
            case .image(let e): return e.shadow
            default: return nil
            }
        }
        set {
            switch self {
            case .arrow(var e): e.shadow = newValue; self = .arrow(e)
            case .line(var e): e.shadow = newValue; self = .line(e)
            case .rectangle(var e): e.shadow = newValue; self = .rectangle(e)
            case .ellipse(var e): e.shadow = newValue; self = .ellipse(e)
            case .text(var e): e.shadow = newValue; self = .text(e)
            case .stamp(var e): e.shadow = newValue; self = .stamp(e)
            case .image(var e): e.shadow = newValue ?? true; self = .image(e)
            default: break
            }
        }
    }

    public var rectangleCornerRadius: CGFloat? {
        get {
            guard case .rectangle(let e) = self else { return nil }
            return e.cornerRadius ?? 0
        }
        set {
            guard case .rectangle(var e) = self else { return }
            e.cornerRadius = newValue
            self = .rectangle(e)
        }
    }
}
