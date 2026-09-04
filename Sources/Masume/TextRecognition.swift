import CoreGraphics
import Foundation
import Vision

/// One string recognized from the untouched base image. Bounds use the
/// cropped image's top-left pixel coordinate space; the command service
/// translates them back into full-canvas coordinates.
struct TextRecognitionLine: Equatable, Sendable {
    let text: String
    let confidence: Float
    let bounds: CGRect
}

protocol TextRecognizing: Sendable {
    func recognize(in image: CGImage, languages: [String], customWords: [String]) throws -> [TextRecognitionLine]
}

enum TextRecognitionError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        switch self {
        case .timedOut:
            "Text recognition timed out."
        }
    }
}

/// Runs Vision's macOS 15 request API off the main actor. Apple Events are a
/// synchronous request/reply transport, so the command waits for that worker
/// while preserving the command service's serialized document boundary.
struct VisionTextRecognizer: TextRecognizing {
    var timeout: TimeInterval = 30

    func recognize(in image: CGImage, languages: [String], customWords: [String]) throws -> [TextRecognitionLine] {
        let waiter = TextRecognitionWaiter()
        _ = Task.detached(priority: .userInitiated) {
            do {
                var request = RecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.customWords = customWords
                request.recognitionLanguages = languages.map(Locale.Language.init(identifier:))
                request.automaticallyDetectsLanguage = languages.isEmpty

                let observations = try await request.perform(on: image)
                let size = CGSize(width: image.width, height: image.height)
                let imageBounds = CGRect(origin: .zero, size: size)
                let lines = observations.compactMap { observation -> TextRecognitionLine? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let bounds = observation.boundingBox
                        .toImageCoordinates(size, origin: .upperLeft)
                        .intersection(imageBounds)
                    guard !bounds.isNull, !bounds.isEmpty else { return nil }
                    return TextRecognitionLine(text: candidate.string, confidence: candidate.confidence, bounds: bounds)
                }
                waiter.finish(.success(lines))
            } catch {
                waiter.finish(.failure(error))
            }
        }
        return try waiter.wait(timeout: timeout).get()
    }
}

/// A small synchronization bridge for the async Vision API. The box is
/// internally locked; `@unchecked Sendable` is the promise that no state is
/// touched outside that lock.
private final class TextRecognitionWaiter: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<[TextRecognitionLine], Error>?

    func finish(_ result: Result<[TextRecognitionLine], Error>) {
        condition.lock()
        self.result = result
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeout: TimeInterval) -> Result<[TextRecognitionLine], Error> {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while result == nil {
            guard condition.wait(until: deadline) else { return .failure(TextRecognitionError.timedOut) }
        }
        return result ?? .failure(TextRecognitionError.timedOut)
    }
}
