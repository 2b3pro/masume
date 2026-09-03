import AppKit
import Observation

/// Identity-based id so controllers work directly with ForEach and View.id().
extension CanvasController: Identifiable {}

/// Owns the open tabs and the active tab. One CanvasController per tab —
/// everything per-document (image, selection, zoom, undo stack, toast) already
/// lives on CanvasController, so this class only manages the collection and
/// the close/quit routing.
@MainActor @Observable
final class WorkspaceController {
    /// Invariant: never empty. Closing the last tab quits the app instead of
    /// removing the tab, so the active tab can stay non-optional.
    private(set) var tabs: [CanvasController]
    private(set) var active: CanvasController

    /// Injected so unit tests can simulate the user's confirm/cancel choice
    /// without running an NSAlert.
    @ObservationIgnored
    private let confirmDiscard: (_ message: String, _ info: String, _ confirmTitle: String) -> Bool
    /// Injected quit hook; the default routes through applicationShouldTerminate,
    /// which owns the (single) quit confirmation.
    @ObservationIgnored
    private let requestTermination: () -> Void
    /// Save / Don't Save / Cancel for a dirty saved project, injected like
    /// `confirmDiscard`. Returning `.save` runs Save before closing.
    @ObservationIgnored
    private let confirmSave: (_ name: String) -> SaveChoice
    @ObservationIgnored
    private let recoveryStore: RecoveryStore

    enum SaveChoice { case save, discard, cancel }

    init(
        confirmDiscard: @escaping (String, String, String) -> Bool = {
            ExportService.confirmDiscard(message: $0, info: $1, confirmTitle: $2)
        },
        confirmSave: @escaping (String) -> SaveChoice = { ExportService.confirmSave(name: $0) },
        requestTermination: @escaping () -> Void = { NSApp.terminate(nil) },
        recoveryStore: RecoveryStore = .default
    ) {
        self.confirmDiscard = confirmDiscard
        self.confirmSave = confirmSave
        self.requestTermination = requestTermination
        self.recoveryStore = recoveryStore
        // Whatever the last run left in recovery comes back where it was,
        // unsaved. Packages that no longer read are left for inspection.
        let recovered: [CanvasController] = recoveryStore.packages().compactMap { url in
            let controller = CanvasController(recoveryStore: recoveryStore)
            return (try? controller.adoptRecovery(at: url)) != nil ? controller : nil
        }
        // The most recently edited document comes to the front.
        let front = recovered.last ?? CanvasController(recoveryStore: recoveryStore)
        tabs = recovered.isEmpty ? [front] : recovered
        active = front
    }

    var openDocumentCount: Int { tabs.count { $0.hasDocument } }

    static func title(for controller: CanvasController) -> String {
        controller.documentTitle
    }

    func newTab() {
        activate(newTabController())
    }

    /// Appends an empty tab without activating it (project open fills it
    /// first, then activates).
    @discardableResult
    func newTabController() -> CanvasController {
        let controller = CanvasController(recoveryStore: recoveryStore)
        tabs.append(controller)
        return controller
    }

    /// Option-drop: the file opens as a new document in a new tab instead of
    /// landing on the active one. An unreadable drop leaves no empty tab.
    func openDroppedInNewTab(_ items: [DroppedImage]) {
        let target = active.hasDocument ? newTabController() : active
        if target.loadDroppedImage(items) {
            activate(target)
        } else {
            closeEmpty(target)
        }
    }

    /// Drops a tab that never got a document (a failed open), never the last.
    func closeEmpty(_ controller: CanvasController) {
        guard !controller.hasDocument, tabs.count > 1,
              let index = tabs.firstIndex(where: { $0 === controller }) else { return }
        tabs.remove(at: index)
        if controller === active { active = tabs[min(index, tabs.count - 1)] }
    }

    /// Recovery packages of every open tab are dropped: called when the app
    /// quits after the user confirmed, so nothing stale reopens next launch.
    func discardAllRecovery() {
        for tab in tabs { tab.discardRecovery() }
    }

    func activate(_ controller: CanvasController) {
        guard controller !== active, tabs.contains(where: { $0 === controller }) else { return }
        // Commit inline text editing before the outgoing tab's canvas view is
        // torn down.
        ExportService.commitPendingTextEditing()
        active = controller
    }

    /// Wrap-around adjacent-tab navigation (Safari's Show Next/Previous Tab).
    func activateNextTab() { activateAdjacent(offset: 1) }

    func activatePreviousTab() { activateAdjacent(offset: -1) }

    private func activateAdjacent(offset: Int) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0 === active }) else { return }
        activate(tabs[(index + offset + tabs.count) % tabs.count])
    }

    func closeActiveTab() { close(active) }

    /// Closes every tab, bringing each to the front in turn so its Save
    /// prompt is about the document on screen. Stops at the first Cancel,
    /// leaving the rest open. Ends with one fresh empty tab rather than
    /// quitting: the user asked to clear the workspace, not leave.
    func closeAll() {
        for controller in tabs {
            activate(controller)
            guard mayClose(controller) else { return }
            controller.discardRecovery()
            guard let index = tabs.firstIndex(where: { $0 === controller }) else { continue }
            tabs.remove(at: index)
            if tabs.isEmpty {
                let fresh = CanvasController(recoveryStore: recoveryStore)
                tabs = [fresh]
                active = fresh
            } else {
                active = tabs[min(index, tabs.count - 1)]
            }
        }
    }

    /// Inline tab rename. Failures (a sibling with that name, an empty name)
    /// are shown; the tab keeps its title.
    func rename(_ controller: CanvasController, to name: String) {
        guard controller.hasDocument else { return }
        do {
            try controller.renameDocument(to: name)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Asks before losing work: a dirty saved project offers Save; anything
    /// else with a document keeps the discard confirmation. Returns true when
    /// closing may proceed (after saving, if chosen).
    private func mayClose(_ controller: CanvasController) -> Bool {
        guard controller.hasDocument else { return true }
        if let url = controller.project?.projectURL {
            guard controller.isDirty else { return true }
            switch confirmSave(controller.documentTitle) {
            case .cancel: return false
            case .discard: return true
            case .save:
                do { try controller.saveProject(to: url, newIdentity: false) } catch { return false }
                return true
            }
        }
        return confirmDiscard(
            "Close this tab?",
            "Closing will discard the image you are editing. Unsaved annotations will be lost.",
            "Close Tab"
        )
    }

    func close(_ controller: CanvasController) {
        guard let index = tabs.firstIndex(where: { $0 === controller }) else { return }
        // Last tab: closing quits. Defer the confirmation to the termination
        // path so the user is prompted exactly once, with quit wording.
        guard tabs.count > 1 else {
            requestTermination()
            return
        }
        guard mayClose(controller) else { return }
        controller.discardRecovery()
        tabs.remove(at: index)
        if controller === active {
            // Finder behavior: activate the right neighbor, or the new last
            // tab when the closed tab was rightmost.
            active = tabs[min(index, tabs.count - 1)]
        }
    }
}
