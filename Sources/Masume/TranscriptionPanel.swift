import SwiftUI
import AnnotationModel

struct TranscriptionPanel: View {
    @Bindable var controller: CanvasController
    @State private var languages = ""
    @State private var customWords = ""
    @State private var readsZone = false
    @FocusState private var queryFocused: Bool

    private func read() {
        do {
            try controller.saveTextPreferences(
                languages: languages.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                customWords: customWords.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            Task { await controller.readTranscription(range: readsZone ? "zone" : nil) }
        } catch { controller.textRecognitionError = error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Find Text & Transcribe").font(.headline)
                Spacer()
                Button { controller.showsTranscription = false } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close transcription")
            }
            Text("Read text locally from the original image.").font(.caption).foregroundStyle(.secondary)
            GroupBox("Recognition preferences · saved with this document") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Languages: en-US, fr-FR (blank = automatic)", text: $languages)
                        .accessibilityLabel("Recognition languages")
                    Text("Custom words, one per line").font(.caption)
                    TextEditor(text: $customWords).frame(height: 55)
                        .accessibilityLabel("Custom words")
                    Button("Save preferences") {
                        do {
                            try controller.saveTextPreferences(
                                languages: languages.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                                customWords: customWords.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                        } catch { controller.textRecognitionError = error.localizedDescription }
                    }
                }.padding(4)
            }
            HStack {
                Picker("Read", selection: $readsZone) {
                    Text("Whole image").tag(false)
                    Text("Zone").tag(true)
                }
                Button(controller.isRecognizingText ? "Reading…" : "Read Text", action: read)
                    .disabled(controller.isRecognizingText || (readsZone && controller.zone == nil))
            }
            Text(TextMap.readingOrderNotice).font(.caption).foregroundStyle(.secondary)
            TextField("Find text in results", text: $controller.textQuery)
                .textFieldStyle(.roundedBorder)
                .focused($queryFocused)
                .onSubmit { if controller.currentTextMap == nil && !controller.isRecognizingText { read() } }
            if let error = controller.textRecognitionError { Text(error).foregroundStyle(.red).font(.caption) }
            if controller.isRecognizingText { ProgressView().controlSize(.small) }
            results
            HStack {
                Button("Copy Text") { controller.copyTranscription() }
                Button("Export Text…") { controller.exportTranscription() }
            }
            .disabled(controller.currentTextMap == nil || controller.currentTextMap?.lines.isEmpty == true)
            Text("Below 80% confidence is marked in copied and exported text. " +
                 "Confidence is the recognizer’s estimate, not verification.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 360)
        .frame(maxHeight: 660, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { loadPreferences(); readsZone = controller.zone != nil; queryFocused = true }
        .onChange(of: controller.document?.textPreferences) { _, _ in loadPreferences() }
    }

    private func loadPreferences() {
        languages = controller.document?.textPreferences.languages.joined(separator: ", ") ?? ""
        customWords = controller.document?.textPreferences.customWords.joined(separator: "\n") ?? ""
    }

    @ViewBuilder private var results: some View {
        if let map = controller.currentTextMap {
            let matches = map.matches(controller.textQuery)
            Text("\(matches.count) of \(map.lines.count) text regions").font(.caption)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(matches.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.text).textSelection(.enabled)
                            let range = map.grid.range(covering: line.bounds, in: map.canvasSize)?.name ?? ""
                            let review = line.confidence < TextMap.lowConfidenceThreshold ? " · Review" : ""
                            Text("\(range) · \(Int(line.confidence * 100))% confidence\(review)")
                                .font(.caption2)
                                .foregroundStyle(line.confidence < TextMap.lowConfidenceThreshold ? Color.orange : Color.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 80, maxHeight: .infinity)
        } else if controller.textMap != nil {
            Text("Results are stale. Read Text again for the current image, grid, zone, and preferences.").font(.caption)
        } else if !controller.isRecognizingText {
            Text("Choose Read Text to begin. Nothing is analyzed automatically.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
