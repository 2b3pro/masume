import Foundation
import AnnotationModel
import MasumeCommands

/// The `masume` command-line tool. Offline subcommands work on files through
/// the libraries; live ones send one Apple Event each to the running app.
/// Output is the JSON envelope on stdout; the exit status mirrors the
/// envelope's error code so shell scripts can branch without parsing.
public enum MasumeCLI {
    public static let usage = """
        usage: masume <subcommand> [arguments] [options]

        Live (Masume must be running; each is one Apple Event):
          doc                         the active document: id, revision, canvas, grid
          elements                    every annotation
          element <id>                one annotation
          resolve <address>           D5, D5.3 (quadrant), or D5:F14 to pixels, center, corners, normalized
          view [range] --out <png>    crop of the untouched base image [--margin px]
          read-text [range]           local OCR of the base image or "zone" [--languages en-US,fr-FR]
          text-preferences            save OCR defaults [--languages en-US] [--custom-words Shen,Masume]
          history [--limit n]         committed actions, oldest first
          add <type> key=value ...    create: from=B3 to=D6 | over=D5:F14 | at=C3 | text=... color=...
          update <id> key=value ...   change the given keys only (zOrder=front|back)
          delete <id> ...             remove annotations
          crop <range|x,y,w,h|none>   the non-destructive crop (a range may be "zone")
          zone <range|x,y,w,h|none>   mark a region for the person to look at [--shape ellipse]
          density <n>                 grid preset: 8, 12, 16, 24, or 32 cells across
          undo | redo                 one step of the shared history
          save [path]                 write the project (path required the first time)
          export <path> [--format png|jpeg|webp] [--bounds expandToFit|clipToImage]
          exec '<json>'               any command by name
          guide                       the full command vocabulary for agents

        Offline (no app needed):
          info <file.masume>
          export <file.masume> <out> [--format ...] [--bounds ...]
          resolve --file <file.masume> <address>
          new <image-or-pdf> <file.masume> [--page n]

        Options: --doc <id> --revision <n> --actor <id> --actor-name <name> --reason <text> --pretty
        Exit: 0 ok, 2 conflict, 3 not_found, 4 invalid_address, 5 invalid_argument,
              6 unsupported, 7 io, 10 Masume not running, 64 usage
        Help: masume help <subcommand> (or <subcommand> --help); "help add" lists every element key
        """

    public static let notRunningExit: Int32 = 10
    public static let usageExit: Int32 = 64

    public static func exitCode(for code: CommandErrorCode) -> Int32 {
        switch code {
        case .conflict: return 2
        case .notFound: return 3
        case .invalidAddress: return 4
        case .invalidArgument: return 5
        case .unsupported: return 6
        case .io: return 7
        }
    }

    /// Parsed command line: subcommand, its positional arguments, `--name
    /// value` flags, and the global options.
    public struct Invocation: Equatable {
        public var subcommand: String
        public var arguments: [String] = []
        public var flags: [String: String] = [:]
        public var pretty = false
        public var options = CLIRequest.Options()
    }

    static let valueFlags: Set<String> = [
        "doc", "revision", "actor", "actor-name", "reason", "out", "margin", "limit", "format", "bounds", "page", "file", "shape",
        "languages", "custom-words",
    ]

    static let helpWords: Set<String> = ["-h", "--help", "help"]

    public static func parse(_ arguments: [String]) throws -> Invocation {
        guard let first = arguments.first else { throw CLIError.usage(usage) }
        if helpWords.contains(first.lowercased()) {
            guard let topic = arguments.dropFirst().first else { throw CLIError.help(usage) }
            throw try helpError(for: topic)
        }
        if arguments.dropFirst().contains(where: { $0 == "-h" || $0 == "--help" }) {
            throw try helpError(for: first)
        }
        var invocation = Invocation(subcommand: first)
        var rest = arguments.dropFirst()[...]
        while let item = rest.popFirst() {
            guard item.hasPrefix("--") else { invocation.arguments.append(item); continue }
            let name = String(item.dropFirst(2))
            if name == "pretty" { invocation.pretty = true; continue }
            guard valueFlags.contains(name), let value = rest.popFirst() else {
                throw CLIError.usage("unknown or incomplete option \(item)")
            }
            try apply(option: name, value: value, to: &invocation)
        }
        return invocation
    }

    /// `help <topic>`: the topic's text, or a usage error naming it.
    private static func helpError(for topic: String) throws -> CLIError {
        guard let text = help(for: topic) else { throw CLIError.usage("no help for \(topic)\n\n\(usage)") }
        return .help(text)
    }

    private static func apply(option name: String, value: String, to invocation: inout Invocation) throws {
        switch name {
        case "doc": invocation.options.documentId = value
        case "revision":
            guard let n = Int(value) else { throw CLIError.usage("--revision must be an integer") }
            invocation.options.expectedRevision = n
        case "actor": invocation.options.actorId = value
        case "actor-name": invocation.options.actorName = value
        case "reason": invocation.options.reason = value
        default: invocation.flags[name] = value
        }
    }

    // MARK: Run

