import Foundation
import WormtongueCore

/// A single stateless completion per utterance over `POST /chat/completions`.
///
/// Wire types and response parsing live in `WormtongueCore.OpenAICompatibleMessages`
/// so they can be unit-tested; this is the transport. Behind the `LLMProvider`
/// seam it is the OpenAI-compatible adapter, serving the OpenRouter/DeepSeek/Groq/
/// xAI presets and any custom `chat/completions` host. No SDK — the body is
/// hand-coded like the Anthropic adapter.
actor OpenAICompatibleClient: LLMProvider {
    private let session: URLSession
    /// The resolved host for `chat/completions` — a preset host or a custom URL.
    /// `nil` until a usable base URL resolves, so an unset custom URL can never
    /// accidentally point at a working default host.
    private var endpoint: URL?
    /// The active preset: it declares the structured-output capability per host.
    private var preset: OpenAICompatPreset = .custom

    init(timeout: TimeInterval = 60) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        // One host, one request in flight; keep the connection pooled between them.
        configuration.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: configuration)
    }

    /// Applied on every config load. `endpoint` is nil when the base URL does not
    /// resolve yet; the capability is still declared from the preset.
    func configure(endpoint: URL?, preset: OpenAICompatPreset) {
        self.endpoint = endpoint
        self.preset = preset
    }

    /// Structured output is declared per host by the preset, never probed at
    /// runtime. Async so the actor can read its own configured preset safely.
    func supportsStructuredOutput() async -> Bool { preset.supportsStructuredOutput }

    /// Verifies the configured host + stored key with a real one-token call.
    /// Returns nil on success, or a human-readable failure reason. `model` is the
    /// resolved model string so readiness reflects the model dictation will use.
    func healthCheck(model: String) async -> String? {
        guard let endpoint else { return "No base URL set for the OpenAI-compatible provider." }
        guard let apiKey = Keychain.apiKey(for: .openAICompatible) else {
            return "No API key stored in the Keychain."
        }
        var request = URLRequest(url: chatCompletionsURL(endpoint))
        request.httpMethod = "POST"
        request.httpBody = try? OpenAICompatibleMessages.Request(
            model: model, system: "ping", user: "ping", maxTokens: 1, structured: .none
        ).encoded()
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return nil }
            let detail = try? OpenAICompatibleMessages.text(fromStatus: status, body: data)
            return "HTTP \(status)\(detail.map { ": \($0)" } ?? "")"
        } catch {
            return error.localizedDescription
        }
    }

    /// Rewrites the utterance, leaving the edit decision to the seam.
    ///
    /// `.compose` and `.replaceSelection` are deterministic, so the request asks
    /// for plain text. Only `.revise` — a draft with no selection — needs the
    /// model to choose between adding and rewriting, and only that shape pays for
    /// structured output (and only on a host that declares it can express one).
    func complete(prompt: LLMPrompt) async throws -> LLMCompletion {
        guard let endpoint else { throw OpenAICompatibleError.missingBaseURL }
        let structured: OpenAICompatStructured =
            prompt.intent.needsDecision && preset.supportsStructuredOutput
            ? preset.structuredMode : .none
        let body = try OpenAICompatibleMessages.Request(
            model: prompt.model,
            system: systemContent(for: prompt, structured: structured),
            user: prompt.user,
            maxTokens: prompt.maxTokens,
            structured: structured
        ).encoded()

        let data: Data
        let status: Int
        do {
            (status, data) = try await send(body, to: endpoint)
        } catch let error as OpenAICompatibleError where error.isRetryable {
            // A 429 or 5xx is worth exactly one more shot; anything else is our bug.
            log.notice("retrying after \(error.localizedDescription, privacy: .public)")
            try await Task.sleep(for: .milliseconds(250))
            (status, data) = try await send(body, to: endpoint)
        }

        let completion = try OpenAICompatibleMessages.completion(fromStatus: status, body: data)
        return LLMCompletion(text: completion.text, thinking: completion.thinking)
    }

    private func chatCompletionsURL(_ endpoint: URL) -> URL {
        endpoint.appending(path: "chat/completions")
    }

    private func send(_ body: Data, to endpoint: URL) async throws -> (status: Int, data: Data) {
        guard let apiKey = Keychain.apiKey(for: .openAICompatible) else {
            throw OpenAICompatibleError.missingAPIKey
        }

        var request = URLRequest(url: chatCompletionsURL(endpoint))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw OpenAICompatibleError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw OpenAICompatibleError.cancelled
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Retry classification needs the typed error, so surface HTTP failures here
        // and leave body interpretation to the caller.
        if !(200..<300).contains(status) {
            _ = try OpenAICompatibleMessages.text(fromStatus: status, body: data)
        }
        return (status, data)
    }

    /// JSON-object mode wants the model told it emits JSON, and the seam's
    /// `EditDecisionJSON` parser needs the exact decision shape. Only that mode
    /// augments the system prompt; plain-text requests stay untouched.
    private func systemContent(for prompt: LLMPrompt, structured: OpenAICompatStructured) -> String
    {
        guard structured == .jsonObject else { return prompt.system }
        return
            prompt.system
            + "\n\nRespond with a single JSON object only, of the form "
            + #"{"action":"insert"|"replace_all","text":"<your rewritten text>"}"#
            + ". The value of \"action\" must be exactly \"insert\" or \"replace_all\"."
    }
}
