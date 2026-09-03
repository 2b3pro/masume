import Foundation

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
            return "\u{201C}\(s)\u{201D} is not a grid address. Use a cell like D5 or a range like D5:F14."
        case .outOfRange(let s, let columns, let rows):
            return "\u{201C}\(s)\u{201D} is outside the grid, which is \(GridCell.columnName(columns - 1))\(rows) at most."
        case .reversedRange(let s):
            return "\u{201C}\(s)\u{201D} is reversed; the first cell must be above and left of the second."
        }
    }
}

/// One cell, zero-based. `D5` is column 3, row 4.
public struct GridCell: Equatable, Hashable, Sendable {
    public var column: Int
    public var row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
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

    /// `D5` style, as an agent or a person would write it.
    public var name: String { "\(Self.columnName(column))\(row + 1)" }

    /// Parses `D5` (case-insensitive, surrounding whitespace allowed)
    /// without checking it against a grid; see `GridDefinition.cell(_:)`.
    public static func parse(_ text: String) throws -> GridCell {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let letters = trimmed.prefix { $0.isLetter }
        let digits = trimmed.dropFirst(letters.count)
        guard !letters.isEmpty, !digits.isEmpty, digits.allSatisfy(\.isNumber),
              let column = columnIndex(letters), let row = Int(digits), row >= 1 else {
            throw GridError.malformed(text)
        }
        return GridCell(column: column, row: row - 1)
    }
}

/// An inclusive rectangle of cells from `first` (upper-left) to `last`
/// (lower-right).
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
            guard last.column >= first.column, last.row >= first.row else { throw GridError.reversedRange(text) }
            return GridRange(first: first, last: last)
        default:
            throw GridError.malformed(text)
        }
    }
}
