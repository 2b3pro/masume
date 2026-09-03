import Foundation
import CoreGraphics

/// Why a package could not be read or written. Each case names one check,
/// so the UI and the agent surface can say exactly what failed.
public enum ProjectError: Error, Equatable, Sendable, LocalizedError {
    /// The manifest was written by a newer Masume; nothing is loaded.
    case unsupportedVersion(Int)
    case corruptManifest(String)
    case missingBaseImage
    /// The base image bytes do not hash to the manifest's checksum.
    case checksumMismatch
    /// The base image's pixel size disagrees with the manifest or canvas.
    case sizeMismatch
    case duplicateElementIDs
    /// An image layer's asset is missing or does not match its checksum.
    case badAsset(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "This project was saved by a newer version of Masume (format \(v)) and cannot be opened."
        case .corruptManifest(let detail):
            return "The project's manifest could not be read: \(detail)"
        case .missingBaseImage:
            return "The project is missing its base image."
        case .checksumMismatch:
            return "The project's base image does not match its checksum; the file may have been altered."
        case .sizeMismatch:
            return "The project's base image is not the size the manifest expects."
        case .duplicateElementIDs:
            return "The project contains duplicate annotation IDs."
        case .badAsset(let name):
            return "The project's image asset \(name) is missing or altered."
        case .io(let detail):
            return detail
        }
    }
}

/// A JSON value kept verbatim: how the manifest carries keys this version of
/// Masume does not know, so a newer field survives a round trip through an
/// older app.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// The stored base image: where it is in the package and how to verify it.
public struct BaseImageInfo: Codable, Equatable, Sendable {
    public var fileName: String
    /// Hex SHA-256 of the file's bytes.
    public var sha256: String
    public var width: Int
    public var height: Int

    public init(fileName: String, sha256: String, width: Int, height: Int) {
        self.fileName = fileName; self.sha256 = sha256; self.width = width; self.height = height
    }
}

/// `manifest.json`: the editable document plus its identity and revision.
/// Sizes and rects are written as objects (`{"width": …}`) so the file reads
/// plainly to a person or an agent. Unknown top-level keys are preserved.
public struct ProjectManifest: Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var id: UUID
    public var revision: Int
    public var canvasSize: CGSize
    public var crop: CGRect?
    public var elements: [Annotation]
    public var createdAt: Date
    public var updatedAt: Date
    public var baseImage: BaseImageInfo
    /// Image layers' pixels, one file each under `assets/`.
    public var assets: [AssetInfo]
    /// Stored grid counts; nil in packages written before grids existed, in
    /// which case the default for the canvas size applies.
    public var grid: GridDefinition?
    /// The name the user gave an unsaved document (the tab title and the
    /// default file name); nil once saved, when the file name is the name.
    public var workingName: String?
    /// Recovery packages only: the project this document was saved to, so a
    /// relaunch can rebind it.
    public var boundProjectPath: String?
    /// Top-level keys this version does not understand, written back as is.
    public var extra: [String: JSONValue]

    public init(formatVersion: Int = ProjectManifest.currentFormatVersion, id: UUID, revision: Int,
                canvasSize: CGSize, crop: CGRect?, elements: [Annotation], createdAt: Date, updatedAt: Date,
                baseImage: BaseImageInfo, assets: [AssetInfo] = [], grid: GridDefinition? = nil,
                workingName: String? = nil, boundProjectPath: String? = nil, extra: [String: JSONValue] = [:]) {
        self.formatVersion = formatVersion; self.id = id; self.revision = revision
        self.canvasSize = canvasSize; self.crop = crop; self.elements = elements
        self.createdAt = Dates.rounded(createdAt); self.updatedAt = Dates.rounded(updatedAt); self.baseImage = baseImage
        self.assets = assets; self.grid = grid; self.workingName = workingName
        self.boundProjectPath = boundProjectPath; self.extra = extra
    }
}

// MARK: - Codable with unknown-key preservation

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    static func named(_ name: String) -> DynamicKey { DynamicKey(stringValue: name) }
}

private struct SizeJSON: Codable {
    var width: Double
    var height: Double
    init(_ size: CGSize) { width = size.width; height = size.height }
    var cgSize: CGSize { CGSize(width: width, height: height) }
}

private struct RectJSON: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    init(_ rect: CGRect) { x = rect.origin.x; y = rect.origin.y; width = rect.width; height = rect.height }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

extension ProjectManifest: Codable {
    private static let knownKeys: Set<String> = [
        "formatVersion", "id", "revision", "canvasSize", "crop", "elements",
        "createdAt", "updatedAt", "baseImage", "assets", "grid", "workingName", "boundProjectPath",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        // The version gate runs before anything else is touched, so a newer
        // file fails with its own error rather than a decoding one.
        let version = try c.decode(Int.self, forKey: .named("formatVersion"))
        guard version <= Self.currentFormatVersion else { throw ProjectError.unsupportedVersion(version) }
        formatVersion = version
        id = try c.decode(UUID.self, forKey: .named("id"))
        revision = try c.decode(Int.self, forKey: .named("revision"))
        canvasSize = try c.decode(SizeJSON.self, forKey: .named("canvasSize")).cgSize
        crop = try c.decodeIfPresent(RectJSON.self, forKey: .named("crop"))?.cgRect
        elements = try c.decode([Annotation].self, forKey: .named("elements"))
        createdAt = try c.decode(Date.self, forKey: .named("createdAt"))
        updatedAt = try c.decode(Date.self, forKey: .named("updatedAt"))
        baseImage = try c.decode(BaseImageInfo.self, forKey: .named("baseImage"))
        assets = try c.decodeIfPresent([AssetInfo].self, forKey: .named("assets")) ?? []
        grid = try c.decodeIfPresent(GridDefinition.self, forKey: .named("grid"))
        workingName = try c.decodeIfPresent(String.self, forKey: .named("workingName"))
        boundProjectPath = try c.decodeIfPresent(String.self, forKey: .named("boundProjectPath"))
        var unknown: [String: JSONValue] = [:]
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
            unknown[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
        }
        extra = unknown
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try c.encode(formatVersion, forKey: .named("formatVersion"))
        try c.encode(id, forKey: .named("id"))
        try c.encode(revision, forKey: .named("revision"))
        try c.encode(SizeJSON(canvasSize), forKey: .named("canvasSize"))
        try c.encodeIfPresent(crop.map(RectJSON.init), forKey: .named("crop"))
        try c.encode(elements, forKey: .named("elements"))
        try c.encode(createdAt, forKey: .named("createdAt"))
        try c.encode(updatedAt, forKey: .named("updatedAt"))
        try c.encode(baseImage, forKey: .named("baseImage"))
        if !assets.isEmpty { try c.encode(assets, forKey: .named("assets")) }
        try c.encodeIfPresent(grid, forKey: .named("grid"))
        try c.encodeIfPresent(workingName, forKey: .named("workingName"))
        try c.encodeIfPresent(boundProjectPath, forKey: .named("boundProjectPath"))
        for (key, value) in extra where !Self.knownKeys.contains(key) {
            try c.encode(value, forKey: .named(key))
        }
    }
}
