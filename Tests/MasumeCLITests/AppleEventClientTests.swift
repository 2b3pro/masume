import AppKit
import XCTest
@testable import MasumeCLI

final class AppleEventClientTests: XCTestCase {
    func testNumericAutomationDenialIsNotReportedAsMissingResult() throws {
        let reply = makeReply()
        reply.setParam(NSAppleEventDescriptor(int32: Int32(errAEEventNotPermitted)),
                       forKeyword: AEKeyword(keyErrorNumber))

        let response = try decodedEnvelope(AppleEventClient.response(from: reply))

        XCTAssertEqual(response["ok"] as? Bool, false)
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "io")
        XCTAssertTrue((error["message"] as? String)?.contains("-1743") == true)
        XCTAssertTrue((error["message"] as? String)?.contains("Automation") == true)
        XCTAssertTrue((error["message"] as? String)?.contains("terminal or editor") == true)
        XCTAssertFalse((error["message"] as? String)?.contains("returned no result") == true)
    }

    func testNumericAppleEventErrorIncludesAvailableDetail() throws {
        let reply = makeReply()
        reply.setParam(NSAppleEventDescriptor(int32: -1712), forKeyword: AEKeyword(keyErrorNumber))
        reply.setParam(NSAppleEventDescriptor(string: "Timed out"), forKeyword: AEKeyword(keyErrorString))

        let response = try decodedEnvelope(AppleEventClient.response(from: reply))
        let error = try XCTUnwrap(response["error"] as? [String: Any])

        XCTAssertEqual(error["message"] as? String, "Apple Event failed (-1712): Timed out")
    }

    func testSuccessfulReplyReturnsDirectObject() throws {
        let reply = makeReply()
        let expected = #"{"ok":true,"result":{"revision":3}}"#
        reply.setParam(NSAppleEventDescriptor(string: expected), forKeyword: AEKeyword(keyDirectObject))

        XCTAssertEqual(String(data: AppleEventClient.response(from: reply), encoding: .utf8), expected)
    }

    private func makeReply() -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEAnswer),
            targetDescriptor: NSAppleEventDescriptor.null(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    private func decodedEnvelope(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
