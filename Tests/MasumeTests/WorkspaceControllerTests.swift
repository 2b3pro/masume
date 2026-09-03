import XCTest
import CoreGraphics
import AnnotationModel
@testable import Masume

@MainActor
final class WorkspaceControllerTests: XCTestCase {

    /// Captures the workspace's Save prompt, Save As, and termination
    /// requests so tests never show a panel or quit the test runner.
    /// `confirmAnswer` true answers Don't Save; false answers Cancel.
    @MainActor
    private final class Harness {
        var confirmAnswer = true
        var saveChoice: WorkspaceController.SaveChoice?
        private(set) var confirmCount = 0
        private(set) var saveAsCount = 0
        private(set) var terminationCount = 0
        let workspace: WorkspaceController

        init(confirmAnswer: Bool = true) {
            self.confirmAnswer = confirmAnswer
            var recordConfirm: (() -> WorkspaceController.SaveChoice)!
            var recordSaveAs: (() -> Bool)!
            var recordTermination: (() -> Void)!
            // An empty, private recovery store: never the user's real one.
            let store = RecoveryStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("masume-ws-\(UUID().uuidString)", isDirectory: true))
            workspace = WorkspaceController(
                confirmDiscard: { _, _, _ in true },
                confirmSave: { _ in recordConfirm() },
                saveAs: { _ in recordSaveAs() },
                requestTermination: { recordTermination() },
                recoveryStore: store
            )
            recordConfirm = { [unowned self] in
                confirmCount += 1
                return self.saveChoice ?? (self.confirmAnswer ? .discard : .cancel)
            }
            recordSaveAs = { [unowned self] in
                saveAsCount += 1
                return true
            }
            recordTermination = { [unowned self] in terminationCount += 1 }
        }
    }

    /// A document with one committed change: the kind that deserves a prompt.
    private func edit(_ controller: CanvasController) {
        controller.perform { $0.add(.arrow(SegmentElement(start: .zero, end: CGPoint(x: 1, y: 1)))) }
    }

    private func makeImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    // MARK: - Init / new tab / activate

    func testInitHasSingleActiveEmptyTab() {
        let ws = Harness().workspace
        XCTAssertEqual(ws.tabs.count, 1)
        XCTAssertTrue(ws.active === ws.tabs[0])
        XCTAssertEqual(ws.openDocumentCount, 0)
    }

    func testNewTabAppendsAndActivates() {
        let ws = Harness().workspace
        ws.newTab()
        XCTAssertEqual(ws.tabs.count, 2)
        XCTAssertTrue(ws.active === ws.tabs[1])
        XCTAssertFalse(ws.active.hasDocument)
    }

    func testActivateSwitchesActive() {
        let ws = Harness().workspace
        ws.newTab()
        let first = ws.tabs[0]
        ws.activate(first)
        XCTAssertTrue(ws.active === first)
    }

    func testActivateForeignControllerIsNoOp() {
        let ws = Harness().workspace
        ws.activate(CanvasController(preferencesStore: InMemoryToolPreferencesStore()))
        XCTAssertTrue(ws.active === ws.tabs[0])
    }

    // MARK: - Adjacent-tab navigation

    func testActivateNextTabMovesRight() {
        let ws = Harness().workspace
        ws.newTab()
        ws.newTab()
        ws.activate(ws.tabs[1])
        ws.activateNextTab()
        XCTAssertTrue(ws.active === ws.tabs[2])
    }

    func testActivateNextTabWrapsToFirst() {
        let ws = Harness().workspace
        ws.newTab()
        ws.newTab() // rightmost is active
        ws.activateNextTab()
        XCTAssertTrue(ws.active === ws.tabs[0])
    }

    func testActivatePreviousTabWrapsToLast() {
        let ws = Harness().workspace
        ws.newTab()
        ws.newTab()
        ws.activate(ws.tabs[0])
        ws.activatePreviousTab()
        XCTAssertTrue(ws.active === ws.tabs[2])
    }

    func testTabCycleWithSingleTabIsNoOp() {
        let ws = Harness().workspace
        ws.activateNextTab()
        XCTAssertTrue(ws.active === ws.tabs[0])
        ws.activatePreviousTab()
        XCTAssertTrue(ws.active === ws.tabs[0])
    }

    // MARK: - Close: confirmation

    func testCloseEmptyNonLastTabRemovesWithoutConfirm() {
        let harness = Harness()
        let ws = harness.workspace
        ws.newTab()
        ws.close(ws.tabs[1])
        XCTAssertEqual(ws.tabs.count, 1)
        XCTAssertEqual(harness.confirmCount, 0)
    }

    func testCloseTabWithUneditedImageClosesWithoutAsking() {
        let harness = Harness(confirmAnswer: false)
        let ws = harness.workspace
        ws.newTab()
        ws.active.loadImage(makeImage())
        ws.close(ws.active)
        XCTAssertEqual(ws.tabs.count, 1, "nothing but the import: no prompt, no loss")
        XCTAssertEqual(harness.confirmCount, 0)
    }

    func testCloseEditedTabCancelKeepsTab() {
        let harness = Harness(confirmAnswer: false)
        let ws = harness.workspace
        ws.newTab()
        ws.active.loadImage(makeImage())
        edit(ws.active)
        let documented = ws.active
        ws.close(documented)
        XCTAssertEqual(ws.tabs.count, 2)
        XCTAssertTrue(ws.active === documented)
        XCTAssertEqual(harness.confirmCount, 1)
    }

    func testCloseEditedTabDontSaveRemoves() {
        let harness = Harness(confirmAnswer: true)
        let ws = harness.workspace
        ws.newTab()
        ws.active.loadImage(makeImage())
        edit(ws.active)
        ws.close(ws.active)
        XCTAssertEqual(ws.tabs.count, 1)
        XCTAssertEqual(harness.confirmCount, 1)
        XCTAssertEqual(harness.saveAsCount, 0)
    }

    func testCloseEditedNeverSavedTabSaveRunsSaveAs() {
        let harness = Harness()
        harness.saveChoice = .save
        let ws = harness.workspace
        ws.newTab()
        ws.active.loadImage(makeImage())
        edit(ws.active)
        ws.close(ws.active)
        XCTAssertEqual(harness.confirmCount, 1)
        XCTAssertEqual(harness.saveAsCount, 1, "Save on a never-saved document is Save As")
        XCTAssertEqual(ws.tabs.count, 1)
    }

    // MARK: - Close: neighbor activation

    func testCloseActiveMiddleTabActivatesRightNeighbor() {
        let ws = Harness().workspace
        ws.newTab()
        ws.newTab()
        let middle = ws.tabs[1]
        let right = ws.tabs[2]
        ws.activate(middle)
        ws.close(middle)
        XCTAssertTrue(ws.active === right)
    }

    func testCloseActiveRightmostTabActivatesLeftNeighbor() {
        let ws = Harness().workspace
        ws.newTab()
        ws.newTab()
        let left = ws.tabs[1]
        ws.close(ws.tabs[2]) // rightmost is active after newTab()
        XCTAssertTrue(ws.active === left)
    }

    func testCloseNonActiveTabKeepsActive() {
        let ws = Harness().workspace
        ws.newTab()
        let activeTab = ws.active
        ws.close(ws.tabs[0])
        XCTAssertTrue(ws.active === activeTab)
        XCTAssertEqual(ws.tabs.count, 1)
    }

    // MARK: - Close: last tab quits

    func testCloseLastTabRequestsTerminationWithoutConfirmOrRemoval() {
        let harness = Harness()
        let ws = harness.workspace
        // Even with a document, the quit prompt owns the confirmation.
        ws.active.loadImage(makeImage())
        ws.closeActiveTab()
        XCTAssertEqual(harness.terminationCount, 1)
        XCTAssertEqual(harness.confirmCount, 0)
        XCTAssertEqual(ws.tabs.count, 1)
    }

    // MARK: - Document counting

    func testOpenDocumentCountWithMixedTabs() {
        let ws = Harness().workspace
        ws.active.loadImage(makeImage())
        ws.newTab()
        ws.newTab()
        ws.active.loadImage(makeImage())
        XCTAssertEqual(ws.tabs.count, 3)
        XCTAssertEqual(ws.openDocumentCount, 2)
    }
}
