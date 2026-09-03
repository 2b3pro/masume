import Foundation
import CryptoKit

/// The `.masume` package on disk:
///
/// ```
/// Name.masume/
///   manifest.json     the document, its identity, and its revision
///   base-image.png    written once, verified by checksum on read
///   preview.png       optional flattened preview
///   history.jsonl     one HistoryEntry per line, append-only
/// ```
///
/// `create` builds the whole package beside its destination and swaps it in,
/// so a half-written package never exists at the path. `update` replaces the
/// manifest through a temporary file and appends to the history; the base
/// image is never rewritten. `read` verifies before it returns anything.
public enum ProjectPackage {
    public static let pathExtension = "masume"
    public static let manifestName = "manifest.json"
    public static let baseImageName = "base-image.png"
    public static let previewName = "preview.png"
    public static let historyName = "history.jsonl"
    public static let assetsDirectoryName = "assets"

    /// Everything a verified package holds.
    public struct Contents: Equatable, Sendable {
        public var manifest: ProjectManifest
        public var baseImagePNG: Data
        public var history: [HistoryEntry]
        /// Image layers' pixels by asset id.
        public var assets: [UUID: Data]

        public init(manifest: ProjectManifest, baseImagePNG: Data, history: [HistoryEntry], assets: [UUID: Data] = [:]) {
            self.manifest = manifest; self.baseImagePNG = baseImagePNG; self.history = history; self.assets = assets
        }
    }

    public static func assetFileName(for id: UUID) -> String { "\(id.uuidString).png" }

    // MARK: Encoding

