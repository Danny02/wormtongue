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

    /// Where model weights live: ~/Library/Application Support/VoiceMode/models.
    ///
    /// WhisperKit's default is ~/Documents/huggingface, which is a TCC-protected
    /// folder. Without that grant the download half-succeeds and then fails on the
    /// cleanup of its own metadata files — reported as "Model not found", which
    /// sends you looking for the wrong problem. Application Support needs no grant.
    static let downloadBase: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/VoiceMode/models")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Whether the weights are already on disk, so the UI can say "downloading"
    /// rather than "loading" for the one run that takes minutes. WhisperKit does
    /// both inside its initialiser, so this is the only point to tell them apart.
    ///
    /// Matches on suffix because the config name ("base") is the tail of the
    /// downloaded folder name ("openai_whisper-base").
    func isDownloaded(model: String) -> Bool {
        let repo = Self.downloadBase.appending(
            path: "models/argmaxinc/whisperkit-coreml", directoryHint: .isDirectory)
        let variants =
            (try? FileManager.default.contentsOfDirectory(atPath: repo.path())) ?? []
        return variants.contains { $0.hasSuffix(model) }
    }

    /// Loads (and on first run downloads) the model. Safe to call repeatedly.
    func prewarm(model: String) async throws {
        if pipe != nil, loadedModel == model { return }
        isLoading = true
        defer { isLoading = false }
        let started = Date()
        pipe = try await WhisperKit(
            WhisperKitConfig(model: model, downloadBase: Self.downloadBase))
        loadedModel = model
        log.info(
            "whisper model \(model, privacy: .public) ready in \(Int(Date().timeIntervalSince(started) * 1000))ms"
        )
    }

    /// `language` is a Whisper code ("en", "de"); nil detects it per utterance.
    ///
    /// The options are not optional. WhisperKit's defaults are `language: nil`
    /// with `usePrefillPrompt: true`, which makes `detectLanguage` false and
    /// forces the `<|en|>` token — German dictated into that comes back garbled
    /// or half-translated.
    func transcribe(_ samples: [Float], model: String, language: String?) async throws -> String {
        try await prewarm(model: model)
        guard let pipe else { return "" }
        let options = DecodingOptions(language: language, detectLanguage: language == nil)
        // If the compiler complains about overload ambiguity here, WhisperKit has
        // dropped the optional-returning form; use:
        //   let text = try await pipe.transcribe(audioArray: samples, decodeOptions: options).map(\.text).joined(separator: " ")
        let text = try await pipe.transcribe(audioArray: samples, decodeOptions: options)?.text ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
