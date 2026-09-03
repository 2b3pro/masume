import Foundation
import CoreGraphics
import AnnotationModel

/// Error codes shared by every surface (MCP, CLI, AppleScript). The CLI maps
/// them to exit codes; MCP returns them in the tool result.
public enum CommandErrorCode: String, Codable, Sendable {
    case conflict
    case notFound = "not_found"
    case invalidAddress = "invalid_address"
    case invalidArgument = "invalid_argument"
    case unsupported
    case io
}

public struct CommandError: Error, Equatable, Sendable {
    public let code: CommandErrorCode
    public let message: String

    public init(code: CommandErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public static func conflict(_ message: String) -> CommandError { CommandError(code: .conflict, message: message) }
    public static func notFound(_ message: String) -> CommandError { CommandError(code: .notFound, message: message) }
    public static func invalidAddress(_ message: String) -> CommandError { CommandError(code: .invalidAddress, message: message) }
    public static func invalidArgument(_ message: String) -> CommandError { CommandError(code: .invalidArgument, message: message) }
    public static func unsupported(_ message: String) -> CommandError { CommandError(code: .unsupported, message: message) }
    public static func io(_ message: String) -> CommandError { CommandError(code: .io, message: message) }

    /// Any thrown error as a command error: grid errors are addresses,
    /// project errors are io, everything else is io with its description.
    public static func wrap(_ error: Error) -> CommandError {
        switch error {
        case let e as CommandError: return e
        case let e as GridError: return .invalidAddress(e.localizedDescription)
        case let e as ProjectError: return .io(e.localizedDescription)
        default: return .io(error.localizedDescription)
        }
    }
}

/// One call, as JSON: `{"command", "documentId"?, "expectedRevision"?,
/// "actorId"?, "actorName"?, "reason"?, "params"?: {...}}`.
public struct CommandRequest: Decodable {
    public var command: String
    public var documentId: String?
    public var expectedRevision: Int?
    public var actorId: String?
    public var actorName: String?
    public var reason: String?
    public var params: JSONValue?

    public var parameters: Params {
        if case .object(let o)? = params { return Params(o) }
        return Params([:])
    }

    /// Who this call acts as. Absent actor fields mean an unnamed agent.
    public var actor: HistoryActor {
        let id = actorId ?? "agent"
        return HistoryActor(id: id, name: actorName ?? (actorId.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Agent"))
    }
}

/// Typed access to a command's `params` object, throwing `invalid_argument`
/// with the key's name when a value is missing or the wrong shape.
public struct Params {
    public let object: [String: JSONValue]

    public init(_ object: [String: JSONValue]) { self.object = object }

    public func has(_ key: String) -> Bool {
        if case .null? = object[key] { return false }
        return object[key] != nil
    }

    public func string(_ key: String) throws -> String {
        guard let value = try optionalString(key) else { throw CommandError.invalidArgument("\(key) is required") }
        return value
    }

    public func optionalString(_ key: String) throws -> String? {
        switch object[key] {
        case nil, .null?: return nil
        case .string(let s)?: return s
        default: throw CommandError.invalidArgument("\(key) must be a string")
        }
    }

    public func optionalDouble(_ key: String) throws -> Double? {
        switch object[key] {
        case nil, .null?: return nil
        case .number(let n)?: return n
        default: throw CommandError.invalidArgument("\(key) must be a number")
        }
    }

    public func double(_ key: String) throws -> Double {
        guard let value = try optionalDouble(key) else { throw CommandError.invalidArgument("\(key) is required") }
        return value
    }

    public func optionalInt(_ key: String) throws -> Int? {
        guard let value = try optionalDouble(key) else { return nil }
        guard value == value.rounded() else { throw CommandError.invalidArgument("\(key) must be a whole number") }
        return Int(value)
    }

    public func optionalBool(_ key: String) throws -> Bool? {
        switch object[key] {
        case nil, .null?: return nil
        case .bool(let b)?: return b
        default: throw CommandError.invalidArgument("\(key) must be true or false")
        }
    }

    public func optionalArray(_ key: String) throws -> [JSONValue]? {
        switch object[key] {
        case nil, .null?: return nil
        case .array(let a)?: return a
        default: throw CommandError.invalidArgument("\(key) must be an array")
        }
    }

    public func optionalObject(_ key: String) throws -> Params? {
        switch object[key] {
        case nil, .null?: return nil
        case .object(let o)?: return Params(o)
        default: throw CommandError.invalidArgument("\(key) must be an object")
        }
    }

    /// `{"x": …, "y": …}`.
    public func optionalPoint(_ key: String) throws -> CGPoint? {
        guard let p = try optionalObject(key) else { return nil }
        return CGPoint(x: try p.double("x"), y: try p.double("y"))
    }

    /// `{"x", "y", "width", "height"}`.
    public func optionalRect(_ key: String) throws -> CGRect? {
        guard let r = try optionalObject(key) else { return nil }
        return CGRect(x: try r.double("x"), y: try r.double("y"), width: try r.double("width"), height: try r.double("height"))
    }

    public func optionalPoints(_ key: String) throws -> [CGPoint]? {
        guard let array = try optionalArray(key) else { return nil }
        return try array.map { item in
            guard case .object(let o) = item else { throw CommandError.invalidArgument("\(key) must hold {x, y} points") }
            let p = Params(o)
            return CGPoint(x: try p.double("x"), y: try p.double("y"))
        }
    }
}

// MARK: - Results

extension JSONValue {
    public static func int(_ value: Int) -> JSONValue { .number(Double(value)) }
    public static func point(_ p: CGPoint) -> JSONValue { .object(["x": .number(p.x), "y": .number(p.y)]) }
    public static func size(_ s: CGSize) -> JSONValue { .object(["width": .number(s.width), "height": .number(s.height)]) }
    public static func rect(_ r: CGRect) -> JSONValue {
        .object(["x": .number(r.minX), "y": .number(r.minY), "width": .number(r.width), "height": .number(r.height)])
    }
    public static func optional(_ value: JSONValue?) -> JSONValue { value ?? .null }
}

/// `{"ok": true, "result": …}` or `{"ok": false, "error": {"code", "message"}}`.
public enum CommandResponse: Equatable {
    case success(JSONValue)
    case failure(CommandError)

    public var json: JSONValue {
        switch self {
        case .success(let result):
            return .object(["ok": .bool(true), "result": result])
        case .failure(let error):
            return .object(["ok": .bool(false),
                            "error": .object(["code": .string(error.code.rawValue), "message": .string(error.message)])])
        }
    }

    public func encoded(pretty: Bool = false) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(json)) ?? Data("{\"ok\":false,\"error\":{\"code\":\"io\",\"message\":\"encoding failed\"}}".utf8)
    }
}