    /// The process entry point: prints and returns the exit status.
    public static func run(_ arguments: [String], output: (String) -> Void = { print($0) },
                           error: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
                           transport: (Data) throws -> Data = { try AppleEventClient.execute($0) }) -> Int32 {
        do {
            let invocation = try parse(arguments)
            let response = try perform(invocation, transport: transport, note: error)
            output(String(data: response.encoded(pretty: invocation.pretty), encoding: .utf8) ?? "")
            switch response {
            case .success: return 0
            case .failure(let failure): return exitCode(for: failure.code)
            }
        } catch CLIError.usage(let message) {
            error(message)
            return usageExit
        } catch CLIError.help(let text) {
            output(text)
            return 0
        } catch {
            output(String(data: AppleEventClient.envelope(code: "io", message: "Masume is not running"), encoding: .utf8) ?? "")
            return notRunningExit
        }
    }

    static func perform(_ invocation: Invocation, transport: (Data) throws -> Data,
                        note: (String) -> Void) throws -> CommandResponse {
        if let offline = try offline(invocation) { return offline }
        if invocation.subcommand == "exec" { return try exec(invocation, transport: transport) }
        var options = invocation.options
        // Validate the subcommand's own arguments before touching the app, so
        // a usage mistake never costs a round trip or a stale-looking error.
        _ = try CLIRequest.build(invocation.subcommand, arguments: invocation.arguments,
                                 flags: invocation.flags, options: options)
        if CLIRequest.mutations.contains(invocation.subcommand),
           options.documentId == nil || options.expectedRevision == nil {
            // Default to the active document as it is right now, and say so.
            let summary = try send(["command": "get_active_document"], transport: transport)
            guard case .success(.object(let doc)) = summary,
                  case .string(let id)? = doc["id"], case .number(let revision)? = doc["revision"] else {
                return summary
            }
            options.documentId = options.documentId ?? id
            options.expectedRevision = options.expectedRevision ?? Int(revision)
            note("using document \(options.documentId ?? "") at revision \(options.expectedRevision ?? 0)")
        }
        let request = try CLIRequest.build(invocation.subcommand, arguments: invocation.arguments,
                                           flags: invocation.flags, options: options)
        let response = try send(request, transport: transport)
        if invocation.subcommand == "view", let out = invocation.flags["out"] {
            return try moveCrop(response, to: out)
        }
        return response
    }

    private static func offline(_ invocation: Invocation) throws -> CommandResponse? {
        let args = invocation.arguments
        switch invocation.subcommand {
        case "info":
            guard args.count == 1 else { throw CLIError.usage("info <file.masume>") }
            return OfflineCommands.info(args[0])
        case "export" where args.count == 2 && args[0].hasSuffix(".masume"):
            return OfflineCommands.export(args[0], to: args[1], format: invocation.flags["format"],
                                          bounds: invocation.flags["bounds"])
        case "resolve" where invocation.flags["file"] != nil:
            guard args.count == 1 else { throw CLIError.usage("resolve --file <file.masume> <address>") }
            return OfflineCommands.resolve(args[0], file: invocation.flags["file"] ?? "")
        case "new":
            guard args.count == 2 else { throw CLIError.usage("new <image-or-pdf> <file.masume> [--page n]") }
            let page = try invocation.flags["page"].map { text -> Int in
                guard let n = Int(text) else { throw CLIError.usage("--page must be an integer") }
                return n
            }
            return OfflineCommands.new(from: args[0], to: args[1], page: page)
        default:
            return nil
        }
    }

    private static func exec(_ invocation: Invocation, transport: (Data) throws -> Data) throws -> CommandResponse {
        guard let json = invocation.arguments.first, let data = json.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError.usage("exec '<json object>'")
        }
        let options = invocation.options
        if let id = options.documentId { object["documentId"] = id }
        if let revision = options.expectedRevision { object["expectedRevision"] = revision }
        if let actor = options.actorId { object["actorId"] = actor }
        if let name = options.actorName { object["actorName"] = name }
        if let reason = options.reason { object["reason"] = reason }
        return try send(object, transport: transport)
    }

    static func send(_ request: [String: Any], transport: (Data) throws -> Data) throws -> CommandResponse {
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let reply = try transport(data)
        return decode(reply)
    }

    /// The app's envelope, re-read into the shared response type so the CLI
    /// prints and exits the same way for live and offline results.
    static func decode(_ data: Data) -> CommandResponse {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), case .object(let object) = value else {
            return .failure(.io("unreadable reply from Masume"))
        }
        if case .bool(true)? = object["ok"], let result = object["result"] { return .success(result) }
        if case .object(let error)? = object["error"], case .string(let code)? = error["code"],
           case .string(let message)? = error["message"] {
            return .failure(CommandError(code: CommandErrorCode(rawValue: code) ?? .io, message: message))
        }
        return .failure(.io("unreadable reply from Masume"))
    }

    /// `view --out`: the app wrote the crop under Caches; move it where the
    /// caller asked and report that path.
    private static func moveCrop(_ response: CommandResponse, to out: String) throws -> CommandResponse {
        guard case .success(.object(var result)) = response, case .string(let path)? = result["path"] else { return response }
        let destination = URL(fileURLWithPath: out)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: path), to: destination)
        result["path"] = .string(destination.standardizedFileURL.path)
        return .success(.object(result))
    }
}
