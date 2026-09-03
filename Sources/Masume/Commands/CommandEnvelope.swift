import Foundation
import CoreGraphics
import AnnotationModel

/// Error codes shared by every surface (MCP, CLI, AppleScript). The CLI maps
/// them to exit codes; MCP returns them in the tool result.
enum CommandErrorCode: String, Codable, Sendable {
    case conflict
    case notFound = "not_found"
    case invalidAddress = "invalid_address"
    case invalidArgument = "invalid_argument"
    case unsupported
    case io
}

struct CommandError: Error, Equatable, Sendable {
    let code: CommandErrorCode
    let message: String

    static func conflict(_ message: String) -> CommandError { CommandError(code: .conflict, message: message) }
    static func notFound(_ message: String) -> CommandError { CommandError(code: .notFound, message: message) }
    static func invalidAddress(_ message: String) -> CommandError { CommandError(code: .invalidAddress, message: message) }
    static func invalidArgument(_ message: String) -> CommandError { CommandError(code: .invalidArgument, message: message) }
    static func unsupported(_ message: String) -> CommandError { CommandError(code: .unsupported, message: message) }
    static func io(_ message: String) -> CommandError { CommandError(code: .io, message: message) }

    /// Any thrown error as a command error: grid errors are addresses,
    /// project errors are io, everything else is io with its description.
    static func wrap(_ error: Error) -> CommandError {
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
struct CommandRequest: Decodable {
    var command: String
    var documentId: String?
    var expectedRevision: Int?
    var actorId: String?
    var actorName: String?
    var reason: String?
    var params: JSONValue?

    var parameters: Params {
        if case .object(let o)? = params { return Params(o) }
        return Params([:])
    }

    /// Who this call acts as. Absent actor fields mean an unnamed agent.
    var actor: HistoryActor {
        let id = actorId ?? "agent"
        return HistoryActor(id: id, name: actorName ?? (actorId.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Agent"))
    }
}

/// Typed access to a command's `params` object, throwing `invalid_argument`
/// with the key's name when a value is missing or the wrong shape.
struct Params {
    let object: [String: JSONValue]

    init(_ object: [String: JSONValue]) { self.object = object }

    func has(_ key: String) -> Bool {
        if case .null? = object[key] { return false }
        return object[key] != nil
    }

    func string(_ key: String) throws -> String {
        guard let value = try optionalString(key) else { throw CommandError.invalidArgument("\(key) is required") }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        switch object[key] {
        case nil, .null?: return nil
        case .string(let s)?: return s
        default: throw CommandError.invalidArgument("\(key) must be a string")
        }
    }

    func optionalDouble(_ key: String) throws -> Double? {
        switch object[key] {
        case nil, .null?: return nil
        case .number(let n)?: return n
        default: throw CommandError.invalidArgument("\(key) must be a number")
        }
    }

    func double(_ key: String) throws -> Double {
        guard let value = try optionalDouble(key) else { throw CommandError.invalidArgument("\(key) is required") }
        return value
    }

    func optionalInt(_ key: String) throws -> Int? {
        guard let value = try optionalDouble(key) else { return nil }
        guard value == value.rounded() else { throw CommandError.invalidArgument("\(key) must be a whole number") }
        return Int(value)
    }

    func optionalBool(_ key: String) throws -> Bool? {
        switch object[key] {
        case nil, .null?: return nil
        case .bool(let b)?: return b
        default: throw CommandError.invalidArgument("\(key) must be true or false")
        }
    }

    func optionalArray(_ key: String) throws -> [JSONValue]? {
        switch object[key] {
        case nil, .null?: return nil
        case .array(let a)?: return a
        default: throw CommandError.invalidArgument("\(key) must be an array")
        }
    }

    func optionalObject(_ key: String) throws -> Params? {
        switch object[key] {
        case nil, .null?: return nil
        case .object(let o)?: return Params(o)
        default: throw CommandError.invalidArgument("\(key) must be an object")
        }
    }

    /// `{"x": …, "y": …}`.
    func optionalPoint(_ key: String) throws -> CGPoint? {
        guard let p = try optionalObject(key) else { return nil }
        return CGPoint(x: try p.double("x"), y: try p.double("y"))
    }

    /// `{"x", "y", "width", "height"}`.
    func optionalRect(_ key: String) throws -> CGRect? {
        guard let r = try optionalObject(key) else { return nil }
        return CGRect(x: try r.double("x"), y: try r.double("y"), width: try r.double("width"), height: try r.double("height"))
    }

    func optionalPoints(_ key: String) throws -> [CGPoint]? {
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
    static func int(_ value: Int) -> JSONValue { .number(Double(value)) }
    static func point(_ p: CGPoint) -> JSONValue { .object(["x": .number(p.x), "y": .number(p.y)]) }
    static func size(_ s: CGSize) -> JSONValue { .object(["width": .number(s.width), "height": .number(s.height)]) }
    static func rect(_ r: CGRect) -> JSONValue {
        .object(["x": .number(r.minX), "y": .number(r.minY), "width": .number(r.width), "height": .number(r.height)])
    }
    static func optional(_ value: JSONValue?) -> JSONValue { value ?? .null }
}

/// `{"ok": true, "result": …}` or `{"ok": false, "error": {"code", "message"}}`.
enum CommandResponse: Equatable {
    case success(JSONValue)
    case failure(CommandError)

    var json: JSONValue {
        switch self {
        case .success(let result):
            return .object(["ok": .bool(true), "result": result])
        case .failure(let error):
            return .object(["ok": .bool(false),
                            "error": .object(["code": .string(error.code.rawValue), "message": .string(error.message)])])
        }
    }

    func encoded(pretty: Bool = false) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return (try? encoder.encode(json)) ?? Data("{\"ok\":false,\"error\":{\"code\":\"io\",\"message\":\"encoding failed\"}}".utf8)
    }
}
