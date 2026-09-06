import Foundation
import MasumeCommands

/// Turns a live subcommand and its arguments into the request JSON the
/// command service takes. A strict mirror: every subcommand is one command
/// name plus its params, with nothing added on the way. The MCP server
/// builds the same objects, and a table test checks the two agree.
public enum CLIRequest {
    /// Subcommands that change the document and so need documentId and
    /// expectedRevision.
    public static let mutations: Set<String> = ["add", "update", "delete", "crop", "density", "text-preferences", "undo", "redo", "batch"]

    public struct Options: Equatable {
        public var documentId: String?
        public var expectedRevision: Int?
        public var actorId: String?
        public var actorName: String?
        public var reason: String?

        public init(documentId: String? = nil, expectedRevision: Int? = nil, actorId: String? = nil,
                    actorName: String? = nil, reason: String? = nil) {
            self.documentId = documentId; self.expectedRevision = expectedRevision
            self.actorId = actorId; self.actorName = actorName; self.reason = reason
        }
    }

    /// The command name and params for a subcommand; `flags` are the
    /// subcommand's own `--name value` options.
    public static func build(_ subcommand: String, arguments: [String], flags: [String: String],
                             options: Options) throws -> [String: Any] {
        let (command, params) = try commandAndParams(subcommand, arguments: arguments, flags: flags)
        var request: [String: Any] = ["command": command, "params": params]
        if let id = options.documentId { request["documentId"] = id }
        if let revision = options.expectedRevision { request["expectedRevision"] = revision }
        if let actor = options.actorId { request["actorId"] = actor }
        if let name = options.actorName { request["actorName"] = name }
        if let reason = options.reason { request["reason"] = reason }
        return request
    }

    private static func commandAndParams(_ subcommand: String, arguments: [String],
                                         flags: [String: String]) throws -> (String, [String: Any]) {
        if subcommand == "text-preferences" {
            guard arguments.isEmpty else { throw CLIError.usage("text-preferences [--languages en-US] [--custom-words Shen]") }
            var params: [String: Any] = [:]
            for (flag, key) in [("languages", "languages"), ("custom-words", "customWords")] {
                if let value = flags[flag] { params[key] = value.isEmpty ? [] : try commaSeparated(value, flag: "--\(flag)") }
            }
            return ("set_text_preferences", params)
        }
        if let read = try readCommand(subcommand, arguments: arguments, flags: flags) { return read }
        if let mutation = try mutationCommand(subcommand, arguments: arguments) { return mutation }
        if let file = try fileCommand(subcommand, arguments: arguments, flags: flags) { return file }
        throw CLIError.usage("unknown subcommand \(subcommand)")
    }

    private static func readCommand(_ subcommand: String, arguments: [String],
                                    flags: [String: String]) throws -> (String, [String: Any])? {
        switch subcommand {
        case "guide": return ("guide", [:])
        case "doc": return ("get_active_document", [:])
        case "elements": return ("list_elements", [:])
        case "element": return ("get_element", ["id": try one(arguments, "element <id>")])
        case "resolve": return ("resolve_grid", ["address": try one(arguments, "resolve <address>")])
        case "view": return ("view_base_image", try viewParams(arguments, flags: flags))
        case "read-text": return ("read_text", try readTextParams(arguments, flags: flags))
        case "zone": return ("set_zone", try zoneParams(arguments, flags: flags))
        case "history":
            var params: [String: Any] = [:]
            if let limit = flags["limit"] { params["limit"] = try number(limit, "--limit") }
            return ("get_history", params)
        default: return nil
        }
    }

    private static func mutationCommand(_ subcommand: String, arguments: [String]) throws -> (String, [String: Any])? {
        switch subcommand {
        case "add":
            guard let type = arguments.first else { throw CLIError.usage("add <type> [key=value ...]") }
            var params = try keyValues(Array(arguments.dropFirst()))
            params["type"] = type
            return ("create_element", params)
        case "update":
            guard let id = arguments.first else { throw CLIError.usage("update <id> [key=value ...]") }
            var params = try keyValues(Array(arguments.dropFirst()))
            params["id"] = id
            return ("update_element", params)
        case "delete":
            guard !arguments.isEmpty else { throw CLIError.usage("delete <id> [<id> ...]") }
            return ("delete_elements", ["ids": arguments])
        case "crop": return ("set_crop", ["crop": try cropValue(try one(arguments, "crop <range|x,y,w,h|none>"))])
        case "density":
            return ("set_grid_density", ["cellsAcrossLongSide": try number(try one(arguments, "density <n>"), "density")])
        case "undo", "redo": return (subcommand, [:])
        default: return nil
        }
    }