    // Dates are ISO 8601 with milliseconds ("2026-09-02T21:58:49.825Z"), the
    // precision `Dates.rounded` stores, so a round trip is exact. The
    // formatters are documented thread-safe, hence `nonisolated(unsafe)`.
    private nonisolated(unsafe) static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func encoder(pretty: Bool) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(fractionalFormatter.string(from: date))
        }
        return e
    }

    private static var manifestEncoder: JSONEncoder { encoder(pretty: true) }
    private static var lineEncoder: JSONEncoder { encoder(pretty: false) }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Not an ISO 8601 date: \(string)"))
            }
            return date
        }
        return d
    }

    public static func encodeManifest(_ manifest: ProjectManifest) throws -> Data {
        try manifestEncoder.encode(manifest)
    }

    /// Decodes a manifest. A newer format version surfaces as
    /// `unsupportedVersion`; any other decoding failure as `corruptManifest`.
    public static func decodeManifest(_ data: Data) throws -> ProjectManifest {
        do {
            return try decoder.decode(ProjectManifest.self, from: data)
        } catch let error as ProjectError {
            throw error
        } catch {
            throw ProjectError.corruptManifest(String(describing: error))
        }
    }

    private static func encodeHistoryLines(_ entries: [HistoryEntry]) throws -> Data {
        var data = Data()
        for entry in entries {
            data.append(try lineEncoder.encode(entry))
            data.append(0x0A)
        }
        return data
    }

    private static func decodeHistory(_ data: Data) throws -> [HistoryEntry] {
        try data.split(separator: 0x0A).filter { !$0.isEmpty }.map { line in
            do {
                return try decoder.decode(HistoryEntry.self, from: line)
            } catch {
                throw ProjectError.io("The project's history could not be read: \(error)")
            }
        }
    }

    // MARK: Verification helpers

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Width and height from a PNG's IHDR chunk, without decoding the image.
    public static func pngPixelSize(_ data: Data) -> (width: Int, height: Int)? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= 24, Array(data.prefix(8)) == signature,
              Array(data[12..<16]) == Array("IHDR".utf8) else { return nil }
        func be32(_ offset: Int) -> Int {
            data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        }
        return (be32(16), be32(20))
    }

    // MARK: Create

    /// Writes a complete package, replacing any package already at `url`.
    /// The files land in a hidden temporary directory beside `url` first and
    /// are moved into place in one step.
    public static func create(at url: URL, manifest: ProjectManifest, baseImagePNG: Data,
                              preview: Data?, history: [HistoryEntry], assets: [UUID: Data] = [:]) throws {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        let temp = parent.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: false)
            try encodeManifest(manifest).write(to: temp.appendingPathComponent(manifestName))
            try baseImagePNG.write(to: temp.appendingPathComponent(manifest.baseImage.fileName))
            if let preview { try preview.write(to: temp.appendingPathComponent(previewName)) }
            try encodeHistoryLines(history).write(to: temp.appendingPathComponent(historyName))
            try writeAssets(manifest.assets, assets, in: temp)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw ProjectError.io("Could not write the project: \(error.localizedDescription)")
        }
    }

    // MARK: Update

    /// Replaces the manifest (and preview, when given) atomically and appends
    /// `entries` to the history. The base image is left alone.
    public static func update(at url: URL, manifest: ProjectManifest, preview: Data?,
                              appending entries: [HistoryEntry], assets: [UUID: Data] = [:]) throws {
        do {
            try writeAssets(manifest.assets, assets, in: url)
            try replaceFile(at: url.appendingPathComponent(manifestName), with: encodeManifest(manifest))
            if let preview {
                try replaceFile(at: url.appendingPathComponent(previewName), with: preview)
            }
            try appendHistory(entries, in: url)
        } catch let error as ProjectError {
            throw error
        } catch {
            throw ProjectError.io("Could not update the project: \(error.localizedDescription)")
        }
    }

    /// Writes the listed assets that are not on disk yet. Assets are
    /// immutable, so an existing file is never rewritten.
    private static func writeAssets(_ infos: [AssetInfo], _ data: [UUID: Data], in package: URL) throws {
        guard !infos.isEmpty else { return }
        let directory = package.appendingPathComponent(assetsDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for info in infos {
            let file = directory.appendingPathComponent((info.fileName as NSString).lastPathComponent)
            guard !FileManager.default.fileExists(atPath: file.path) else { continue }
            guard let bytes = data[info.id] else { throw ProjectError.badAsset(info.fileName) }
            try bytes.write(to: file)
        }
    }

    private static func replaceFile(at url: URL, with data: Data) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temp)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }

    private static func appendHistory(_ entries: [HistoryEntry], in package: URL) throws {
        guard !entries.isEmpty else { return }
        let url = package.appendingPathComponent(historyName)
        let data = try encodeHistoryLines(entries)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    // MARK: Read

    /// Reads and verifies a package: manifest version, base image checksum
    /// and pixel size against both the manifest and the canvas, and element
    /// id uniqueness. Nothing is returned unless every check passes.
    public static func read(at url: URL) throws -> Contents {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectError.io("No project at \(url.path).")
        }
        guard let manifestData = fm.contents(atPath: url.appendingPathComponent(manifestName).path) else {
            throw ProjectError.corruptManifest("manifest.json is missing")
        }
        let manifest = try decodeManifest(manifestData)

        let imageName = (manifest.baseImage.fileName as NSString).lastPathComponent
        guard let image = fm.contents(atPath: url.appendingPathComponent(imageName).path) else {
            throw ProjectError.missingBaseImage
        }
        guard sha256Hex(image) == manifest.baseImage.sha256.lowercased() else {
            throw ProjectError.checksumMismatch
        }
        guard let size = pngPixelSize(image),
              size.width == manifest.baseImage.width, size.height == manifest.baseImage.height,
              CGFloat(size.width) == manifest.canvasSize.width,
              CGFloat(size.height) == manifest.canvasSize.height else {
            throw ProjectError.sizeMismatch
        }
        guard Set(manifest.elements.map(\.id)).count == manifest.elements.count else {
            throw ProjectError.duplicateElementIDs
        }
        var assets: [UUID: Data] = [:]
        for info in manifest.assets {
            let file = url.appendingPathComponent(assetsDirectoryName).appendingPathComponent((info.fileName as NSString).lastPathComponent)
            guard let bytes = fm.contents(atPath: file.path), sha256Hex(bytes) == info.sha256.lowercased() else {
                throw ProjectError.badAsset(info.fileName)
            }
            assets[info.id] = bytes
        }
        let history = try fm.contents(atPath: url.appendingPathComponent(historyName).path).map(decodeHistory) ?? []
        return Contents(manifest: manifest, baseImagePNG: image, history: history, assets: assets)
    }
}
