import Foundation
import CoreGraphics

/// The spreadsheet grid laid over the base image: how many columns and rows,
/// and a version that changes whenever the counts do, so anything keyed to
/// cell addresses (a semantic map, a cached crop) knows it is stale.
///
/// Counts are stored, never recomputed on open, so addresses never drift
/// after reopening or after the default tiers change in a later release.
public struct GridDefinition: Codable, Equatable, Hashable, Sendable {
    public static let countRange = 2...64
    /// The density presets a user may choose; also the tier values.
    public static let presets = [8, 12, 16, 24, 32]

    public var columns: Int
    public var rows: Int
    public var version: Int

    public init(columns: Int, rows: Int, version: Int = 1) {
        self.columns = min(Self.countRange.upperBound, max(Self.countRange.lowerBound, columns))
        self.rows = min(Self.countRange.upperBound, max(Self.countRange.lowerBound, rows))
        self.version = version
    }

    /// Cells across the long side for an image of this long side, in pixels.
    public static func tier(forLongSide longSide: CGFloat) -> Int {
        switch longSide {
        case ...800: return 8
        case ...1600: return 12
        case ...2600: return 16
        case ...4000: return 24
        default: return 32
        }
    }

    /// The default grid for an image, from its pixel size alone: the tier
    /// picks cells across the long side, and both counts follow from the
    /// near-square cell that gives, so the grid covers the image exactly.
    public static func `default`(for canvasSize: CGSize) -> GridDefinition {
        derive(cellsAcrossLongSide: tier(forLongSide: max(canvasSize.width, canvasSize.height)), for: canvasSize)
    }

    /// A chosen preset (8, 12, 16, 24, or 32 cells across the long side)
    /// derived the same way as the default.
    public static func preset(_ n: Int, for canvasSize: CGSize, version: Int = 1) -> GridDefinition {
        derive(cellsAcrossLongSide: n, for: canvasSize, version: version)
    }

    /// `target = long / n; cols = clamp(round(W / target)); rows = clamp(round(H / target))`.
    /// `rounded()` is half-away-from-zero, so 1440×900 at 12 gives 12×8 on
    /// every platform (900 / 120 = 7.5 rounds up).
    static func derive(cellsAcrossLongSide n: Int, for canvasSize: CGSize, version: Int = 1) -> GridDefinition {
        let long = max(canvasSize.width, canvasSize.height)
        guard long > 0, n > 0 else { return GridDefinition(columns: 2, rows: 2, version: version) }
        let target = long / CGFloat(n)
        return GridDefinition(columns: Int((canvasSize.width / target).rounded()),
                              rows: Int((canvasSize.height / target).rounded()),
                              version: version)
    }

    /// The preset this grid was derived from, when it matches one exactly.
    public func matchingPreset(for canvasSize: CGSize) -> Int? {
        Self.presets.first { Self.derive(cellsAcrossLongSide: $0, for: canvasSize, version: version) == self }
    }
}
