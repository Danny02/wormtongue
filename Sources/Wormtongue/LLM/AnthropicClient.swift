import Foundation
import WormtongueCore

/// A single stateless completion per utterance over `POST /v1/messages`.
///
/// Wire types and response parsing live in `WormtongueCore.AnthropicMessages` so
/// they can be unit-tested; this is the transport. Behind the `LLMProvider` seam
/// it is the first adapter; the pipeline never names it directly.
actor AnthropicClient: LLMProvider {
    private let session: URLSession
    /// Overridable so the app can be pointed at a gateway or a local mock.
    private var endpoint: APIEndpoint = .anthropic
    private var extraHeaders: [String: String] = [:]
    /// HTTP/2 connections idle out after about a minute, so re-warming more often
    /// than that is wasted work and less often is a cold handshake.
    private let warmInterval = Duration.seconds(50)
    private var lastWarmed: ContinuousClock.Instant?

    // DeepSeek emits a sizeable thinking block before the answer, and a real
    // utterance ships up to context_char_cap of surrounding text — together easy
    // to exceed a 15s budget. 60s keeps dictation from spuriously timing out
    // while still bounding a wedged request.
    init(timeout: TimeInterval = 60) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        // One host, one request in flight; keep the connection pooled between them.
        configuration.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: configuration)
    }

    /// Structured outputs are supported: the Messages API's `output_config` ships
    /// the JSON decision a `.revise` needs. Declared statically; never
    /// feature-detected.
    nonisolated var supportsStructuredOutput: Bool { true }

    /// Applied on every config load.
    func configure(endpoint: APIEndpoint, headers: [String: String]) {
        if endpoint != self.endpoint {
            // A different host means the warm connection is to the wrong place.
            lastWarmed = nil
            log.info("API endpoint set to \(endpoint.base.absoluteString, privacy: .public)")
        }
        self.endpoint = endpoint
        self.extraHeaders = headers
    }

    /// Opens the TLS connection ahead of the real request.
    ///
    /// `/v1/models` is a free GET, so this costs nothing but saves the DNS + TCP +
    /// TLS + HTTP/2 handshake — 100–300 ms — from the first rewrite after an idle
    /// period. Called on key-down, which is the moment we know a request is likely
    /// and have a second of recording to hide it behind.
    func warmConnection() async {
        guard let apiKey = Keychain.apiKey() else { return }
        if let lastWarmed, lastWarmed.duration(to: ContinuousClock.now) < warmInterval { return }
        lastWarmed = ContinuousClock.now

        var request = URLRequest(url: endpoint.models)
        request.httpMethod = "GET"
        applyHeaders(to: &request, apiKey: apiKey)
        // Result is irrelevant — we only want the socket open.
        _ = try? await session.data(for: request)
    }

    /// Verifies the configured endpoint + stored key with a real one-token call.
    /// Returns nil on success, or a human-readable failure reason.
    func healthCheck() async -> String? {
        guard let apiKey = Keychain.apiKey() else {
            return "No API key stored in the Keychain."
        }
        var request = URLRequest(url: endpoint.messages)
        request.httpMethod = "POST"
        request.httpBody = try? AnthropicMessages.Request(
            model: "deepseek/deepseek-v4-flash", system: "ping", user: "ping",
            maxTokens: 1
        ).encoded()
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        applyHeaders(to: &request, apiKey: apiKey)
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return nil }
            let detail = try? AnthropicMessages.text(fromStatus: status, body: data)
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
    /// structured output.
    func complete(prompt: LLMPrompt) async throws -> LLMCompletion {
        let structured = prompt.intent.needsDecision
        let body = try AnthropicMessages.Request(
            model: prompt.model, system: prompt.system, user: prompt.user,
            maxTokens: prompt.maxTokens, structured: structured
        ).encoded()

        let data: Data
        let status: Int
        do {
            (status, data) = try await send(body)
        } catch let error as AnthropicError where error.isRetryable {
            // A 429 or 5xx is worth exactly one more shot; anything else is our bug.
            log.notice("retrying after \(error.localizedDescription, privacy: .public)")
            try await Task.sleep(for: .milliseconds(250))
            (status, data) = try await send(body)
        }

        let completion = try AnthropicMessages.completion(fromStatus: status, body: data)
        return LLMCompletion(text: completion.text, thinking: completion.thinking)
    }

    private func send(_ body: Data) async throws -> (status: Int, data: Data) {
        guard let apiKey = Keychain.apiKey() else { throw AnthropicError.missingAPIKey }

        var request = URLRequest(url: endpoint.messages)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        applyHeaders(to: &request, apiKey: apiKey)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw AnthropicError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw AnthropicError.cancelled
        }

        lastWarmed = ContinuousClock.now  // the connection is demonstrably warm now
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Retry classification needs the typed error, so surface HTTP failures here
        // and leave body interpretation to the caller.
        if !(200..<300).contains(status) {
            _ = try AnthropicMessages.text(fromStatus: status, body: data)
        }
        return (status, data)
    }

    /// Extra headers go on first so the built-ins win: the API key comes from the
    /// Keychain and must not be overridable from a plaintext config file.
    private func applyHeaders(to request: inout URLRequest, apiKey: String) {
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(AnthropicMessages.apiVersion, forHTTPHeaderField: "anthropic-version")
    }
}
