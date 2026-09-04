import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Masume

final class DragOutPromiseTests: XCTestCase {
    @MainActor
    func testFileNameCallbackUsesThePayloadOwnedByItsProvider() {
        let writer = DragOutPromiseWriter()
        let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: writer)
        provider.userInfo = DragOutPromise(data: Data(), fileName: "Yearbook.png")

        XCTAssertEqual(writer.filePromiseProvider(provider, fileNameForType: UTType.png.identifier), "Yearbook.png")
    }

    func testObjectiveCOperationQueueCallbackIsSafeOffMainActor() async throws {
        let writer = DragOutPromiseWriter()

        let optionalQueue = await Task.detached {
            let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: writer)
            let selector = NSSelectorFromString("operationQueueForFilePromiseProvider:")
            return writer.perform(selector, with: provider)?.takeUnretainedValue() as? OperationQueue
        }.value

        let queue = try XCTUnwrap(optionalQueue)
        XCTAssertEqual(queue.name, "com.2b3pro.masume.drag-out")
        XCTAssertEqual(queue.maxConcurrentOperationCount, 1)
    }

    func testWriteCallbackUsesThePayloadOwnedByItsProvider() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("masume-drag-out-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: destination) }
        let expected = Data([0x89, 0x50, 0x4E, 0x47])
        let writer = DragOutPromiseWriter()

        let written = try await Task.detached {
            let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: writer)
            provider.userInfo = DragOutPromise(data: expected, fileName: "Yearbook.png")
            var callbackError: Error?
            writer.filePromiseProvider(provider, writePromiseTo: destination) { callbackError = $0 }
            if let callbackError { throw callbackError }
            return try Data(contentsOf: destination)
        }.value

        XCTAssertEqual(written, expected)
    }
}
