import XCTest
@testable import Masume

@MainActor
final class CLIInstallerTests: XCTestCase {
    func testFindsOnlyAnExecutableBundledCLI() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = scratch.appendingPathComponent("Masume.app", isDirectory: true)
        let helper = bundle.appendingPathComponent("Contents/Helpers/masume")
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("cli".utf8).write(to: helper)
        XCTAssertNil(CLIInstaller.bundledExecutableURL(bundleURL: bundle))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        XCTAssertEqual(CLIInstaller.bundledExecutableURL(bundleURL: bundle), helper)
    }

    func testInstallCopiesBundledCLIAndReportsInstalled() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = try makeBundleWithCLI(in: scratch)
        let destination = scratch.appendingPathComponent("usr-local-bin-masume")
        let controller = CLIInstallationController(bundleURL: bundle, destinationURL: destination) { sourceExecutable in
            try FileManager.default.copyItem(at: sourceExecutable, to: destination)
        }
        XCTAssertEqual(controller.state, .notInstalled)
        XCTAssertEqual(controller.buttonTitle, "Install CLI Executable\u{2026}")

        await controller.install()

        XCTAssertEqual(controller.state, .installed)
        XCTAssertEqual(controller.buttonTitle, "Reinstall CLI Executable\u{2026}")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: destination.path))
    }

    func testMissingBundledCLIFailsWithoutRunningInstaller() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let destination = scratch.appendingPathComponent("masume")
        var didRun = false
        let controller = CLIInstallationController(bundleURL: scratch, destinationURL: destination) { _ in
            didRun = true
        }

        await controller.install()

        guard case .failed(let message) = controller.state else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("does not contain"), message)
        XCTAssertFalse(didRun)
    }

    func testInstallerFailureIsShownAndCanBeRetried() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        struct TestError: LocalizedError {
            var errorDescription: String? { "Authorization was canceled." }
        }
        let bundle = try makeBundleWithCLI(in: scratch)
        let destination = scratch.appendingPathComponent("masume")
        let controller = CLIInstallationController(bundleURL: bundle, destinationURL: destination) { _ in
            throw TestError()
        }

        await controller.install()

        XCTAssertEqual(controller.state, .failed("Authorization was canceled."))
        XCTAssertEqual(controller.buttonTitle, "Install CLI Executable\u{2026}")
    }

    private func makeScratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("masume-cli-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeBundleWithCLI(in scratch: URL) throws -> URL {
        let bundle = scratch.appendingPathComponent("Masume.app", isDirectory: true)
        let helper = bundle.appendingPathComponent("Contents/Helpers/masume")
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return bundle
    }
}