    private static func fileCommand(_ subcommand: String, arguments: [String],
                                    flags: [String: String]) throws -> (String, [String: Any])? {
        switch subcommand {
        case "save":
            var params: [String: Any] = [:]
            if let path = arguments.first { params["path"] = absolute(path) }
            return ("save_project", params)
        case "export":
            var params: [String: Any] = ["path": absolute(try one(arguments, "export <path>"))]
            if let format = flags["format"] { params["format"] = format }
            if let bounds = flags["bounds"] { params["bounds"] = bounds }
            return ("export", params)
        default: return nil
        }
    }

    private static func one(_ arguments: [String], _ usage: String) throws -> String {
        guard let first = arguments.first else { throw CLIError.usage(usage) }
        return first
    }

    private static func number(_ text: String, _ what: String) throws -> Any {
        guard let value = Double(text) else { throw CLIError.usage("\(what) must be a number, not \(text)") }
        return value == value.rounded() ? Int(value) : value
    }

    private static func viewParams(_ arguments: [String], flags: [String: String]) throws -> [String: Any] {
        var params: [String: Any] = [:]
        if let range = arguments.first { params["range"] = range }
        if let margin = flags["margin"] { params["margin"] = try number(margin, "--margin") }
        return params
    }

    private static func readTextParams(_ arguments: [String], flags: [String: String]) throws -> [String: Any] {
        guard arguments.count <= 1 else {
            throw CLIError.usage("read-text [range] [--languages en-US,fr-FR] [--custom-words Shen,Masume]")
        }
        var params: [String: Any] = [:]
        if let range = arguments.first { params["range"] = range }
        if let value = flags["languages"] { params["languages"] = try commaSeparated(value, flag: "--languages") }
        if let value = flags["custom-words"] { params["customWords"] = try commaSeparated(value, flag: "--custom-words") }
        return params
    }

    private static func commaSeparated(_ value: String, flag: String) throws -> [String] {
        let values = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !values.isEmpty, values.allSatisfy({ !$0.isEmpty }) else {
            throw CLIError.usage("\(flag) must be a comma-separated list")
        }
        return values
    }

    private static func zoneParams(_ arguments: [String], flags: [String: String]) throws -> [String: Any] {
        var params: [String: Any] = [
            "zone": try cropValue(try one(arguments, "zone <range|x,y,w,h|none> [--shape rectangle|ellipse]")),
        ]
        if let shape = flags["shape"] { params["shape"] = shape }
        return params
    }

    static func absolute(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func cropValue(_ text: String) throws -> Any {
        if text.lowercased() == "none" { return NSNull() }
        let parts = text.split(separator: ",")
        if parts.count == 4, let numbers = Optional(parts.compactMap { Double($0) }), numbers.count == 4 {
            return ["x": numbers[0], "y": numbers[1], "width": numbers[2], "height": numbers[3]]
        }
        return text
    }

    /// `key=value` pairs. Values: numbers become numbers, `true`/`false`
    /// booleans, `x,y` a point, `x,y,w,h` a rect, `x,y;x,y;…` points, and
    /// anything else a string (grid addresses, colors, text).
    public static func keyValues(_ pairs: [String]) throws -> [String: Any] {
        var params: [String: Any] = [:]
        for pair in pairs {
            guard let eq = pair.firstIndex(of: "=") else { throw CLIError.usage("expected key=value, got \(pair)") }
            let key = String(pair[..<eq])
            let value = String(pair[pair.index(after: eq)...])
            params[key] = parse(value)
        }
        return params
    }

    static func parse(_ value: String) -> Any {
        if let n = Double(value) { return n == n.rounded() && !value.contains(".") ? Int(n) : n }
        if value == "true" { return true }
        if value == "false" { return false }
        if value.contains(";") {
            let points = value.split(separator: ";").compactMap { pointValue(String($0)) }
            if !points.isEmpty { return points }
        }
        let numbers = value.split(separator: ",").compactMap { Double($0) }
        if numbers.count == 2, value.split(separator: ",").count == 2 { return ["x": numbers[0], "y": numbers[1]] }
        if numbers.count == 4, value.split(separator: ",").count == 4 {
            return ["x": numbers[0], "y": numbers[1], "width": numbers[2], "height": numbers[3]]
        }
        return value
    }

    private static func pointValue(_ text: String) -> [String: Double]? {
        let numbers = text.split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 2 else { return nil }
        return ["x": numbers[0], "y": numbers[1]]
    }
}

public enum CLIError: Error, Equatable {
    /// A mistake on the command line: printed to stderr, exit 64.
    case usage(String)
    /// Help the user asked for: printed to stdout, exit 0.
    case help(String)
    case notRunning
}
