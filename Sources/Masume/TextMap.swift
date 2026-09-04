import Foundation
import CoreGraphics
import AnnotationModel
import MasumeCommands

struct TextMap: Sendable {
    static let lowConfidenceThreshold: Float = 0.8
    static let readingOrderNotice = "Reading order across columns is not guaranteed. Mark a zone and read one column at a time."
    let documentID: UUID
    let revision: Int
    let checksum: String
    let baseImagePNG: Data
    let grid: GridDefinition
    let canvasSize: CGSize
    let documentPreferences: TextPreferences
    let preferences: TextPreferences
    let requested: String?
    let zone: Zone?
    let bounds: CGRect
    let lines: [TextRecognitionLine]

    var text: String { lines.map(\.text).joined(separator: "\n") }
    var transcription: String {
        lines.map { line in
            line.confidence < Self.lowConfidenceThreshold ? "[low confidence] \(line.text)" : line.text
        }.joined(separator: "\n")
    }

    func matches(_ query: String) -> [TextRecognitionLine] {
        guard !query.isEmpty else { return lines }
        return lines.filter { $0.text.localizedStandardContains(query) }
    }

    var json: JSONValue {
        let observations = lines.map { line -> JSONValue in
            .object([
                "text": .string(line.text), "confidence": .number(Double(line.confidence)),
                "lowConfidence": .bool(line.confidence < Self.lowConfidenceThreshold),
                "bounds": .rect(line.bounds), "normalized": .rect(grid.normalized(line.bounds, in: canvasSize)),
                "range": .optional(grid.range(covering: line.bounds, in: canvasSize).map { .string($0.name) }),
            ])
        }
        return .object([
            "documentId": .string(documentID.uuidString), "revision": .int(revision),
            "baseImageChecksum": .string(checksum), "requested": .optional(requested.map(JSONValue.string)),
            "bounds": .rect(bounds), "text": .string(text), "transcription": .string(transcription),
            "observations": .array(observations), "languages": .array(preferences.languages.map(JSONValue.string)),
            "readingOrderNotice": .string(Self.readingOrderNotice),
            "grid": .object(["columns": .int(grid.columns), "rows": .int(grid.rows), "version": .int(grid.version)]),
        ])
    }
}

struct TextRecognitionJob: Sendable {
    let image: CGImage
    let documentID: UUID
    let revision: Int
    let checksum: String
    let baseImagePNG: Data
    let document: Document
    let requested: String?
    let bounds: CGRect
    let preferences: TextPreferences
    let zone: Zone?

    func run(using recognizer: any TextRecognizing) throws -> TextMap {
        let recognized: [TextRecognitionLine]
        do {
            recognized = try recognizer.recognize(in: image, languages: preferences.languages, customWords: preferences.customWords)
        } catch {
            throw CommandError.io("text recognition failed: \(error.localizedDescription)")
        }
        let localBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let lines = recognized.compactMap { line -> TextRecognitionLine? in
            let local = line.bounds.intersection(localBounds)
            guard !local.isNull, !local.isEmpty else { return nil }
            return TextRecognitionLine(text: line.text, confidence: line.confidence,
                                       bounds: local.offsetBy(dx: bounds.minX, dy: bounds.minY))
        }
        return TextMap(documentID: documentID, revision: revision, checksum: checksum, baseImagePNG: baseImagePNG, grid: document.grid,
                       canvasSize: document.canvasSize, documentPreferences: document.textPreferences,
                       preferences: preferences, requested: requested, zone: zone, bounds: bounds, lines: lines)
    }
}
