import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import AnnotationModel
import AnnotationRender
import MasumeCommands

/// The subcommands that need no running app: they open a `.masume` package
/// or an image through the model and renderer libraries. Results use the
/// same envelope and shapes as the live commands.
public enum OfflineCommands {
    /// Where the app keeps recovery packages; overridable for tests (a
    /// process-wide setting, hence `nonisolated(unsafe)`).
    public nonisolated(unsafe) static var recoveryDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["MASUME_RECOVERY_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Masume/Recovery", isDirectory: true)
    }()

    // MARK: info

    public static func info(_ path: String) -> CommandResponse {
        do {
            let url = URL(fileURLWithPath: path)
            let contents = try ProjectPackage.read(at: url)
            let m = contents.manifest
            let grid = m.grid ?? .default(for: m.canvasSize)
            return .success(.object([
                "id": .string(m.id.uuidString),
                "revision": .int(m.revision),
                "name": .string(url.deletingPathExtension().lastPathComponent),
                "path": .string(url.standardizedFileURL.path),
                "canvas": .size(m.canvasSize),
                "grid": .object(["columns": .int(grid.columns), "rows": .int(grid.rows), "version": .int(grid.version)]),
                "crop": .optional(m.crop.map(JSONValue.rect)),
                "createdAt": .string(ISO8601DateFormatter().string(from: m.createdAt)),
                "updatedAt": .string(ISO8601DateFormatter().string(from: m.updatedAt)),
                "workingName": .optional(m.workingName.map(JSONValue.string)),
                "elementCount": .int(m.elements.count),
                "historyCount": .int(contents.history.count),
                "elements": .array(m.elements.map(ElementJSON.json)),
                "openInMasume": .bool(isOpenInApp(url)),
                "containsOriginalImage": .bool(true),
            ]))
        } catch {
            return .failure(CommandError.wrap(error))
        }
    }

    // MARK: export

    public static func export(_ path: String, to output: String, format formatName: String?,
                              bounds boundsName: String?) -> CommandResponse {
        do {
            let contents = try ProjectPackage.read(at: URL(fileURLWithPath: path))
            let m = contents.manifest
            guard let base = decode(contents.baseImagePNG) else { throw CommandError.io("the base image could not be decoded") }
            let document = Document(baseImage: .pngData(Data()), canvasSize: m.canvasSize,
                                    elements: m.elements, crop: m.crop, grid: m.grid)
            let out = URL(fileURLWithPath: output)
            let type = try utType(formatName ?? out.pathExtension)
            let bounds = try exportBounds(boundsName)
            let assets = contents.assets.compactMapValues(decode)
            guard let image = Renderer.flatten(document, baseImage: base, scale: 1, bounds: bounds, assets: assets),
                  let data = Renderer.encode(image, as: type) else {
                throw CommandError.io("the document could not be flattened")
            }
            try data.write(to: out, options: .atomic)
            return .success(.object(["path": .string(out.standardizedFileURL.path), "format": .string(formatName ?? out.pathExtension.lowercased()),
                                     "width": .int(image.width), "height": .int(image.height)]))
        } catch {
            return .failure(CommandError.wrap(error))
        }
    }

    // MARK: resolve

    public static func resolve(_ address: String, file path: String) -> CommandResponse {
        do {
            let m = try ProjectPackage.read(at: URL(fileURLWithPath: path)).manifest
            let grid = m.grid ?? .default(for: m.canvasSize)
            let range = try grid.range(address)
            let geometry = grid.geometry(of: range, in: m.canvasSize)
            return .success(.object([
                "address": .string(range.name),
                "cells": .object(["first": .string(range.first.name), "last": .string(range.last.name)]),
                "rect": .rect(geometry.rect),
                "center": .point(geometry.center),
                "corners": .array(geometry.corners.map(JSONValue.point)),
                "normalized": .rect(geometry.normalized),
                "grid": .object(["columns": .int(grid.columns), "rows": .int(grid.rows), "version": .int(grid.version)]),
            ]))
        } catch {
            return .failure(CommandError.wrap(error))
        }
    }

    // MARK: new

    /// A fresh project from an image or a PDF page, with the default grid.
    public static func new(from source: String, to path: String, page: Int?) -> CommandResponse {
        do {
            let sourceURL = URL(fileURLWithPath: source)
            let destination = URL(fileURLWithPath: path)
            guard destination.pathExtension == ProjectPackage.pathExtension else {
                throw CommandError.invalidArgument("the project path must end in .\(ProjectPackage.pathExtension)")
            }
            guard let image = try loadImage(sourceURL, page: page), let png = Renderer.encode(image, as: .png) else {
                throw CommandError.io("\(source) is not an image or PDF Masume can read")
            }
            let size = CGSize(width: image.width, height: image.height)
            let manifest = ProjectManifest(
                id: UUID(), revision: 0, canvasSize: size, crop: nil, elements: [], createdAt: Date(), updatedAt: Date(),
                baseImage: BaseImageInfo(fileName: ProjectPackage.baseImageName, sha256: ProjectPackage.sha256Hex(png),
                                         width: image.width, height: image.height),
                grid: .default(for: size))
            let preview = previewPNG(of: image, size: size)
            try ProjectPackage.create(at: destination, manifest: manifest, baseImagePNG: png, preview: preview, history: [])
            return .success(.object([
                "path": .string(destination.standardizedFileURL.path),
                "id": .string(manifest.id.uuidString),
                "canvas": .size(size),
                "grid": .object(["columns": .int(manifest.grid!.columns), "rows": .int(manifest.grid!.rows), "version": .int(1)]),
            ]))
        } catch {
            return .failure(CommandError.wrap(error))
        }
    }

    // MARK: Helpers

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func previewPNG(of image: CGImage, size: CGSize) -> Data? {
        let longSide = max(size.width, size.height)
        let scale = longSide > 512 ? 512 / longSide : 1
        let document = Document(baseImage: .pngData(Data()), canvasSize: size)
        guard let preview = Renderer.flatten(
            document,
            baseImage: image,
            scale: scale,
            bounds: .clipToImage
        ) else { return nil }
        return Renderer.encode(preview, as: .png)
    }

    private static func loadImage(_ url: URL, page: Int?) throws -> CGImage? {
        let data = try Data(contentsOf: url)
        if PDFRasterizer.looksLikePDF(data) {
            guard let pdf = PDFRasterizer.document(data: data) else { return nil }
            let number = page ?? 1
            guard (1...pdf.numberOfPages).contains(number) else {
                throw CommandError.invalidArgument("page must be 1 to \(pdf.numberOfPages)")
            }
            return PDFRasterizer.render(pdf, page: number)
        }
        if page != nil { throw CommandError.invalidArgument("--page applies to PDFs only") }
        return decode(data)
    }

    private static func utType(_ name: String) throws -> UTType {
        switch name.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "webp": return .webP
        default: throw CommandError.invalidArgument("format must be png, jpeg, or webp")
        }
    }

    private static func exportBounds(_ name: String?) throws -> ExportBounds {
        guard let name else { return .expandToFit }
        guard let bounds = ExportBounds(rawValue: name) else {
            throw CommandError.invalidArgument("bounds must be expandToFit or clipToImage")
        }
        return bounds
    }

    /// True when a recovery package binds this project: the app has it open
    /// (or crashed with it open), so an offline write would race it.
    public static func isOpenInApp(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        let packages = (try? FileManager.default.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: nil)) ?? []
        return packages.contains { package in
            guard package.pathExtension == ProjectPackage.pathExtension,
                  let data = FileManager.default.contents(atPath: package.appendingPathComponent(ProjectPackage.manifestName).path),
                  let manifest = try? ProjectPackage.decodeManifest(data),
                  let bound = manifest.boundProjectPath else { return false }
            return URL(fileURLWithPath: bound).standardizedFileURL.path == target
        }
    }
}
