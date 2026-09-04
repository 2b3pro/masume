import Foundation
import CoreGraphics

public enum ExportBounds: String, Codable, CaseIterable, Sendable {
    case expandToFit
    case clipToImage
}

/// The annotation document: a base image plus an ordered list of annotations
/// (draw order == array order) and an optional crop rect, all in image pixel
/// space.
public struct Document: Codable, Equatable, Sendable {
    public var baseImage: ImageRef
    public var canvasSize: CGSize
    public var elements: [Annotation]
    public var crop: CGRect?
    /// The address grid over the base image. Defaults from the canvas size
    /// alone; stored so it never drifts. Changing it is a document action.
    public var grid: GridDefinition
    public var textPreferences: TextPreferences

    public init(baseImage: ImageRef, canvasSize: CGSize,
                elements: [Annotation] = [], crop: CGRect? = nil, grid: GridDefinition? = nil,
                textPreferences: TextPreferences = TextPreferences()) {
        self.baseImage = baseImage
        self.canvasSize = canvasSize
        self.elements = elements
        self.crop = crop
        self.grid = grid ?? .default(for: canvasSize)
        self.textPreferences = textPreferences
    }

    /// A document encoded before grids existed gets the default for its size.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseImage = try c.decode(ImageRef.self, forKey: .baseImage)
        canvasSize = try c.decode(CGSize.self, forKey: .canvasSize)
        elements = try c.decode([Annotation].self, forKey: .elements)
        crop = try c.decodeIfPresent(CGRect.self, forKey: .crop)
        grid = try c.decodeIfPresent(GridDefinition.self, forKey: .grid) ?? .default(for: canvasSize)
        textPreferences = try c.decodeIfPresent(TextPreferences.self, forKey: .textPreferences) ?? TextPreferences()
    }

    /// Output bounds after crop (defaults to the full canvas).
    public var outputRect: CGRect {
        crop ?? CGRect(origin: .zero, size: canvasSize)
    }

    public func expandedOutputRect() -> CGRect {
        let base = outputRect
        guard !elements.isEmpty else { return base }
        var union = base
        for element in elements {
            union = union.union(element.boundingBox())
        }
        return union.integral
    }

    public func outputRect(for bounds: ExportBounds) -> CGRect {
        switch bounds {
        case .clipToImage: return outputRect
        case .expandToFit: return expandedOutputRect()
        }
    }

    // MARK: Element lookup / mutation helpers

    public func index(of id: ElementID) -> Int? {
        elements.firstIndex { $0.id == id }
    }

    /// Topmost element hit at `point` (search front-to-back).
    public func hitTest(_ point: CGPoint, tolerance: CGFloat) -> ElementID? {
        for element in elements.reversed() where element.hitTest(point, tolerance: tolerance) {
            return element.id
        }
        return nil
    }

    /// Mutates the element with `id` in place; no-op when absent.
    public mutating func mutate(_ id: ElementID, _ body: (inout Annotation) -> Void) {
        if let i = index(of: id) { body(&elements[i]) }
    }

    /// `rect` constrained to the canvas, or nil when the result is degenerate
    /// (thinner than 2pt either way) — the single source of crop validity.
    public func clampedCrop(_ rect: CGRect) -> CGRect? {
        let clamped = rect.intersection(CGRect(origin: .zero, size: canvasSize))
        guard !clamped.isNull, clamped.width >= 2, clamped.height >= 2 else { return nil }
        return clamped
    }

    /// The pending crop clamped to the canvas and snapped to whole pixels,
    /// or nil when there is no crop or it is degenerate.
    public var integralCrop: CGRect? {
        crop.flatMap { clampedCrop($0)?.integral }
    }

    public var canvasRect: CGRect { CGRect(origin: .zero, size: canvasSize) }

    /// `rect` as a frame for the image: it may reach outside the canvas
    /// (that part becomes new white canvas) but must keep some of the image
    /// and have area; nil otherwise.
    public func framedRect(_ rect: CGRect) -> CGRect? {
        let rect = rect.standardized
        guard rect.width >= 2, rect.height >= 2, rect.intersects(canvasRect) else { return nil }
        return rect
    }

    /// The pending frame snapped to whole pixels, or nil when there is none
    /// or it keeps none of the image.
    public var integralFrame: CGRect? {
        crop.flatMap { framedRect($0)?.integral }
    }

    public mutating func add(_ element: Annotation) {
        elements.append(element)
    }

    public mutating func remove(_ id: ElementID) {
        if let i = index(of: id) { elements.remove(at: i) }
    }

    public mutating func bringToFront(_ id: ElementID) {
        guard let i = index(of: id) else { return }
        let e = elements.remove(at: i)
        elements.append(e)
    }
}
