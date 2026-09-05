import AppKit
import CoreGraphics
import Foundation
import Observation
import AnnotationModel
import AnnotationRender

/// Where recovery packages live. Injected into controllers so tests write to
/// a temporary directory instead of the user's Application Support.
struct RecoveryStore: Sendable {
    let directory: URL

    /// Under XCTest this is a throwaway directory per test process, so no
    /// test can ever leave packages in the user's Application Support (which
    /// the app would reopen as tabs at the next launch).
    static let `default`: RecoveryStore = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil {
            return RecoveryStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("masume-test-recovery-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return RecoveryStore(directory: base.appendingPathComponent("Masume/Recovery", isDirectory: true))
    }()

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).\(ProjectPackage.pathExtension)", isDirectory: true)
    }

    /// Every recovery package present, oldest first.
    func packages() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension == ProjectPackage.pathExtension }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }
}

/// The durable identity of an open document: its id and revision, the
/// history of committed actions, the base image bytes as stored, where it is
/// saved (if anywhere), and the recovery package that shadows every commit.
///
/// The controller owns one per document and calls `record` from its commit
/// funnel; nothing else bumps the revision.
@MainActor @Observable
final class ProjectSession {
    static let previewLongSide: CGFloat = 512
    static let previewDelay: Duration = .seconds(1)

    private(set) var id: UUID
    private(set) var revision: Int
    /// Revision last written to `projectURL`; nil until the first save.
    private(set) var lastSavedRevision: Int?
    private(set) var projectURL: URL?
    /// The user's name for an unsaved document; the tab title and the Save
    /// As default. Ignored once the document is saved (the file name rules).
    var workingName: String?
    private(set) var history: [HistoryEntry]
    private(set) var baseImagePNG: Data
    /// Image layers' pixels, as stored (PNG) and as decoded for drawing.
    private(set) var assets: [UUID: Data] = [:]
    private(set) var assetImages: [UUID: CGImage] = [:]
    private(set) var assetInfos: [AssetInfo] = []
    let createdAt: Date
    let actor: HistoryActor
    /// The last autosave failure, cleared by the next success. The controller
    /// surfaces it; the document stays dirty regardless.
    private(set) var autosaveError: String?
    /// Whether the unredacted-original disclosure has been shown for this
    /// document (it shows once per document, see `SaveService`).
    var disclosureShown = false

    @ObservationIgnored private let recovery: RecoveryStore
    @ObservationIgnored private var recoveryWritten = false
    /// Set when the base image changed (destructive crop, or its undo): the
    /// next autosave rewrites the whole package instead of just the manifest.
    @ObservationIgnored private var baseImageChanged = false
    @ObservationIgnored private var historyWritten = 0
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    static let humanActor = HistoryActor(id: "human", name: NSFullUserName())

    /// A fresh document from an imported image.
    init(baseImagePNG: Data, recovery: RecoveryStore, actor: HistoryActor = ProjectSession.humanActor) {
        id = UUID()
        revision = 0
        history = []
        self.baseImagePNG = baseImagePNG
        createdAt = Date()
        self.actor = actor
        self.recovery = recovery
    }

    /// A document read back from a project or recovery package.
    init(contents: ProjectPackage.Contents, projectURL: URL?, recovery: RecoveryStore,
         actor: HistoryActor = ProjectSession.humanActor, isRecovered: Bool) {
        id = contents.manifest.id
        revision = contents.manifest.revision
        history = contents.history
        baseImagePNG = contents.baseImagePNG
        createdAt = contents.manifest.createdAt
        self.actor = actor
        self.recovery = recovery
        self.projectURL = projectURL
        workingName = contents.manifest.workingName
        assets = contents.assets
        assetInfos = contents.manifest.assets
        assetImages = contents.assets.compactMapValues(ImageLoader.cgImage(from:))
        // A project opened from disk is clean; a recovered one is not (its
        // recovery package may be ahead of the saved project, if any).
        lastSavedRevision = isRecovered ? nil : contents.manifest.revision
        historyWritten = isRecovered ? contents.history.count : 0
        recoveryWritten = isRecovered
    }

    var isDirty: Bool { lastSavedRevision != revision }

    var recoveryURL: URL { recovery.url(for: id) }

    /// Display name: the project's file name, else the working name, else
    /// "Untitled".
    var name: String {
        projectURL?.deletingPathExtension().lastPathComponent ?? workingName ?? "Untitled"
    }

    /// The saved project moved on disk (a rename): follow it.
    func rebind(to url: URL) {
        projectURL = url
    }

    // MARK: Commits

    /// Records a committed change: bumps the revision and appends the history
    /// entry. Returns the entry. The caller autosaves next.
    @discardableResult
    func record(before: Document, after: Document, actor: HistoryActor? = nil, reason: String? = nil) -> HistoryEntry {
        let entry = HistoryEntry.diff(from: before, to: after, actor: actor ?? self.actor,
                                      revisionBefore: revision, reason: reason)
        revision = entry.revisionAfter
        history.append(entry)
        return entry
    }

