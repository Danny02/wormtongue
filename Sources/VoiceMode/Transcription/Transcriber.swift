import Foundation
import WhisperKit

/// Local Whisper via WhisperKit (CoreML + Metal). Audio never leaves the machine.
///
/// The model is downloaded from Hugging Face on first use, so `prewarm()` should
/// run at launch — otherwise the first dictation eats the download.
actor Transcriber {
    private var pipe: WhisperKit?
    private var loadedModel: String?
    private(set) var isLoading = false

    /// Loads (and on first run downloads) the model. Safe to call repeatedly.
    func prewarm(model: String) async throws {
        if pipe != nil, loadedModel == model { return }
        isLoading = true
        defer { isLoading = false }
        let started = Date()
        pipe = try await WhisperKit(WhisperKitConfig(model: model))
        loadedModel = model
        log.info(
            "whisper model \(model, privacy: .public) ready in \(Int(Date().timeIntervalSince(started) * 1000))ms"
        )
    }

    func transcribe(_ samples: [Float], model: String) async throws -> String {
        try await prewarm(model: model)
        guard let pipe else { return "" }
        // If the compiler complains about overload ambiguity here, WhisperKit has
        // dropped the optional-returning form; use:
        //   let text = try await pipe.transcribe(audioArray: samples).map(\.text).joined(separator: " ")
        let text = try await pipe.transcribe(audioArray: samples)?.text ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
