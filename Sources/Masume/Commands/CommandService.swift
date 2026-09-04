import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import AnnotationModel
import MasumeCommands
import AnnotationRender

/// The one way anything outside the canvas drives a document: JSON command
/// in, JSON envelope out. MCP, the `masume` CLI, and the AppleScript
/// `execute` verb are all clients of this. It uses the same controller
/// mutations the UI uses, so agent edits share undo, history, and autosave
/// with the human's.
@MainActor
final class CommandService {
    let controller: CanvasController
    private let textRecognizer: any TextRecognizing

    init(controller: CanvasController, textRecognizer: any TextRecognizing = VisionTextRecognizer()) {
        self.controller = controller
        self.textRecognizer = textRecognizer
    }

    /// Where `view_base_image` crops go. Under Caches: not the project.
    static var cropDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("com.2b3pro.masume/crops", isDirectory: true)
    }()

    // MARK: Entry points

    /// Malformed JSON is the only input this cannot answer with an envelope;
    /// it returns an `invalid_argument` envelope anyway so callers have one
    /// shape to parse. (The Apple Event layer turns it into an event error.)
    func execute(json: Data, pretty: Bool = false) -> Data {
        let request: CommandRequest
        do {
            request = try JSONDecoder().decode(CommandRequest.self, from: json)
        } catch {
            return CommandResponse.failure(.invalidArgument("malformed request: \(error.localizedDescription)")).encoded(pretty: pretty)
        }
        return execute(request).encoded(pretty: pretty)
    }

    func execute(_ request: CommandRequest) -> CommandResponse {
        do {
            return .success(try dispatch(request))
        } catch {
            return .failure(CommandError.wrap(error))
        }
    }

    /// Commands that change the document through one attributed commit.
    static let mutationCommands: Set<String> = [
        "create_element", "update_element", "delete_elements", "set_crop", "set_grid_density", "batch",
    ]

    private func dispatch(_ request: CommandRequest) throws -> JSONValue {
        if Self.mutationCommands.contains(request.command) { return try mutate(request) }
        if request.command == "undo" || request.command == "redo" { return try undoRedo(request) }
        if request.command == "read_text" { return try readText(request) }
        return try dispatchOther(request)
    }

    private func dispatchOther(_ request: CommandRequest) throws -> JSONValue {
        switch request.command {
        case "get_active_document": return try getActiveDocument(request)
        case "set_zone": return try setZone(request)
        case "list_elements": return try listElements(request)
        case "get_element": return try getElement(request)
        case "resolve_grid": return try resolveGrid(request)
        case "view_base_image": return try viewBaseImage(request)
        case "get_history": return try getHistory(request)
        case "save_project": return try saveProject(request)
        case "export": return try export(request)
        default: throw CommandError.unsupported("unknown command \(request.command)")
        }
    }

    // MARK: Document and revision checks

    private var project: ProjectSession {
        get throws {
            guard let project = controller.project, controller.document != nil else {
                throw CommandError.notFound("no document is open")
            }
            return project
        }
    }

    private var document: Document {
        get throws {
            guard let document = controller.document else { throw CommandError.notFound("no document is open") }
            return document
        }
    }

    /// Mutations must name the document and its revision; reads may.
    private func assertTarget(_ request: CommandRequest, mutation: Bool) throws {
        let project = try project
        if mutation && (request.documentId == nil || request.expectedRevision == nil) {
            throw CommandError.invalidArgument("documentId and expectedRevision are required for \(request.command)")
        }
        if let id = request.documentId, id.lowercased() != project.id.uuidString.lowercased() {
            throw CommandError.conflict("document \(id) is not open; the active document is \(project.id.uuidString)")
        }
        if let expected = request.expectedRevision, expected != project.revision {
            throw CommandError.conflict("expected revision \(expected) but the document is at \(project.revision)")
        }
    }

    // MARK: Reads

    private func getActiveDocument(_ request: CommandRequest) throws -> JSONValue {
        try assertTarget(request, mutation: false)
        return try documentSummary()
    }

    func documentSummary() throws -> JSONValue {
        let project = try project
        let doc = try document
        return .object([
            "id": .string(project.id.uuidString),
            "revision": .int(project.revision),
            "name": .string(controller.documentTitle),
            "projectPath": .optional(project.projectURL.map { .string($0.path) }),
            "dirty": .bool(project.isDirty),
            "canvas": .size(doc.canvasSize),
            "grid": gridJSON(doc.grid),
            "crop": .optional(doc.crop.map(JSONValue.rect)),
            "selection": .optional(controller.selection.map { .string($0.uuidString) }),
            "zone": .optional(controller.zone.map { zoneJSON($0, in: doc) }),
            "elementCount": .int(doc.elements.count),
            "historyCount": .int(project.history.count),
            "containsOriginalImage": .bool(true),
        ])
    }

    private func gridJSON(_ grid: GridDefinition) -> JSONValue {
        .object(["columns": .int(grid.columns), "rows": .int(grid.rows), "version": .int(grid.version)])
    }

    private func listElements(_ request: CommandRequest) throws -> JSONValue {
        try assertTarget(request, mutation: false)
        let project = try project
        return .object(["revision": .int(project.revision),
                        "elements": .array(try document.elements.map(ElementJSON.json))])
    }

    private func getElement(_ request: CommandRequest) throws -> JSONValue {
        try assertTarget(request, mutation: false)
        let id = try request.parameters.string("id")
        guard let element = try document.elements.first(where: { $0.id.uuidString.lowercased() == id.lowercased() }) else {
            throw CommandError.notFound("no element \(id)")
        }
        return .object(["revision": .int(try project.revision), "element": ElementJSON.json(element)])
    }

    private func resolveGrid(_ request: CommandRequest) throws -> JSONValue {
        try assertTarget(request, mutation: false)
        let doc = try document
        let address = try request.parameters.string("address")
        if address.lowercased() == ElementInput.zoneAddress {
            guard let zone = controller.zone else { throw CommandError.notFound("no zone is drawn") }
            var fields = zoneFields(zone, in: doc)
            fields["grid"] = gridJSON(doc.grid)
            return .object(fields)
        }
        let range = try doc.grid.range(address)
        let geometry = doc.grid.geometry(of: range, in: doc.canvasSize)
        return .object([
            "address": .string(range.name),
            "cells": .object(["first": .string(range.first.name), "last": .string(range.last.name)]),
            "rect": .rect(geometry.rect),
            "center": .point(geometry.center),
            "corners": .array(geometry.corners.map(JSONValue.point)),
            "normalized": .rect(geometry.normalized),
            "grid": gridJSON(doc.grid),
        ])
    }

    /// The zone as agents see it: its rect and shape, the grid range that
    /// covers it (and that range's address), center, corners, and normalized
    /// coordinates, so it works both as a place to look and as geometry.
    func zoneJSON(_ zone: Zone, in doc: Document) -> JSONValue { .object(zoneFields(zone, in: doc)) }

    private func zoneFields(_ zone: Zone, in doc: Document) -> [String: JSONValue] {
        let geometry = GridGeometry(rect: zone.rect, normalized: doc.grid.normalized(zone.rect, in: doc.canvasSize))
        let range = doc.grid.range(covering: zone.rect, in: doc.canvasSize)
        return [
            "address": .string(ElementInput.zoneAddress),
            "shape": .string(zone.shape.rawValue),
            "rect": .rect(zone.rect),
            "center": .point(geometry.center),
            "corners": .array(geometry.corners.map(JSONValue.point)),
            "normalized": .rect(geometry.normalized),
            "range": .optional(range.map { .string($0.name) }),
            "cells": .optional(range.map { .object(["first": .string($0.first.name), "last": .string($0.last.name)]) }),
        ]
    }

    /// `set_zone`: an agent marks out a region for the person to look at, or
    /// clears it. Not a document change: no revision, no history, no undo.
    /// `zone` is a rect, a grid range, or null; `shape` rectangle|ellipse.
    private func setZone(_ request: CommandRequest) throws -> JSONValue {
        try assertTarget(request, mutation: false)
        let doc = try document
        let params = request.parameters
        let shape = try params.optionalString("shape").map { name -> ZoneShape in
            guard let shape = ZoneShape(rawValue: name) else {
                throw CommandError.invalidArgument("shape must be rectangle or ellipse")
            }
            return shape
        }
        switch params.object["zone"] {
        case nil, .null?:
            controller.zone = nil
            return .object(["zone": .null])
        case .object?:
            guard let rect = try params.optionalRect("zone"), rect.width >= Zone.minimumSide, rect.height >= Zone.minimumSide else {
                throw CommandError.invalidArgument("zone must be at least \(Int(Zone.minimumSide)) pixels each way")
            }
            controller.zone = Zone(rect: rect, shape: shape ?? controller.zone?.shape ?? controller.zoneShape)
        case .string(let address)?:
            let rect = try ElementInput(params: params, document: doc, zone: controller.zone).resolve(address).rect
            controller.zone = Zone(rect: rect, shape: shape ?? controller.zone?.shape ?? controller.zoneShape)
        default:
            throw CommandError.invalidArgument("zone must be a rect, a grid range, or null")
        }
        return .object(["zone": controller.zone.map { zoneJSON($0, in: doc) } ?? .null])
    }

    private func getHistory(_ request: CommandRequest) throws -> JSONValue {
        try assertTarget(request, mutation: false)
        let project = try project
        let limit = try request.parameters.optionalInt("limit") ?? project.history.count
        let entries = project.history.suffix(max(0, limit)).map { entry -> JSONValue in
            .object([
                "id": .string(entry.id.uuidString),
                "actor": .object(["id": .string(entry.actor.id), "name": .string(entry.actor.name)]),
                "timestamp": .string(ISO8601DateFormatter().string(from: entry.timestamp)),
                "revisionBefore": .int(entry.revisionBefore),
                "revisionAfter": .int(entry.revisionAfter),
                "summary": .string(entry.summary),
                "reason": .optional(entry.reason.map(JSONValue.string)),
                "affected": .array(entry.affected.map { .string($0.uuidString) }),
            ])
        }
        return .object(["revision": .int(project.revision), "entries": .array(entries)])
    }

    /// A crop of the untouched base image, whole or by grid range, written
    /// as PNG under Caches. Never the composited layer, never the project.
    private func viewBaseImage(_ request: CommandRequest) throws -> JSONValue {
        try assertTarget(request, mutation: false)
        let project = try project
        let doc = try document
        guard let base = controller.baseImage else { throw CommandError.notFound("no base image") }
        let canvas = CGRect(origin: .zero, size: doc.canvasSize)
        let params = request.parameters
        var requested = canvas
        if let address = try params.optionalString("range") {
            requested = try ElementInput(params: params, document: doc, zone: controller.zone).resolve(address).rect
        }
        let margin = CGFloat(try params.optionalDouble("margin") ?? 0)
        let bounds = requested.insetBy(dx: -margin, dy: -margin).intersection(canvas).integral
        guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1,
              let crop = base.cropping(to: bounds), let png = Renderer.encode(crop, as: .png) else {
            throw CommandError.invalidArgument("the requested region is empty")
        }
        try FileManager.default.createDirectory(at: Self.cropDirectory, withIntermediateDirectories: true)
        let url = Self.cropDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try png.write(to: url)
        return .object([
            "path": .string(url.path),
            "documentId": .string(project.id.uuidString),
            "revision": .int(project.revision),
            "requested": .optional(try params.optionalString("range").map(JSONValue.string)),
            "bounds": .rect(bounds),
            "width": .int(crop.width),
            "height": .int(crop.height),
            "marginAdded": .bool(margin > 0 && bounds != requested.integral),
        ])
    }

    /// Recognizes text locally in the untouched base image. Only strings and
    /// geometry cross the command boundary: no image path or image bytes.
    private func readText(_ request: CommandRequest) throws -> JSONValue {
        try assertTarget(request, mutation: false)
        let project = try project
        let doc = try document
        guard let base = controller.baseImage else { throw CommandError.notFound("no base image") }
        let params = request.parameters
        let requestedAddress = try params.optionalString("range")
        let canvas = CGRect(origin: .zero, size: doc.canvasSize)
        let requested: CGRect
        if let requestedAddress {
            requested = try ElementInput(params: params, document: doc, zone: controller.zone).resolve(requestedAddress).rect
        } else {
            requested = canvas
        }
        let bounds = requested.intersection(canvas).integral
        guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1,
              let crop = base.cropping(to: bounds) else {
            throw CommandError.invalidArgument("the requested region is empty")
        }

        let languages = try stringArray(params, key: "languages")
        let customWords = try stringArray(params, key: "customWords")
        let recognized: [TextRecognitionLine]
        do {
            recognized = try textRecognizer.recognize(in: crop, languages: languages, customWords: customWords)
        } catch {
            throw CommandError.io("text recognition failed: \(error.localizedDescription)")
        }

        let observations = recognized.compactMap { line -> JSONValue? in
            let local = line.bounds.intersection(CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            guard !local.isNull, !local.isEmpty else { return nil }
            let source = local.offsetBy(dx: bounds.minX, dy: bounds.minY)
            let range = doc.grid.range(covering: source, in: doc.canvasSize)
            return .object([
                "text": .string(line.text),
                "confidence": .number(Double(line.confidence)),
                "bounds": .rect(source),
                "normalized": .rect(doc.grid.normalized(source, in: doc.canvasSize)),
                "range": .optional(range.map { .string($0.name) }),
            ])
        }
        return .object([
            "documentId": .string(project.id.uuidString),
            "revision": .int(project.revision),
            "baseImageChecksum": .string(ProjectPackage.sha256Hex(project.baseImagePNG)),
            "requested": .optional(requestedAddress.map(JSONValue.string)),
            "bounds": .rect(bounds),
            "text": .string(recognized.map(\.text).joined(separator: "\n")),
            "observations": .array(observations),
            "languages": .array(languages.map(JSONValue.string)),
            "grid": gridJSON(doc.grid),
        ])
    }

    private func stringArray(_ params: Params, key: String) throws -> [String] {
        try (params.optionalArray(key) ?? []).map { value in
            guard case .string(let string) = value, !string.isEmpty else {
                throw CommandError.invalidArgument("\(key) must contain non-empty strings")
            }
            return string
        }
    }

    // MARK: Mutations

    /// Runs `body` as one attributed commit. The document is only touched
    /// through `controller.perform`, so a thrown error leaves it unchanged.
    private func commit(_ request: CommandRequest, _ body: (inout Document) throws -> JSONValue) throws -> JSONValue {
        try assertTarget(request, mutation: true)
        controller.commitAttribution = (request.actor, request.reason)
        defer { controller.commitAttribution = nil }
        var working = try document
        let result = try body(&working)
        let final = working
        controller.perform { $0 = final }
        var fields: [String: JSONValue] = ["revision": .int(try project.revision)]
        if case .object(let extra) = result { fields.merge(extra) { _, new in new } }
        return .object(fields)
    }

    private func mutate(_ request: CommandRequest) throws -> JSONValue {
        let prepared = try registerImageAsset(request)
        let zone = controller.zone
        return try commit(prepared) { doc in
            try Self.applyMutation(prepared.command, params: prepared.parameters, to: &doc, zone: zone)
        }
    }

    /// `create_element` of type image: the file at `imagePath` joins the
    /// asset store first, and the factory gets `assetId` and `naturalSize`.
    private func registerImageAsset(_ request: CommandRequest) throws -> CommandRequest {
        guard request.command == "create_element", case .object(var params)? = request.params,
              case .string("image")? = params["type"] else { return request }
        guard case .string(let path)? = params["imagePath"], path.hasPrefix("/") else {
            throw CommandError.invalidArgument("image needs imagePath, an absolute path to a PNG or JPEG")
        }
        guard let data = FileManager.default.contents(atPath: path), let image = ImageLoader.cgImage(from: data),
              let png = Renderer.encode(image, as: .png) else {
            throw CommandError.io("\(path) is not an image Masume can read")
        }
        let assetID = try project.registerAsset(png: png, image: image)
        params["assetId"] = .string(assetID.uuidString)
        params["naturalSize"] = .size(CGSize(width: image.width, height: image.height))
        var prepared = request
        prepared.params = .object(params)
        return prepared
    }

    /// The mutation vocabulary, shared by single commands and `batch`. The
    /// zone, if drawn, is what the address `zone` resolves to.
    static func applyMutation(_ command: String, params: Params, to doc: inout Document, zone: Zone? = nil) throws -> JSONValue {
        switch command {
        case "create_element":
            let element = try ElementFactory.make(ElementInput(params: params, document: doc, zone: zone))
            doc.add(element)
            return .object(["element": ElementJSON.json(element)])
        case "update_element":
            let id = try params.string("id")
            guard let i = doc.elements.firstIndex(where: { $0.id.uuidString.lowercased() == id.lowercased() }) else {
                throw CommandError.notFound("no element \(id)")
            }
            var element = doc.elements[i]
            try ElementFactory.apply(ElementInput(params: params, document: doc, zone: zone), to: &element)
            doc.elements[i] = element
            try applyZOrder(try params.optionalString("zOrder"), of: element.id, in: &doc)
            return .object(["element": ElementJSON.json(element)])
        case "delete_elements":
            return try deleteElements(params, from: &doc)
        case "set_crop":
            return try setCrop(params, in: &doc, zone: zone)
        case "set_grid_density":
            return try setGridDensity(params, in: &doc)
        case "batch":
            return try batch(params, in: &doc, zone: zone)
        default:
            throw CommandError.unsupported("\(command) is not a mutation")
        }
    }

    private static func applyZOrder(_ order: String?, of id: ElementID, in doc: inout Document) throws {
        switch order {
        case nil: return
        case "front": doc.bringToFront(id)
        case "back":
            guard let i = doc.index(of: id) else { return }
            let element = doc.elements.remove(at: i)
            doc.elements.insert(element, at: 0)
        default: throw CommandError.invalidArgument("zOrder must be front or back")
        }
    }

    private static func deleteElements(_ params: Params, from doc: inout Document) throws -> JSONValue {
        guard let ids = try params.optionalArray("ids"), !ids.isEmpty else {
            throw CommandError.invalidArgument("ids is required")
        }
        var deleted: [String] = []
        for value in ids {
            guard case .string(let id) = value else { throw CommandError.invalidArgument("ids must be strings") }
            guard let element = doc.elements.first(where: { $0.id.uuidString.lowercased() == id.lowercased() }) else {
                throw CommandError.notFound("no element \(id)")
            }
            doc.remove(element.id)
            deleted.append(element.id.uuidString)
        }
        return .object(["deleted": .array(deleted.map(JSONValue.string))])
    }

    /// `crop` is a rect, a grid range, or null to clear.
    private static func setCrop(_ params: Params, in doc: inout Document, zone: Zone?) throws -> JSONValue {
        guard params.has("crop") else {
            doc.crop = nil
            return .object(["crop": .null])
        }
        let requested: CGRect
        switch params.object["crop"] {
        case .object?: requested = try params.optionalRect("crop") ?? .zero
        case .string(let address)?:
            requested = try ElementInput(params: params, document: doc, zone: zone).resolve(address).rect
        default: throw CommandError.invalidArgument("crop must be a rect, a grid range, or null")
        }
        guard let clamped = doc.clampedCrop(requested) else {
            throw CommandError.invalidArgument("crop must lie on the image and be at least 2 pixels each way")
        }
        doc.crop = clamped
        return .object(["crop": .rect(clamped)])
    }

    private static func setGridDensity(_ params: Params, in doc: inout Document) throws -> JSONValue {
        guard let n = try params.optionalInt("cellsAcrossLongSide"), GridDefinition.presets.contains(n) else {
            throw CommandError.invalidArgument("cellsAcrossLongSide must be one of \(GridDefinition.presets)")
        }
        let next = GridDefinition.preset(n, for: doc.canvasSize, version: doc.grid.version + 1)
        if next.columns != doc.grid.columns || next.rows != doc.grid.rows { doc.grid = next }
        return .object(["grid": .object(["columns": .int(doc.grid.columns), "rows": .int(doc.grid.rows),
                                         "version": .int(doc.grid.version)])])
    }

    /// All-or-nothing: the commands run against a copy, and the copy only
    /// becomes the document when every one succeeded. A failure reports the
    /// index of the command that failed.
    private static func batch(_ params: Params, in doc: inout Document, zone: Zone?) throws -> JSONValue {
        guard let commands = try params.optionalArray("commands"), !commands.isEmpty else {
            throw CommandError.invalidArgument("commands is required")
        }
        var working = doc
        var results: [JSONValue] = []
        for (index, item) in commands.enumerated() {
            guard case .object(let object) = item, case .string(let name)? = object["command"], name != "batch" else {
                throw CommandError.invalidArgument("commands[\(index)] must be {command, params}")
            }
            let inner = Params(object).optionalObjectOrEmpty("params")
            do {
                results.append(try applyMutation(name, params: inner, to: &working, zone: zone))
            } catch {
                let wrapped = CommandError.wrap(error)
                throw CommandError(code: wrapped.code, message: "commands[\(index)] \(name): \(wrapped.message)")
            }
        }
        doc = working
        return .object(["results": .array(results)])
    }

    // MARK: Undo, redo, save, export

    private func undoRedo(_ request: CommandRequest) throws -> JSONValue {
        try assertTarget(request, mutation: true)
        let undo = request.command == "undo"
        guard undo ? controller.canUndo : controller.canRedo else {
            throw CommandError.invalidArgument("nothing to \(request.command)")
        }
        controller.commitAttribution = (request.actor, request.reason)
        defer { controller.commitAttribution = nil }
        if undo { controller.undo() } else { controller.redo() }
        let project = try project
        return .object(["revision": .int(project.revision),
                        "summary": .optional(project.history.last.map { .string($0.summary) })])
    }

    private func saveProject(_ request: CommandRequest) throws -> JSONValue {
        try assertTarget(request, mutation: false)
        let project = try project
        let path = try request.parameters.optionalString("path")
        guard let url = path.map({ URL(fileURLWithPath: $0) }) ?? project.projectURL else {
            throw CommandError.invalidArgument("path is required for a project that has never been saved")
        }
        guard url.path.hasPrefix("/") else { throw CommandError.invalidArgument("path must be absolute") }
        try controller.saveProject(to: url, newIdentity: false)
        return .object(["path": .string(url.path), "revision": .int(project.revision),
                        "containsOriginalImage": .bool(true)])
    }

    private func export(_ request: CommandRequest) throws -> JSONValue {
        try assertTarget(request, mutation: false)
        let params = request.parameters
        let path = try params.string("path")
        guard path.hasPrefix("/") else { throw CommandError.invalidArgument("path must be absolute") }
        let url = URL(fileURLWithPath: path)
        let formatName = try params.optionalString("format") ?? url.pathExtension.lowercased()
        guard let format = ExportFormat(rawValue: formatName == "jpg" ? "jpeg" : formatName) else {
            throw CommandError.invalidArgument("format must be png, jpeg, or webp")
        }
        let bounds = try params.optionalString("bounds").map { name -> ExportBounds in
            guard let bounds = ExportBounds(rawValue: name) else {
                throw CommandError.invalidArgument("bounds must be expandToFit or clipToImage")
            }
            return bounds
        }
        let size = try ExportService.write(controller, to: url, as: format, bounds: bounds)
        return .object(["path": .string(url.path), "format": .string(format.rawValue),
                        "width": .int(size.width), "height": .int(size.height)])
    }
}

extension Params {
    func optionalObjectOrEmpty(_ key: String) -> Params {
        (try? optionalObject(key)) ?? Params([:])
    }
}
