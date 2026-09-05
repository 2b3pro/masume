import XCTest
import CoreGraphics
@testable import AnnotationModel

/// The spreadsheet grid: deterministic sizing from image pixels alone,
/// bijective column letters, exact edges, and a parser that refuses rather
/// than clamps.
final class GridTests: XCTestCase {

    // MARK: Sizing

    func testTierBoundaries() {
        XCTAssertEqual(GridDefinition.tier(forLongSide: 200), 8)
        XCTAssertEqual(GridDefinition.tier(forLongSide: 800), 8)
        XCTAssertEqual(GridDefinition.tier(forLongSide: 801), 12)
        XCTAssertEqual(GridDefinition.tier(forLongSide: 1600), 12)
        XCTAssertEqual(GridDefinition.tier(forLongSide: 1601), 16)
        XCTAssertEqual(GridDefinition.tier(forLongSide: 2600), 16)
        XCTAssertEqual(GridDefinition.tier(forLongSide: 2601), 24)
        XCTAssertEqual(GridDefinition.tier(forLongSide: 4000), 24)
        XCTAssertEqual(GridDefinition.tier(forLongSide: 4001), 32)
    }

    func testSpecExamples() {
        func grid(_ w: CGFloat, _ h: CGFloat) -> (Int, Int) {
            let g = GridDefinition.default(for: CGSize(width: w, height: h))
            return (g.columns, g.rows)
        }
        XCTAssertTrue(grid(200, 200) == (8, 8), "icon")
        XCTAssertTrue(grid(1440, 900) == (12, 8), "900 / 120 = 7.5 rounds away from zero")
        XCTAssertTrue(grid(2880, 1800) == (24, 15), "2x Retina")
        XCTAssertTrue(grid(1170, 2532) == (7, 16), "portrait phone")
        XCTAssertTrue(grid(3840, 2160) == (24, 14), "4K")
    }

    func testCountsAreClampedAndDegenerateSizesAreSafe() {
        let sliver = GridDefinition.default(for: CGSize(width: 4000, height: 10))
        XCTAssertEqual(sliver.columns, 24)
        XCTAssertEqual(sliver.rows, 2, "never fewer than two rows")
        XCTAssertEqual(GridDefinition(columns: 500, rows: 0).columns, 64)
        XCTAssertEqual(GridDefinition(columns: 500, rows: 0).rows, 2)
        XCTAssertEqual(GridDefinition.default(for: .zero), GridDefinition(columns: 2, rows: 2))
    }

    func testPresetsDeriveLikeTheDefaultAndAreRecognized() {
        let size = CGSize(width: 1440, height: 900)
        let fine = GridDefinition.preset(24, for: size)
        XCTAssertEqual(fine.columns, 24)
        XCTAssertEqual(fine.rows, 15)
        XCTAssertEqual(fine.matchingPreset(for: size), 24)
        XCTAssertEqual(GridDefinition.default(for: size).matchingPreset(for: size), 12)
        XCTAssertNil(GridDefinition(columns: 5, rows: 5).matchingPreset(for: size))
    }

