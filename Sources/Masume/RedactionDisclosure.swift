import Foundation

/// When to tell the user that a `.masume` project contains the original,
/// unredacted image: on the first save of each document, until they opt out
/// for good. Pure policy over a `UserDefaults`, so it is testable without an
/// alert.
@MainActor
enum RedactionDisclosure {
    static let suppressKey = "suppressRedactionDisclosure"

    static let title = "This project will contain the original image"
    static let body = """
        A Masume project keeps the unredacted original so you can keep editing. \
        Anyone who can open it can see what pixelation hides. \
        To share a redacted result, use Create Share-Safe Copy, which writes only the flattened pixels.
        """

    static func shouldShow(project: ProjectSession, defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: suppressKey) && !project.disclosureShown
    }

    static func recordShown(project: ProjectSession, suppress: Bool, defaults: UserDefaults) {
        project.disclosureShown = true
        if suppress { defaults.set(true, forKey: suppressKey) }
    }
}
