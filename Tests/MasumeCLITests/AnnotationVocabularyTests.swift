import XCTest
@testable import MasumeCLI

final class AnnotationVocabularyTests: XCTestCase {
    func testRectangleStyleKeysReachCommandServiceUnchanged() throws {
        let request = try CLIRequest.build("add", arguments: ["rounded_rectangle", "over=B2:C3", "cornerRadius=16", "shadow=false"],
                                           flags: [:], options: CLIRequest.Options())
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["type"] as? String, "rounded_rectangle")
        XCTAssertEqual(params["cornerRadius"] as? Int, 16)
        XCTAssertEqual(params["shadow"] as? Bool, false)
        let highlight = try CLIRequest.build("add", arguments: ["highlight", "over=B2:C3", "opacity=0.3"],
                                             flags: [:], options: CLIRequest.Options())
        XCTAssertEqual((highlight["params"] as? [String: Any])?["opacity"] as? Double, 0.3)
    }

    func testTextPreferencesPreserveOmittedFieldsAndAllowExplicitClear() throws {
        let request = try CLIRequest.build("text-preferences", arguments: [], flags: ["languages": "en-US,fr-FR"],
                                           options: CLIRequest.Options(documentId: "D", expectedRevision: 3))
        XCTAssertEqual(request["command"] as? String, "set_text_preferences")
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["languages"] as? [String], ["en-US", "fr-FR"])
        XCTAssertNil(params["customWords"])
        let clear = try CLIRequest.build("text-preferences", arguments: [], flags: ["custom-words": ""], options: CLIRequest.Options())
        XCTAssertEqual((clear["params"] as? [String: Any])?["customWords"] as? [String], [])
        XCTAssertTrue(CLIRequest.mutations.contains("text-preferences"))
    }
}