    func testStoredCountsDoNotDependOnTheTierTable() throws {
        // A grid decoded from a project keeps its counts whatever the
        // current default would be.
        let stored = try JSONDecoder().decode(GridDefinition.self,
                                              from: Data(#"{"columns": 10, "rows": 6, "version": 3}"#.utf8))
        XCTAssertEqual(stored, GridDefinition(columns: 10, rows: 6, version: 3))
        XCTAssertNotEqual(stored, GridDefinition.default(for: CGSize(width: 1440, height: 900)))
    }

    // MARK: Letters and parsing

    func testColumnLettersAreBijectiveBase26() {
        XCTAssertEqual(GridCell.columnName(0), "A")
        XCTAssertEqual(GridCell.columnName(25), "Z")
        XCTAssertEqual(GridCell.columnName(26), "AA")
        XCTAssertEqual(GridCell.columnName(51), "AZ")
        XCTAssertEqual(GridCell.columnName(52), "BA")
        XCTAssertEqual(GridCell.columnName(701), "ZZ")
        XCTAssertEqual(GridCell.columnName(702), "AAA")
        for i in 0..<800 {
            XCTAssertEqual(GridCell.columnIndex(Substring(GridCell.columnName(i))), i)
        }
        XCTAssertNil(GridCell.columnIndex(""))
        XCTAssertNil(GridCell.columnIndex("A1"))
    }

    func testCellParsingIsCaseInsensitiveAndStrict() throws {
        XCTAssertEqual(try GridCell.parse("D5"), GridCell(column: 3, row: 4))
        XCTAssertEqual(try GridCell.parse(" aa12 "), GridCell(column: 26, row: 11))
        XCTAssertEqual(try GridCell.parse("D5").name, "D5")
        for bad in ["", "5", "D", "D0", "D-1", "5D", "D5x", "D 5", "DD.5"] {
            XCTAssertThrowsError(try GridCell.parse(bad), bad) { error in
                XCTAssertEqual(error as? GridError, .malformed(bad))
            }
        }
    }

    func testQuadrantsNumberClockwiseFromTheUpperLeftAndNest() throws {
        XCTAssertEqual(try GridCell.parse("D5.3"), GridCell(column: 3, row: 4, quadrants: [3]))
        XCTAssertEqual(try GridCell.parse(" d5.3.1 ").name, "D5.3.1")
        XCTAssertEqual(GridCell(column: 3, row: 4).unitRect, CGRect(x: 3, y: 4, width: 1, height: 1))
        XCTAssertEqual(GridCell(column: 3, row: 4, quadrants: [1]).unitRect, CGRect(x: 3, y: 4, width: 0.5, height: 0.5))
        XCTAssertEqual(GridCell(column: 3, row: 4, quadrants: [2]).unitRect, CGRect(x: 3.5, y: 4, width: 0.5, height: 0.5))
        XCTAssertEqual(GridCell(column: 3, row: 4, quadrants: [3]).unitRect, CGRect(x: 3.5, y: 4.5, width: 0.5, height: 0.5))
        XCTAssertEqual(GridCell(column: 3, row: 4, quadrants: [4]).unitRect, CGRect(x: 3, y: 4.5, width: 0.5, height: 0.5))
        XCTAssertEqual(GridCell(column: 3, row: 4, quadrants: [3, 1]).unitRect,
                       CGRect(x: 3.5, y: 4.5, width: 0.25, height: 0.25), "the upper-left quarter of the lower-right quarter")
        XCTAssertNoThrow(try GridCell.parse("D5.1.2.3.4"), "four levels deep is allowed")
        for bad in ["D5.", "D5.0", "D5.5", "D5.a", "D5.13", "D5..3", ".3", "D5.1.2.3.4.1"] {
            XCTAssertThrowsError(try GridCell.parse(bad), bad) { XCTAssertEqual($0 as? GridError, .malformed(bad)) }
        }
        XCTAssertTrue(GridError.malformed("x").localizedDescription.contains("D5.3"), "the message teaches the grammar")
    }

    func testQuadrantsResolveToTheirQuarterOfTheCell() throws {
        let size = CGSize(width: 1200, height: 800)
        let grid = GridDefinition(columns: 12, rows: 8)     // 100 × 100 cells; D5 is x 300..400, y 400..500
        XCTAssertEqual(try grid.resolve("D5.3", in: size).rect, CGRect(x: 350, y: 450, width: 50, height: 50))
        XCTAssertEqual(try grid.resolve("D5.3", in: size).center, CGPoint(x: 375, y: 475))
        XCTAssertEqual(try grid.resolve("D5.3.1", in: size).rect, CGRect(x: 350, y: 450, width: 25, height: 25))
        XCTAssertEqual(try grid.resolve("D5.1", in: size).rect.origin, try grid.resolve("D5", in: size).rect.origin,
                       "a quadrant's outer edges are its cell's edges")
        XCTAssertEqual(try grid.resolve("D5.3", in: size).rect.maxX, try grid.resolve("D5", in: size).rect.maxX)
        XCTAssertEqual(try grid.resolve("D5.3:E5.4", in: size).rect, CGRect(x: 350, y: 450, width: 100, height: 50),
                       "from the first's upper-left edge to the last's lower-right edge")
        XCTAssertEqual(try grid.resolve("D5.3:E5", in: size).rect, CGRect(x: 350, y: 450, width: 150, height: 50))
        XCTAssertEqual(try grid.range("d5.3:e5.4").name, "D5.3:E5.4")
        for reversed in ["D5.3:D5.1", "D5.3:E5.1", "D5.2:D5.4"] {
            XCTAssertThrowsError(try grid.range(reversed), reversed) {
                XCTAssertEqual($0 as? GridError, .reversedRange(reversed), "no area between those edges")
            }
        }
        XCTAssertThrowsError(try grid.range("M1.3")) { XCTAssertEqual($0 as? GridError, .outOfRange("M1.3", columns: 12, rows: 8)) }
    }

    func testRangeCoveringARectTakesTheCellsUnderItsCorners() {
        let size = CGSize(width: 1200, height: 800)
        let grid = GridDefinition(columns: 12, rows: 8)     // 100 px cells
        XCTAssertEqual(grid.range(covering: CGRect(x: 150, y: 250, width: 300, height: 100), in: size)?.name, "B3:E4")
        XCTAssertEqual(grid.range(covering: CGRect(x: 100, y: 200, width: 100, height: 100), in: size)?.name, "B3",
                       "a rect that is exactly one cell covers just that cell")
        XCTAssertEqual(grid.range(covering: CGRect(x: -50, y: -50, width: 200, height: 200), in: size)?.name, "A1:B2",
                       "clamped into the grid")
        XCTAssertEqual(grid.range(covering: CGRect(x: 1150, y: 750, width: 500, height: 500), in: size)?.name, "L8")
        XCTAssertNil(grid.range(covering: CGRect(x: 2000, y: 2000, width: 10, height: 10), in: size), "misses the canvas")
        let zone = Zone(rect: CGRect(x: 60, y: 50, width: -50, height: -40))
        XCTAssertEqual(zone.rect, CGRect(x: 10, y: 10, width: 50, height: 40), "zones are stored normalized")
        XCTAssertEqual(zone.center, CGPoint(x: 35, y: 30))
    }

    func testRangeParsingRejectsReversedRanges() throws {
        XCTAssertEqual(try GridRange.parse("D5:F14"), GridRange(first: GridCell(column: 3, row: 4),
                                                                last: GridCell(column: 5, row: 13)))
        XCTAssertEqual(try GridRange.parse("D5").name, "D5", "a lone cell is a one-cell range")
        XCTAssertEqual(try GridRange.parse("d5:f14").name, "D5:F14")
        XCTAssertThrowsError(try GridRange.parse("F14:D5")) { XCTAssertEqual($0 as? GridError, .reversedRange("F14:D5")) }
        XCTAssertThrowsError(try GridRange.parse("D14:F5")) { XCTAssertEqual($0 as? GridError, .reversedRange("D14:F5")) }
        XCTAssertThrowsError(try GridRange.parse("D5:")) { XCTAssertEqual($0 as? GridError, .malformed("")) }
        XCTAssertThrowsError(try GridRange.parse("A1:B2:C3")) { XCTAssertEqual($0 as? GridError, .malformed("A1:B2:C3")) }
    }

    func testValidationAgainstTheGridNeverClamps() {
        let grid = GridDefinition(columns: 12, rows: 8)
        XCTAssertNoThrow(try grid.cell("L8"))
        XCTAssertThrowsError(try grid.cell("M1")) { error in
            XCTAssertEqual(error as? GridError, .outOfRange("M1", columns: 12, rows: 8))
            XCTAssertEqual(error.localizedDescription.contains("L8"), true, "the message names the last cell")
        }
        XCTAssertThrowsError(try grid.cell("A9"))
        XCTAssertThrowsError(try grid.range("K7:M9")) { error in
            XCTAssertEqual(error as? GridError, .outOfRange("M9", columns: 12, rows: 8))
        }
    }

    // MARK: Resolution

    func testEdgesAreExactAndCellsCoverTheImage() {
        let size = CGSize(width: 1170, height: 2532)
        let grid = GridDefinition.default(for: size)   // 7 × 16
        XCTAssertEqual(grid.edgeX(0, in: size), 0)
        XCTAssertEqual(grid.edgeX(7, in: size), 1170, "the last edge is the image edge, exactly")
        XCTAssertEqual(grid.edgeY(16, in: size), 2532)
        XCTAssertEqual(grid.edgeX(3, in: size), 3 * 1170 / 7, accuracy: 1e-12)
        var covered: CGFloat = 0
        for c in 0..<grid.columns { covered += grid.rect(of: GridCell(column: c, row: 0), in: size).width }
        XCTAssertEqual(covered, 1170, accuracy: 1e-9)
    }

    func testCellCenterAndRangeRectangleAndNormalized() throws {
        let size = CGSize(width: 1200, height: 800)
        let grid = GridDefinition(columns: 12, rows: 8)   // 100 px cells
        let d5 = try grid.resolve("D5", in: size)
        XCTAssertEqual(d5.rect, CGRect(x: 300, y: 400, width: 100, height: 100))
        XCTAssertEqual(d5.center, CGPoint(x: 350, y: 450))
        XCTAssertEqual(d5.normalized, CGRect(x: 0.25, y: 0.5, width: 100 / 1200, height: 0.125))
        XCTAssertEqual(d5.corners, [CGPoint(x: 300, y: 400), CGPoint(x: 400, y: 400),
                                    CGPoint(x: 400, y: 500), CGPoint(x: 300, y: 500)])
        let range = try grid.resolve("D5:F7", in: size)
        XCTAssertEqual(range.rect, CGRect(x: 300, y: 400, width: 300, height: 300), "inclusive of F7")
        XCTAssertEqual(try grid.resolve("A1:L8", in: size).rect, CGRect(origin: .zero, size: size))
    }

    func testPointToCellFloorsAndClampsAtTheEdges() {
        let size = CGSize(width: 1200, height: 800)
        let grid = GridDefinition(columns: 12, rows: 8)
        XCTAssertEqual(grid.cell(containing: CGPoint(x: 350, y: 450), in: size), GridCell(column: 3, row: 4))
        XCTAssertEqual(grid.cell(containing: CGPoint(x: 400, y: 500), in: size), GridCell(column: 4, row: 5),
                       "a point on an edge belongs to the next cell")
        XCTAssertEqual(grid.cell(containing: CGPoint(x: 1200, y: 800), in: size), GridCell(column: 11, row: 7),
                       "the far edge lands in the last cell")
        XCTAssertEqual(grid.cell(containing: CGPoint(x: -5, y: -5), in: size), GridCell(column: 0, row: 0))
    }

    func testResolutionIsIndependentOfAnyViewport() throws {
        // Same image, same address, same answer; there is no window in sight.
        let size = CGSize(width: 2880, height: 1800)
        let grid = GridDefinition.default(for: size)
        let first = try grid.resolve("H9", in: size)
        let again = try GridDefinition.default(for: size).resolve("h9", in: size)
        XCTAssertEqual(first, again)
    }
}

/// The grid inside the document and the package.
final class GridStorageTests: XCTestCase {

    func testDocumentDefaultsItsGridFromTheCanvasAndDecodesWithoutOne() throws {
        let doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 1440, height: 900))
        XCTAssertEqual(doc.grid, GridDefinition(columns: 12, rows: 8))
        let legacy = Data("""
        {"baseImage":{"pngData":{"_0":""}},"canvasSize":[1440,900],"elements":[]}
        """.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Document.self, from: legacy).grid, GridDefinition(columns: 12, rows: 8))
        let roundTrip = try JSONDecoder().decode(Document.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(roundTrip, doc)
    }

