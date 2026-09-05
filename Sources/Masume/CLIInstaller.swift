import Foundation
import Observation

enum CLIInstallerError: LocalizedError {
    case bundledExecutableMissing
    case installationFailed(String)
    case installationCouldNotBeVerified

    var errorDescription: String? {
        switch self {
        case .bundledExecutableMissing:
            "This copy of Masume does not contain the CLI executable."
        case .installationFailed(let message):
            message
        case .installationCouldNotBeVerified:
            "The installer finished, but /usr/local/bin/masume does not match the bundled executable."
        }
    }
}

/// Installs the bundled CLI executable at a stable path shared by local users.
enum CLIInstaller {
    static let destinationURL = URL(fileURLWithPath: "/usr/local/bin/masume")

    static func bundledExecutableURL(
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> URL? {
        let executable = bundleURL.appendingPathComponent("Contents/Helpers/masume")
        guard fileManager.isExecutableFile(atPath: executable.path) else { return nil }
        return executable
    }

    static func install(_ sourceExecutableURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try runAuthorizedInstall(sourceExecutableURL)
        }.value
    }

    private static func runAuthorizedInstall(_ sourceExecutableURL: URL) throws {
        let script = #"""
            set sourcePath to system attribute "MASUME_CLI_INSTALL_SOURCE"
            set destinationPath to "/usr/local/bin/masume"
            set makeDirectoryCommand to "/usr/bin/install -d -m 755 /usr/local/bin"
            set installCommand to "/usr/bin/install -m 755 " & quoted form of sourcePath & " " & quoted form of destinationPath
            do shell script makeDirectoryCommand & " && " & installCommand with administrator privileges
            """#
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["MASUME_CLI_INSTALL_SOURCE"] = sourceExecutableURL.path
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw CLIInstallerError.installationFailed("Could not start the CLI installer: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message: String
            if let detail, detail.localizedCaseInsensitiveContains("user canceled") {
                message = "Installation was canceled."
            } else if let detail, !detail.isEmpty {
                message = detail
            } else {
                message = "The CLI installation was canceled or could not be completed."
            }
            throw CLIInstallerError.installationFailed(message)
        }
    }
}

@MainActor
@Observable
final class CLIInstallationController {
    enum State: Equatable {
        case notInstalled
        case installed
        case installing
        case failed(String)
    }

    private(set) var state: State
    let destinationURL: URL

    @ObservationIgnored private let sourceExecutableURL: URL?
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let installOperation: (URL) async throws -> Void

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        destinationURL: URL = CLIInstaller.destinationURL,
        fileManager: FileManager = .default,
        installOperation: @escaping (URL) async throws -> Void = CLIInstaller.install
    ) {
        self.destinationURL = destinationURL
        self.fileManager = fileManager
        self.installOperation = installOperation
        sourceExecutableURL = CLIInstaller.bundledExecutableURL(bundleURL: bundleURL, fileManager: fileManager)
        if let sourceExecutableURL,
           fileManager.isExecutableFile(atPath: destinationURL.path),
           fileManager.contentsEqual(atPath: sourceExecutableURL.path, andPath: destinationURL.path) {
            state = .installed
        } else {
            state = .notInstalled
        }
    }

    var buttonTitle: String {
        if fileManager.isExecutableFile(atPath: destinationURL.path) {
            "Reinstall CLI Executable\u{2026}"
        } else {
            "Install CLI Executable\u{2026}"
        }
    }

    func install() async {
        guard state != .installing else { return }
        guard let sourceExecutableURL else {
            state = .failed(CLIInstallerError.bundledExecutableMissing.localizedDescription)
            return
        }

        state = .installing
        do {
            try await installOperation(sourceExecutableURL)
            guard fileManager.isExecutableFile(atPath: destinationURL.path),
                  fileManager.contentsEqual(atPath: sourceExecutableURL.path, andPath: destinationURL.path) else {
                throw CLIInstallerError.installationCouldNotBeVerified
            }
            state = .installed
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
