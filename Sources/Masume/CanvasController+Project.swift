import AppKit
import CoreGraphics
import AnnotationModel
import AnnotationRender

// Save, open, and recovery for CanvasController, over ProjectSession and
// the .masume codec. Panels and alerts live in SaveService; these methods
// take URLs so tests can drive them directly.

extension CanvasController {
    var isDirty: Bool { project?.isDirty ?? false }

    /// Tab and window title: the project name, else the imported file's
    /// name, else "Untitled".
    var documentTitle: String {
        if let url = project?.projectURL { return url.deletingPathExtension().lastPathComponent }
        return sourceURL?.lastPathComponent ?? "Untitled"
    }

    /// Writes the project to `url` and binds the document to it. Save As
    /// passes `newIdentity: true` so the copy is a new document.
    func saveProject(to url: URL, newIdentity: Bool) throws {
        guard let project, let document else { throw ProjectError.io("There is no document to save.") }
        ExportService.commitPendingTextEditing()
        let preview = ProjectSession.previewPNG(document: document, baseImage: baseImage)
        try project.save(document: document, to: url, preview: preview, newIdentity: newIdentity)
        sourceURL = url
        // The recovery package now records the binding.
        autosave()
    }

    /// Reads and verifies a project package and makes it the open document.
    /// Nothing changes when the read fails.
    func openProject(at url: URL) throws {
        let contents = try ProjectPackage.read(at: url)
        let session = ProjectSession(contents: contents, projectURL: url, recovery: recoveryStore, isRecovered: false)
        try adopt(contents, session: session, sourceURL: url)
    }

    /// Reopens a recovery package after a crash, rebinding the project it was
    /// saved to when the manifest recorded one. The document is unsaved.
    func adoptRecovery(at url: URL) throws {
        let contents = try ProjectPackage.read(at: url)
        let bound = contents.manifest.boundProjectPath.map { URL(fileURLWithPath: $0) }
        let session = ProjectSession(contents: contents, projectURL: bound, recovery: recoveryStore, isRecovered: true)
        try adopt(contents, session: session, sourceURL: bound)
    }

    private func adopt(_ contents: ProjectPackage.Contents, session: ProjectSession, sourceURL: URL?) throws {
        guard let image = ImageLoader.cgImage(from: contents.baseImagePNG) else {
            throw ProjectError.corruptManifest("the base image could not be decoded")
        }
        let manifest = contents.manifest
        let document = Document(baseImage: .pngData(Data()), canvasSize: manifest.canvasSize,
                                elements: manifest.elements, crop: manifest.crop, grid: manifest.grid)
        install(image: image, document: document, sourceURL: sourceURL, session: session)
        autosave()
    }

    /// A clean close: the recovery package is no longer needed.
    func discardRecovery() {
        project?.removeRecovery()
    }

    /// Changes the grid density to a preset (8, 12, 16, 24, or 32 cells
    /// across the long side). A document action: undoable, in the history,
    /// and it bumps the grid version so address-keyed caches go stale.
    func setGridPreset(_ n: Int) {
        guard let document, GridDefinition.presets.contains(n) else { return }
        let next = GridDefinition.preset(n, for: document.canvasSize, version: document.grid.version + 1)
        guard next.columns != document.grid.columns || next.rows != document.grid.rows else { return }
        perform { $0.grid = next }
    }
}