    func testManifestStoresTheGridAndTreatsItsAbsenceAsDefault() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        var m = ProjectManifest(id: UUID(), revision: 1, canvasSize: CGSize(width: 1440, height: 900), crop: nil,
                                elements: [], createdAt: Date(), updatedAt: Date(),
                                baseImage: BaseImageInfo(fileName: "base-image.png", sha256: "", width: 1440, height: 900),
                                grid: GridDefinition(columns: 24, rows: 15, version: 2))
        let back = try ProjectPackage.decodeManifest(try ProjectPackage.encodeManifest(m))
        XCTAssertEqual(back.grid, GridDefinition(columns: 24, rows: 15, version: 2))
        XCTAssertTrue(back.extra.isEmpty, "grid is a known key, not an unknown one")
        m.grid = nil
        XCTAssertNil(try ProjectPackage.decodeManifest(try ProjectPackage.encodeManifest(m)).grid)
    }

    func testGridChangeIsAHistoryEntryWithItsOwnSentence() {
        let actor = HistoryActor(id: "human", name: "Ian")
        let old = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 1440, height: 900))
        var new = old
        new.grid = GridDefinition.preset(24, for: old.canvasSize, version: 2)
        let entry = HistoryEntry.diff(from: old, to: new, actor: actor, revisionBefore: 3)
        XCTAssertEqual(entry.summary, "Ian changed the grid to 24\u{00D7}15")
        XCTAssertEqual(entry.gridBefore, old.grid)
        XCTAssertEqual(entry.gridAfter, new.grid)
        XCTAssertTrue(entry.affected.isEmpty)
        let plain = HistoryEntry.diff(from: old, to: old, actor: actor, revisionBefore: 3)
        XCTAssertNil(plain.gridAfter)
    }
}
