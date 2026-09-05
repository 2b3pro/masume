import AppKit
import XCTest
@testable import Masume

@MainActor
final class AppLifecycleTests: XCTestCase {
    private final class ClosingWindow: NSWindow {
        private(set) var didPerformClose = false

        override func performClose(_ sender: Any?) {
            didPerformClose = true
        }
    }

    func testClosingLastWindowDoesNotImplicitlyQuit() {
        let delegate = AppDelegate()

        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    }

    func testOnlyRegisteredMainWindowUsesTerminationRouting() {
        let delegate = AppDelegate()
        let mainWindow = NSWindow()
        let settingsWindow = NSWindow()

        delegate.registerMainWindow(mainWindow)

        XCTAssertTrue(delegate.isMainWindow(mainWindow))
        XCTAssertFalse(delegate.isMainWindow(settingsWindow))
    }

    func testCloseShortcutClosesAnAuxiliaryWindowWithoutClosingATab() {
        let delegate = AppDelegate()
        let mainWindow = NSWindow()
        let settingsWindow = ClosingWindow()
        delegate.registerMainWindow(mainWindow)

        delegate.closeKeyWindowOrActiveTab(keyWindow: settingsWindow)

        XCTAssertTrue(settingsWindow.didPerformClose)
        XCTAssertEqual(delegate.workspace.tabs.count, 1)
    }
}
