import AppKit
import Foundation
import AnnotationModel

// The AppleScript surface declared in Resources/Masume.sdef: the read-only
// `active document` with its properties, and the `execute` verb over the
// command service. Apple Events arrive serialized on the main run loop, so
// each call runs whole between human edits; the revision assertion happens
// inside the service.

/// The `document` class: a KVC view of the active tab's project session.
/// Apple Events are delivered on the main thread, so the whole object is
/// main-actor isolated; KVC reaches its getters through Objective-C, which
/// does not check isolation, and they run where they must.
@MainActor
@objc(ScriptableDocument)
final class ScriptableDocument: NSObject {
    private let controller: CanvasController

    init(controller: CanvasController) {
        self.controller = controller
    }

    /// `active document` is a property of the application, so the specifier
    /// is that property; there is no index or name lookup.
    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let application = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSPropertySpecifier(containerClassDescription: application, containerSpecifier: nil, key: "activeDocument")
    }

    @objc var documentID: String { controller.project?.id.uuidString ?? "" }
    @objc var revision: Int { controller.project?.revision ?? 0 }
    @objc var name: String { controller.documentTitle }
    @objc var canvasWidth: Int { Int(controller.document?.canvasSize.width ?? 0) }
    @objc var canvasHeight: Int { Int(controller.document?.canvasSize.height ?? 0) }
    @objc var gridColumns: Int { controller.document?.grid.columns ?? 0 }
    @objc var gridRows: Int { controller.document?.grid.rows ?? 0 }
    @objc var gridVersion: Int { controller.document?.grid.version ?? 0 }
    @objc var dirty: Bool { controller.isDirty }
    @objc var projectPath: String? { controller.project?.projectURL?.path }
}

/// The `execute` verb. Malformed JSON is the only scripting error it
/// raises; every other outcome is an envelope, so a client has one shape
/// to parse.
@objc(ExecuteScriptCommand)
final class ExecuteScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let json = directParameter as? String, let data = json.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            scriptErrorNumber = NSCannotCreateScriptCommandError
            scriptErrorString = "execute takes a JSON object as its direct parameter"
            return nil
        }
        let envelope: String = MainActor.assumeIsolated {
            guard let workspace = AppDelegate.current?.workspace else {
                return CommandResponse.failure(.io("Masume is not ready")).encodedString
            }
            let data = CommandService(controller: workspace.active).execute(json: data)
            return String(data: data, encoding: .utf8) ?? CommandResponse.failure(.io("encoding failed")).encodedString
        }
        return envelope
    }
}

extension CommandResponse {
    var encodedString: String { String(data: encoded(), encoding: .utf8) ?? "{\"ok\":false}" }
}

extension AppDelegate {
    /// `active document` lives on the application; the delegate answers for
    /// that key so NSApplication needs no subclass.
    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        key == "activeDocument"
    }

    @objc var activeDocument: ScriptableDocument? {
        workspace.active.hasDocument ? ScriptableDocument(controller: workspace.active) : nil
    }
}
