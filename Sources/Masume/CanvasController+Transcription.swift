import AppKit
import AnnotationModel
import MasumeCommands
import UniformTypeIdentifiers

extension CanvasController {
    var currentTextMap: TextMap? {
        guard let map = textMap, let project, let document,
              map.documentID == project.id, map.grid == document.grid,
              map.canvasSize == document.canvasSize, map.documentPreferences == document.textPreferences,
              map.baseImagePNG == project.baseImagePNG else { return nil }
        if map.requested?.lowercased() == "zone", map.zone != zone { return nil }
        return map
    }

    func readTranscription(range: String?, recognizer: any TextRecognizing = VisionTextRecognizer()) async {
        guard !isRecognizingText else { return }
        let requestID = UUID()
        textRecognitionID = requestID
        isRecognizingText = true
        textRecognitionError = nil
        textMap = nil
        defer {
            if textRecognitionID == requestID { isRecognizingText = false }
        }
        do {
            let request = CommandRequest(command: "read_text", params: .object(range.map { ["range": .string($0)] } ?? [:]))
            let job = try CommandService(controller: self).prepareTextRecognition(request)
            let result = try await Task.detached(priority: .userInitiated) { try job.run(using: recognizer) }.value
            guard textRecognitionID == requestID, !Task.isCancelled else { return }
            textMap = result
            guard currentTextMap != nil else {
                textMap = nil
                textRecognitionError = "The image, grid, zone, or preferences changed. Read the text again."
                return
            }
        } catch {
            if textRecognitionID == requestID { textRecognitionError = error.localizedDescription }
        }
    }

    func saveTextPreferences(languages: [String], customWords: [String]) throws {
        guard let project else { throw CommandError.notFound("no document is open") }
        let request = CommandRequest(command: "set_text_preferences", documentId: project.id.uuidString,
                                     expectedRevision: project.revision, actorId: "human", actorName: "You",
                                     params: .object(["languages": .array(languages.map(JSONValue.string)),
                                                      "customWords": .array(customWords.map(JSONValue.string))]))
        let response = CommandService(controller: self).execute(request)
        if case .failure(let error) = response { throw error }
    }

    func copyTranscription() {
        guard let map = currentTextMap else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(map.transcription, forType: .string)
    }

    func exportTranscription() {
        guard currentTextMap != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(documentTitle)-transcription.txt"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try writeTranscription(to: url) } catch { textRecognitionError = error.localizedDescription }
        }
    }

    func writeTranscription(to url: URL) throws {
        guard let map = currentTextMap else { throw CommandError.conflict("Read Text again before exporting; these results are stale.") }
        try map.transcription.write(to: url, atomically: true, encoding: .utf8)
    }
}
