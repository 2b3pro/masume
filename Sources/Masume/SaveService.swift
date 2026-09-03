import AppKit
import Foundation
import UniformTypeIdentifiers
import AnnotationModel

/// The `.masume` document type and the panels around saving and opening
/// projects. The controller does the work; this asks the user where.
@MainActor
enum SaveService {
    /// Declared in Info.plist as an exported package type.
    static let projectType = UTType(exportedAs: "com.2b3pro.masume.project", conformingTo: .package)

    /// Save to the bound project, or run Save As when there is none.
    static func save(_ controller: CanvasController) {
        guard controller.hasDocument else { NSSound.beep(); return }
        if let url = controller.project?.projectURL {
            write(controller, to: url, newIdentity: false)
        } else {
            saveAs(controller)
        }
    }

    static func saveAs(_ controller: CanvasController) {
        guard controller.hasDocument else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [projectType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(controller.documentTitle).\(ProjectPackage.pathExtension)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            write(controller, to: url, newIdentity: controller.project?.projectURL != nil)
        }
    }

    /// Hook for the unredacted-original disclosure; returns false to cancel
    /// the save. Replaced in the disclosure commit.
    static var disclose: @MainActor (CanvasController) -> Bool = { _ in true }

    private static func write(_ controller: CanvasController, to url: URL, newIdentity: Bool) {
        guard disclose(controller) else { return }
        do {
            try controller.saveProject(to: url, newIdentity: newIdentity)
            controller.flashToast("Saved \(controller.documentTitle)")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Open panel for images, PDFs, and projects. With a workspace, a project
    /// takes an empty tab or a new one; with a controller (the empty state's
    /// button), everything loads into that tab.
    static func openPanel(_ workspace: WorkspaceController) {
        runOpenPanel { open($0, in: workspace) }
    }

    static func openPanel(into controller: CanvasController) {
        runOpenPanel { open($0, into: controller) }
    }

    private static func runOpenPanel(_ handle: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf, projectType]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            handle(url)
        }
    }

    static func isProject(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == ProjectPackage.pathExtension
    }

    /// Routes a file to the right loader: projects open in an empty tab or a
    /// new one; images and PDFs load into the active tab as before.
    static func open(_ url: URL, in workspace: WorkspaceController) {
        guard isProject(url) else {
            workspace.active.loadImage(at: url)
            return
        }
        let target = workspace.active.hasDocument ? workspace.newTabController() : workspace.active
        do {
            try target.openProject(at: url)
            workspace.activate(target)
        } catch {
            NSAlert(error: error).runModal()
            workspace.closeEmpty(target)
        }
    }

    /// Loads `url` into `controller`, whatever kind of file it is.
    static func open(_ url: URL, into controller: CanvasController) {
        guard isProject(url) else {
            controller.loadImage(at: url)
            return
        }
        do {
            try controller.openProject(at: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
