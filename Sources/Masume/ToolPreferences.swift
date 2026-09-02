import Foundation
import CoreGraphics
import AnnotationModel

/// Tool state remembered across launches: the active tool, color, per-group
/// stroke widths, pixel size, pen opacity, text style, and stamp glyph.
/// Sizes are stored relative to the reference canvas so a remembered
/// thickness looks the same on the next image whatever its pixel size.
struct ToolPreferences: Codable, Equatable {
    var tool: Tool = .arrow
    var strokeColor: RGBAColor = .red
    var referenceWidths: [StrokeWidthGroup: CGFloat] = ToolPreferences.defaultReferenceWidths
    var referencePixelateAmount: CGFloat = RedactionElement.defaultPixelateAmount
    var penOpacity: CGFloat = 1
    var textStyle: TextStyle = .shadow
    var textOutlineColor: RGBAColor = .white
    var stampKind: StampKind = .check

    static let defaultReferenceWidths: [StrokeWidthGroup: CGFloat] = [
        .segment: DefaultStrokeWidth.segmentReferenceWidth,
        .shape: DefaultStrokeWidth.shapeReferenceWidth,
        .pen: DefaultStrokeWidth.penReferenceWidth,
        .text: DefaultStrokeWidth.segmentReferenceWidth,
    ]

    init() {}

    /// Field-by-field decoding so a blob written before a field existed still
    /// loads, with the missing fields at their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ToolPreferences()
        tool = try c.decodeIfPresent(Tool.self, forKey: .tool) ?? defaults.tool
        strokeColor = try c.decodeIfPresent(RGBAColor.self, forKey: .strokeColor) ?? defaults.strokeColor
        referenceWidths = defaults.referenceWidths.merging(
            try c.decodeIfPresent([StrokeWidthGroup: CGFloat].self, forKey: .referenceWidths) ?? [:]
        ) { $1 }
        referencePixelateAmount = try c.decodeIfPresent(CGFloat.self, forKey: .referencePixelateAmount)
            ?? defaults.referencePixelateAmount
        penOpacity = try c.decodeIfPresent(CGFloat.self, forKey: .penOpacity) ?? defaults.penOpacity
        textStyle = try c.decodeIfPresent(TextStyle.self, forKey: .textStyle) ?? defaults.textStyle
        textOutlineColor = try c.decodeIfPresent(RGBAColor.self, forKey: .textOutlineColor) ?? defaults.textOutlineColor
        stampKind = try c.decodeIfPresent(StampKind.self, forKey: .stampKind) ?? defaults.stampKind
    }
}

/// Where tool preferences live between launches.
protocol ToolPreferencesStore: AnyObject {
    func load() -> ToolPreferences?
    func save(_ preferences: ToolPreferences)
}

/// JSON blob under one UserDefaults key. An unreadable blob reads as nil so
/// the app falls back to defaults rather than failing to start.
final class UserDefaultsToolPreferencesStore: ToolPreferencesStore {
    static let key = "toolPreferences"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ToolPreferences? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(ToolPreferences.self, from: data)
    }

    func save(_ preferences: ToolPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Test double: keeps the last saved value in memory.
final class InMemoryToolPreferencesStore: ToolPreferencesStore {
    private(set) var stored: ToolPreferences?
    private(set) var saveCount = 0

    init(_ initial: ToolPreferences? = nil) {
        stored = initial
    }

    func load() -> ToolPreferences? { stored }

    func save(_ preferences: ToolPreferences) {
        stored = preferences
        saveCount += 1
    }
}
