import AppKit
import Foundation

/// Sends the `execute` Apple Event (class `Msum`, id `Exec`, declared in
/// Masume.sdef) to the running app and returns the envelope it answers
/// with. Built with `NSAppleEventDescriptor` directly: no `osascript`, no
/// JXA, and the Automation grant attaches to this binary.
public enum AppleEventClient {
    public static let bundleIdentifier = "com.2b3pro.masume"
    static let eventClass = FourCharCode(fromString: "Msum")
    static let eventID = FourCharCode(fromString: "Exec")

    public static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// The envelope JSON, or `CLIError.notRunning`; an Apple Event failure
    /// (a malformed request, or an app that will not answer) is returned as
    /// an envelope with code `io` so callers have one shape to parse.
    public static func execute(_ requestJSON: Data, timeoutSeconds: TimeInterval = 30) throws -> Data {
        guard isRunning else { throw CLIError.notRunning }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(eventClass), eventID: AEEventID(eventID),
                                           targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        let json = String(data: requestJSON, encoding: .utf8) ?? "{}"
        event.setParam(NSAppleEventDescriptor(string: json), forKeyword: AEKeyword(keyDirectObject))
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: timeoutSeconds)
            if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue {
                return envelope(code: "io", message: error)
            }
            guard let result = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else {
                return envelope(code: "io", message: "Masume returned no result")
            }
            return Data(result.utf8)
        } catch {
            return envelope(code: "io", message: "Apple Event failed: \(error.localizedDescription)")
        }
    }

    static func envelope(code: String, message: String) -> Data {
        let object: [String: Any] = ["ok": false, "error": ["code": code, "message": message]]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

extension FourCharCode {
    init(fromString string: String) {
        var code: FourCharCode = 0
        for byte in string.utf8.prefix(4) { code = code << 8 | FourCharCode(byte) }
        self = code
    }
}
