import AppKit
import SwiftUI

/// The menu behind the menu bar item: server control, status, what a client
/// needs to connect, settings, and quit.
struct MCPMenu: View {
    var server: MCPServerController

    var body: some View {
        Button("About Masume MCP\u{2026}") { showAbout() }
        SettingsLink { Text("Settings\u{2026}") }
        Divider()
        switch server.state {
        case .running(let port):
            Button("Stop Server") { server.stop() }
            Text("Server Running \u{2014} Port \(port)")
        case .starting:
            Button("Stop Server") { server.stop() }
            Text("Server Starting\u{2026}")
        case .stopped:
            Button("Start Server") { server.start() }
            Text("Server Stopped")
        case .failed(let message):
            Button("Start Server") { server.start() }
            Text("Failed: \(message)")
        }
        Text("\(MCPServerController.toolCount) Tools Available")
        Button("Copy Server URL") { copy(server.serverURL) }
        Button("Copy Server JSON Config") { copy(server.httpConfigJSON) }
        Button("Copy stdio JSON Config") { copy(server.stdioConfigJSON) }
        Divider()
        Button("Quit Masume") { NSApp.terminate(nil) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Masume MCP"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        alert.informativeText = """
            Masume \(version). The MCP server lets an agent annotate the open document with you: \
            \(MCPServerController.toolCount) tools, one shared history, and a spreadsheet grid as the common language. \
            It runs on this Mac only, bound to 127.0.0.1 with a bearer token, and drives the app through the \
            masume command-line tool over Apple Events.
            """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Settings: installation for the command-line executable plus where the MCP
/// server listens, its token, Node, the agent's name, and launch behavior.
struct MCPSettingsView: View {
    @Bindable var server: MCPServerController
    var cliInstaller: CLIInstallationController

    var body: some View {
        Form {
            Section("Command Line") {
                LabeledContent("Location") {
                    Text(cliInstaller.destinationURL.path)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("Status") {
                    installationStatus
                }
                Button(cliInstaller.buttonTitle) {
                    Task { await cliInstaller.install() }
                }
                .disabled(cliInstaller.state == .installing)
                Text("Installs the masume command for all local users. An administrator password is required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Server") {
                TextField("Port", value: $server.port, format: .number)
                LabeledContent("Token") {
                    HStack {
                        Text(server.token)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Regenerate") { server.regenerateToken() }
                    }
                }
                LabeledContent("Node") {
                    HStack {
                        TextField("Path to node", text: $server.nodePath)
                        Button("Detect") { if let node = MCPServerController.detectNode() { server.nodePath = node } }
                    }
                }
                Text("Changes apply the next time the server starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Agent") {
                TextField("Name in the history", text: $server.actorName)
                Text("Edits made through MCP are attributed to this name, with the reason the agent gives.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Launch") {
                Toggle("Start the server when Masume opens", isOn: $server.startAtLaunch)
                Toggle("Show the menu bar item", isOn: $server.showsMenuBarItem)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var installationStatus: some View {
        switch cliInstaller.state {
        case .notInstalled:
            Text("Not installed")
                .foregroundStyle(.secondary)
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .installing:
            ProgressView("Installing\u{2026}")
                .controlSize(.small)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
