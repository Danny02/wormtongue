import Foundation
import VoiceModeCore

#if VOICEMODE_LOCAL_PASS
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
#endif

/// The on-device rewrite pass — §8 of the brief, which asked whether sensitive
/// apps should get a local model instead of having the pass skipped entirely.
/// They should, and this is it.
///
/// Behind a build flag because MLX plus a quantised model is a large dependency
/// and a multi-GB download that most apps never need. Build it with:
///
///     ./Scripts/bundle.sh release --local-pass
///
/// Without the flag the type still exists and throws a message saying so, which
/// keeps `AppState` free of conditional compilation.
///
/// ⚠️ Least-verified file in the project: MLX's Swift API could not be compiled
/// or run here, only read. If it does not build, the three call sites to check are
/// `loadModel`, `TokenizersLoader`, and `ChatSession` — see
/// https://github.com/ml-explore/mlx-swift-lm (Libraries/MLXLMCommon).
actor LocalRewriter: Rewriter {

    #if VOICEMODE_LOCAL_PASS

    /// A factory rather than the model itself: the concrete model type is never
    /// named, so a rename upstream does not break this file. A fresh session per
    /// utterance keeps each rewrite stateless — `ChatSession` accumulates
    /// conversation history, which is the opposite of what one-shot rewriting
    /// wants.
    private var makeSession: (@Sendable () -> ChatSession)?
    private var loadedModel: String?
    private var loading: Task<Void, Error>?

    func prewarm(model: String) async {
        do {
            try await load(model)
        } catch {
            log.error(
                "local model \(model, privacy: .public) failed to load: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func load(_ model: String) async throws {
        if loadedModel == model, makeSession != nil { return }
        // Coalesce concurrent loads; the first dictation and the launch prewarm
        // can otherwise both start a multi-GB download.
        if let loading, loadedModel == model {
            try await loading.value
            return
        }
        loadedModel = model
        let task = Task {
            let started = ContinuousClock.now
            let loaded = try await loadModel(
                from: HubClient.default, using: TokenizersLoader(), id: model)
            await self.store { ChatSession(loaded) }
            log.info(
                "local model \(model, privacy: .public) ready in \(Int(started.duration(to: ContinuousClock.now).seconds * 1000))ms"
            )
        }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    private func store(_ factory: @escaping @Sendable () -> ChatSession) {
        makeSession = factory
    }

    func edit(
        model: String, system: String, user: String, maxTokens: Int, intent: EditIntent
    ) async throws -> EditDecision {
        try await load(model)
        guard let makeSession else {
            throw RewriterError.localModelUnavailable("model \(model) did not load")
        }

        // The system prompt is folded into the single turn rather than passed
        // separately: every chat template handles a plain user turn, and this
        // avoids depending on an initialiser whose signature we could not verify.
        let prompt = system + "\n\n" + user
        let reply = try await makeSession().respond(to: prompt)
        try Task.checkCancellation()
        return Self.interpret(reply, intent: intent)
    }

    #else

    func prewarm(model: String) async {}

    func edit(
        model: String, system: String, user: String, maxTokens: Int, intent: EditIntent
    ) async throws -> EditDecision {
        throw RewriterError.localPassNotBuilt
    }

    #endif

    /// A local model has no structured-output mode, so a `.revise` reply is parsed
    /// with the same tolerant parser the API path uses — which already falls back to
    /// a plain insert on anything it cannot read. That fallback matters much more
    /// here: small models are far likelier to answer in prose than in JSON.
    static func interpret(_ reply: String, intent: EditIntent) -> EditDecision {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard intent.needsDecision else {
            return EditDecision(
                action: intent == .replaceSelection ? .replaceSelection : .insert, text: text)
        }
        return AnthropicMessages.parse(decision: text)
    }
}