    /// Adds a pasted image to the asset store and returns its id. Assets are
    /// immutable and never pruned, so undo and history stay reversible.
    func registerAsset(png: Data, image: CGImage) -> UUID {
        let id = UUID()
        assets[id] = png
        assetImages[id] = image
        assetInfos.append(AssetInfo(id: id, fileName: ProjectPackage.assetFileName(for: id),
                                    sha256: ProjectPackage.sha256Hex(png), width: image.width, height: image.height))
        return id
    }

    /// The base image changed (destructive crop or its undo): remember the
    /// new bytes so the next autosave rewrites the package.
    func replaceBaseImage(_ png: Data) {
        baseImagePNG = png
        baseImageChanged = true
    }

    // MARK: Manifest

    func manifest(for document: Document, boundTo url: URL?) -> ProjectManifest {
        let size = ProjectPackage.pngPixelSize(baseImagePNG)
        return ProjectManifest(
            id: id, revision: revision, canvasSize: document.canvasSize, crop: document.crop,
            elements: document.elements, createdAt: createdAt, updatedAt: Date(),
            baseImage: BaseImageInfo(fileName: ProjectPackage.baseImageName,
                                     sha256: ProjectPackage.sha256Hex(baseImagePNG),
                                     width: size?.width ?? Int(document.canvasSize.width),
                                     height: size?.height ?? Int(document.canvasSize.height)),
            assets: assetInfos,
            grid: document.grid,
            workingName: workingName,
            boundProjectPath: url?.path, textPreferences: document.textPreferences)
    }

    // MARK: Recovery autosave

    /// Shadows the document into the recovery package: the whole package on
    /// the first write or after a base-image change, else the manifest plus
    /// the history entries not yet written. Synchronous, so a crash right
    /// after return loses nothing committed. The preview follows on a delay.
    func autosave(document: Document, preview: @escaping @MainActor () -> Data?) {
        do {
            try FileManager.default.createDirectory(at: recovery.directory, withIntermediateDirectories: true)
            let manifest = manifest(for: document, boundTo: projectURL)
            if !recoveryWritten || baseImageChanged {
                try ProjectPackage.create(at: recoveryURL, manifest: manifest, baseImagePNG: baseImagePNG,
                                          preview: nil, history: history, assets: assets)
                recoveryWritten = true
                baseImageChanged = false
            } else {
                try ProjectPackage.update(at: recoveryURL, manifest: manifest, preview: nil,
                                          appending: Array(history[historyWritten...]), assets: assets)
            }
            historyWritten = history.count
            autosaveError = nil
        } catch {
            autosaveError = (error as? ProjectError)?.errorDescription ?? error.localizedDescription
            return
        }
        schedulePreview(preview)
    }

    private func schedulePreview(_ render: @escaping @MainActor () -> Data?) {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: Self.previewDelay)
            guard !Task.isCancelled, let self, let png = render() else { return }
            try? png.write(to: self.recoveryURL.appendingPathComponent(ProjectPackage.previewName))
        }
    }

    /// Flattened at most `previewLongSide` on the long side.
    static func previewPNG(document: Document, baseImage: CGImage?, assets: [UUID: CGImage] = [:]) -> Data? {
        let longSide = max(document.canvasSize.width, document.canvasSize.height)
        let scale = longSide > previewLongSide ? previewLongSide / longSide : 1
        guard let image = Renderer.flatten(document, baseImage: baseImage, scale: scale, assets: assets) else { return nil }
        return Renderer.encode(image, as: .png)
    }

    /// A clean close: the recovery package is no longer needed.
    func removeRecovery() {
        previewTask?.cancel()
        try? FileManager.default.removeItem(at: recoveryURL)
        recoveryWritten = false
    }

    // MARK: Save

    /// Writes the whole package to `url` and binds the document to it. Save As
    /// with a new identity passes `newIdentity: true`.
    func save(document: Document, to url: URL, preview: Data?, newIdentity: Bool) throws {
        let previousID = id
        if newIdentity { id = UUID() }
        let manifest = manifest(for: document, boundTo: nil)
        do {
            try ProjectPackage.create(at: url, manifest: manifest, baseImagePNG: baseImagePNG,
                                      preview: preview, history: history, assets: assets)
        } catch {
            id = previousID
            throw error
        }
        projectURL = url
        lastSavedRevision = revision
        // The recovery package records the binding (and the new id) on the
        // next autosave; an old-identity package would otherwise linger.
        if newIdentity {
            try? FileManager.default.removeItem(at: recovery.url(for: previousID))
            recoveryWritten = false
        }
    }
}
