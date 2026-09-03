import XCTest
@testable import Masume

/// The in-app MCP server: settings, what clients are given to connect,
/// the command line it is started with, and its lifecycle through a fake
/// Node.
@MainActor
final class MCPServerControllerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "masume.mcp.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultsTokenAndActor() {
        let server = MCPServerController(defaults: defaults, launch: { _ in })
        XCTAssertEqual(server.port, MCPServerController.defaultPort)
        XCTAssertGreaterThanOrEqual(server.token.count, 30, "a generated token")
        XCTAssertFalse(server.token.contains("="))
        let first = server.token
        server.regenerateToken()
        XCTAssertNotEqual(server.token, first)
        XCTAssertEqual(server.actorId, "agent")
        server.actorName = "Nova Prime"
        XCTAssertEqual(server.actorId, "nova-prime")
        XCTAssertTrue(server.showsMenuBarItem)
        XCTAssertFalse(server.startAtLaunch)
        XCTAssertEqual(MCPServerController(defaults: defaults, launch: { _ in }).token, server.token, "remembered")
    }

    func testConnectionDetailsForClients() throws {
        let server = MCPServerController(defaults: defaults, launch: { _ in })
        server.port = 9001
        server.token = "T0KEN"
        XCTAssertEqual(server.serverURL, "http://127.0.0.1:9001/mcp")
        let http = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(server.httpConfigJSON.utf8)) as? [String: Any])
        let entry = try XCTUnwrap(((http["mcpServers"] as? [String: Any])?["masume"]) as? [String: Any])
        XCTAssertEqual(entry["type"] as? String, "http")
        XCTAssertEqual(entry["url"] as? String, "http://127.0.0.1:9001/mcp")
        XCTAssertEqual((entry["headers"] as? [String: String])?["Authorization"], "Bearer T0KEN")
        let stdio = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(server.stdioConfigJSON.utf8)) as? [String: Any])
        let spawn = try XCTUnwrap(((stdio["mcpServers"] as? [String: Any])?["masume"]) as? [String: Any])
        XCTAssertEqual(spawn["command"] as? String, server.nodePath)
        XCTAssertEqual((spawn["args"] as? [String])?.contains("--actor-name"), true)
        let args = server.arguments(script: URL(fileURLWithPath: "/x/index.js"))
        XCTAssertEqual(args, ["/x/index.js", "--http", "9001", "--token", "T0KEN", "--actor-id", "agent", "--actor-name", "Agent"])
    }

    func testToolCountMatchesTheServerSource() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("mcp/src/server.ts")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "registerTool(").count - 1, MCPServerController.toolCount)
    }

    func testLifecycleThroughAFakeNode() async throws {
        // A "node" that announces it is listening, then waits to be terminated.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("masume-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("node")
        try "#!/bin/sh\necho \"masume-mcp listening on http://127.0.0.1:1/ (Streamable HTTP)\" >&2\nsleep 30\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        setenv("MASUME_MCP_SCRIPT", dir.appendingPathComponent("index.js").path, 1)
        defer { unsetenv("MASUME_MCP_SCRIPT") }

        let server = MCPServerController(defaults: defaults)
        server.nodePath = fake.path
        server.start()
        XCTAssertEqual(server.state, .starting)
        for _ in 0..<50 where !server.state.isRunning {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(server.state, .running(port: server.port))
        server.start()
        XCTAssertEqual(server.state, .running(port: server.port), "start while running is a no-op")
        server.stop()
        for _ in 0..<50 where server.state != .stopped {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(server.state, .stopped)
    }

    func testMissingNodeOrScriptFailsClearly() {
        unsetenv("MASUME_MCP_SCRIPT")
        let server = MCPServerController(defaults: defaults, launch: { _ in })
        server.nodePath = "/nonexistent/node"
        server.start()
        guard case .failed(let message) = server.state else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("not bundled") || message.contains("Node was not found"), message)
    }
}
