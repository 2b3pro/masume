import Foundation
import CoreGraphics

public enum GridError: Error, Equatable, Sendable, LocalizedError {
    /// Not a cell or range at all.
    case malformed(String)
    /// A cell outside the grid; carries the address and the grid's size.
    case outOfRange(String, columns: Int, rows: Int)
    /// A range whose second cell is left of or above the first.
    case reversedRange(String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let s):
            return "\u{201C}\(s)\u{201D} is not a grid address. Use a cell like D5, a quadrant like D5.3 " +
                "(1 to 4 clockwise from the upper left, nesting as D5.3.1), or a range like D5:F14."
        case .outOfRange(let s, let columns, let rows):
            return "\u{201C}\(s)\u{201D} is outside the grid, which is \(GridCell.columnName(columns - 1))\(rows) at most."
        case .reversedRange(let s):
            return "\u{201C}\(s)\u{201D} is reversed; the first cell must be above and left of the second."
        }
    }
}

/// One cell, zero-based. `D5` is column 3, row 4. `quadrants` refines it:
/// `D5.3` is the cell's lower-right quarter (1 to 4 clockwise from the
/// upper left), and each further digit quarters again, so `D5.3.1` is the
/// upper-left quarter of that quarter. Empty means the whole cell.
public struct GridCell: Equatable, Hashable, Sendable {
    public var column: Int
    public var row: Int
    public var quadrants: [Int]

    /// Nesting stops here: a 160-pixel cell is 10 pixels at depth 4.
    public static let maxQuadrantDepth = 4

    public init(column: Int, row: Int, quadrants: [Int] = []) {
        self.column = column
        self.row = row
        self.quadrants = quadrants
    }

    /// The addressed area in cell units: the whole cell is
    /// `(column, row, 1, 1)`; each quadrant halves both sides. Exact in
    /// binary, so `D5.3` sits on the same edges however it is computed.
    public var unitRect: CGRect {
        var rect = CGRect(x: CGFloat(column), y: CGFloat(row), width: 1, height: 1)
        for q in quadrants {
            rect.size.width /= 2
            rect.size.height /= 2
            if q == 2 || q == 3 { rect.origin.x += rect.width }
            if q == 3 || q == 4 { rect.origin.y += rect.height }
        }
        return rect
    }

    /// `A` is 0, `Z` is 25, `AA` is 26, `AZ` is 51: bijective base 26.
    public static func columnIndex(_ letters: Substring) -> Int? {
        guard !letters.isEmpty else { return nil }
        var n = 0
        for scalar in letters.uppercased().unicodeScalars {
            guard let value = scalar.properties.numericType == nil ? Int(scalar.value) : nil,
                  value >= 65, value <= 90 else { return nil }
            n = n * 26 + (value - 64)
        }
        return n - 1
    }

    public static func columnName(_ index: Int) -> String {
        var n = index + 1
        var letters: [Character] = []
        while n > 0 {
            n -= 1
            letters.append(Character(UnicodeScalar(65 + n % 26)!))
            n /= 26
        }
        return String(letters.reversed())
    }

    /// `D5` or `D5.3.1` style, as an agent or a person would write it.
    public var name: String {
        ([Self.columnName(column) + String(row + 1)] + quadrants.map(String.init)).joined(separator: ".")
    }

    /// Parses `D5` or `D5.3.1` (case-insensitive, surrounding whitespace
    /// allowed) without checking it against a grid; see `GridDefinition.cell(_:)`.
    public static func parse(_ text: String) throws -> GridCell {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        let letters = parts[0].prefix { $0.isLetter }
        let digits = parts[0].dropFirst(letters.count)
        guard !letters.isEmpty, !digits.isEmpty, digits.allSatisfy(\.isNumber),
              let column = columnIndex(letters), let row = Int(digits), row >= 1,
              parts.count - 1 <= maxQuadrantDepth else {
            throw GridError.malformed(text)
        }
        let quadrants = try parts.dropFirst().map { part -> Int in
            guard part.count == 1, let q = Int(part), (1...4).contains(q) else { throw GridError.malformed(text) }
            return q
        }
        return GridCell(column: column, row: row - 1, quadrants: quadrants)
    }
}

/// An inclusive rectangle of cells from `first` (upper-left) to `last`
/// (lower-right). Either end may be a quadrant: `D5.3:F14` runs from the
/// lower-right quarter of `D5`.
public struct GridRange: Equatable, Hashable, Sendable {
    public var first: GridCell
    public var last: GridCell

    public init(first: GridCell, last: GridCell) {
        self.first = first
        self.last = last
    }

    public var name: String { first == last ? first.name : "\(first.name):\(last.name)" }

    /// Parses `D5:F14` or a lone `D5` (a one-cell range).
    public static func parse(_ text: String) throws -> GridRange {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            let cell = try GridCell.parse(text)
            return GridRange(first: cell, last: cell)
        case 2:
            let first = try GridCell.parse(String(parts[0]))
            let last = try GridCell.parse(String(parts[1]))
            // The range runs from `first`'s upper-left edge to `last`'s
            // lower-right edge; it must have area, which for whole cells is
            // the usual "last at or right of and below first".
            let a = first.unitRect, b = last.unitRect
            guard b.maxX > a.minX, b.maxY > a.minY else { throw GridError.reversedRange(text) }
            return GridRange(first: first, last: last)
        default:
            throw GridError.malformed(text)
        }
    }
}
