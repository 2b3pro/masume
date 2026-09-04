import AppKit
import Foundation
import Observation

/// Runs the Masume MCP server (the Node process in `mcp/`) from inside the
/// app, in Streamable HTTP mode on loopback with a bearer token, and hands
/// it the bundled `masume` CLI. The menu bar item drives this; settings
/// persist in UserDefaults.
@MainActor @Observable
final class MCPServerController {
    enum State: Equatable {
        case stopped
        case starting
        case running(port: Int)
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    /// The tools the server registers; kept in step with `mcp/src/server.ts`
    /// by a test.
    static let toolCount = 19
    /// Not 8765, which DEVONthink's MCP server takes on the same Mac.
    static let defaultPort = 8722

    private(set) var state: State = .stopped
    /// The last lines the server wrote, for the About box and failures.
    private(set) var log: [String] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stopRequested = false
    /// Test seam: how a configured process is launched.
    @ObservationIgnored private let launch: (Process) throws -> Void

    init(defaults: UserDefaults = .standard, launch: @escaping (Process) throws -> Void = { try $0.run() }) {
        self.defaults = defaults
        self.launch = launch
        if defaults.string(forKey: Keys.token) == nil { regenerateToken() }
        if defaults.string(forKey: Keys.nodePath) == nil, let node = Self.detectNode() {
            defaults.set(node, forKey: Keys.nodePath)
        }
    }

    // MARK: Settings

    enum Keys {
        static let port = "mcp.port"
        static let token = "mcp.token"
        static let nodePath = "mcp.nodePath"
        static let actorName = "mcp.actorName"
        static let startAtLaunch = "mcp.startAtLaunch"
        static let showsMenuBarItem = "mcp.showsMenuBarItem"
    }

    var port: Int {
        get { defaults.object(forKey: Keys.port) as? Int ?? Self.defaultPort }
        set { defaults.set(newValue, forKey: Keys.port) }
    }

    var token: String {
        get { defaults.string(forKey: Keys.token) ?? "" }
        set { defaults.set(newValue, forKey: Keys.token) }
    }

    var nodePath: String {
        get { defaults.string(forKey: Keys.nodePath) ?? "" }
        set { defaults.set(newValue, forKey: Keys.nodePath) }
    }

    var actorName: String {
        get { defaults.string(forKey: Keys.actorName) ?? "Agent" }
        set { defaults.set(newValue, forKey: Keys.actorName) }
    }

    /// The actor id an agent's edits carry: the name, lowercased, spaces to
    /// dashes.
    var actorId: String {
        let id = actorName.lowercased().replacingOccurrences(of: " ", with: "-")
        return id.isEmpty ? "agent" : id
    }

    var startAtLaunch: Bool {
        get { defaults.bool(forKey: Keys.startAtLaunch) }
        set { defaults.set(newValue, forKey: Keys.startAtLaunch) }
    }

    var showsMenuBarItem: Bool {
        get { defaults.object(forKey: Keys.showsMenuBarItem) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showsMenuBarItem) }
    }

    func regenerateToken() {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Node from the usual places, newest nvm install last resort.
    static func detectNode() -> String? {
        let fixed = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        if let found = fixed.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        let nvm = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? []
        return versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { nvm.appendingPathComponent("\($0)/bin/node").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Locations

    /// The server script: bundled under Resources/mcp, else the repository
    /// checkout named by MASUME_MCP_SCRIPT (development).
    static var scriptURL: URL? {
        if let bundled = Bundle.main.url(forResource: "index", withExtension: "js", subdirectory: "mcp/dist/src") {
            return bundled
        }
        if let path = ProcessInfo.processInfo.environment["MASUME_MCP_SCRIPT"] { return URL(fileURLWithPath: path) }
        return nil
    }

    /// The masume CLI the server spawns: bundled beside the app binary,
    /// else MASUME_CLI, else whatever `masume` is on the server's PATH.
    static var cliURL: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/masume")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        if let path = ProcessInfo.processInfo.environment["MASUME_CLI"] { return URL(fileURLWithPath: path) }
        return nil
    }

    // MARK: What clients need

    var serverURL: String { "http://127.0.0.1:\(port)/mcp" }

    /// Claude Code style config for the HTTP server.
    var httpConfigJSON: String {
        Self.json(["mcpServers": ["masume": [
            "type": "http", "url": serverURL, "headers": ["Authorization": "Bearer \(token)"],
        ]]])
    }

    /// Claude Code style config for a host that spawns the server itself.
    var stdioConfigJSON: String {
        var env: [String: String] = [:]
        if let cli = Self.cliURL { env["MASUME_CLI"] = cli.path }
        var server: [String: Any] = [
            "command": nodePath,
            "args": [Self.scriptURL?.path ?? "mcp/dist/src/index.js", "--actor-id", actorId, "--actor-name", actorName],
        ]
        if !env.isEmpty { server["env"] = env }
        return Self.json(["mcpServers": ["masume": server]])
    }

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// The command line the server is started with.
    func arguments(script: URL) -> [String] {
        [script.path, "--http", "\(port)", "--token", token, "--actor-id", actorId, "--actor-name", actorName]
    }

    // MARK: Start and stop

    func start() {
        guard !state.isRunning, state != .starting else { return }
        guard let script = Self.scriptURL else {
            state = .failed("The MCP server is not bundled with this build (mcp/dist missing).")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: nodePath) else {
            state = .failed("Node was not found at \(nodePath.isEmpty ? "any usual place" : nodePath); set its path in Settings.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = arguments(script: script)
        var environment = ProcessInfo.processInfo.environment
        if let cli = Self.cliURL { environment["MASUME_CLI"] = cli.path }
        environment["PATH"] = [URL(fileURLWithPath: nodePath).deletingLastPathComponent().path,
                               environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        process.environment = environment
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(data: handle.availableData, encoding: .utf8) ?? ""
            guard !text.isEmpty else { return }
            Task { @MainActor in self?.serverWrote(text) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in self?.serverExited(status: status) }
        }
        log = []
        stopRequested = false
        state = .starting
        do {
            try launch(process)
            self.process = process
        } catch {
            state = .failed("Could not start Node: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let process else { return }
        stopRequested = true
        process.terminate()
    }

    func toggle() {
        if state.isRunning || state == .starting { stop() } else { start() }
    }

    private func serverWrote(_ text: String) {
        for line in text.split(separator: "\n") where !line.isEmpty {
            log.append(String(line))
            if line.contains("listening") { state = .running(port: port) }
        }
        if log.count > 50 { log.removeFirst(log.count - 50) }
    }

    private func serverExited(status: Int32) {
        process = nil
        if stopRequested || status == 0 {
            state = .stopped
        } else {
            let detail = log.last.map { ": \($0)" } ?? ""
            state = .failed("The server exited with status \(status)\(detail)")
        }
    }
}
