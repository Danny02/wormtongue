import Foundation
import VoiceModeCore

/// A single stateless completion per utterance over `POST /v1/messages`.
///
/// Wire types and response parsing live in `VoiceModeCore.AnthropicMessages` so
/// they can be unit-tested; this is the transport.
actor AnthropicClient {
    private let session: URLSession
    /// HTTP/2 connections idle out after about a minute, so re-warming more often
    /// than that is wasted work and less often is a cold handshake.
    private let warmInterval = Duration.seconds(50)
    private var lastWarmed: ContinuousClock.Instant?

    init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        // One host, one request in flight; keep the connection pooled between them.
        configuration.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: configuration)
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

        var request = URLRequest(url: AnthropicMessages.modelsEndpoint)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(AnthropicMessages.apiVersion, forHTTPHeaderField: "anthropic-version")
        // Result is irrelevant — we only want the socket open.
        _ = try? await session.data(for: request)
    }

    /// Rewrites the utterance and says what to do with the result.
    ///
    /// `.compose` and `.replaceSelection` are deterministic, so they ask for plain
    /// text. Only `.revise` — a draft with no selection — needs the model to choose
    /// between adding and rewriting, and only that shape pays for structured output.
    func edit(
        model: String, system: String, user: String, maxTokens: Int, intent: EditIntent
    ) async throws -> EditDecision {
        let structured = intent.needsDecision
        let body = try AnthropicMessages.Request(
            model: model, system: system, user: user, maxTokens: maxTokens,
            structured: structured
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

        guard structured else {
            let text = try AnthropicMessages.text(fromStatus: status, body: data)
            return EditDecision(
                action: intent == .replaceSelection ? .replaceSelection : .insert, text: text)
        }
        return try AnthropicMessages.decision(fromStatus: status, body: data)
    }

    private func send(_ body: Data) async throws -> (status: Int, data: Data) {
        guard let apiKey = Keychain.apiKey() else { throw AnthropicError.missingAPIKey }

        var request = URLRequest(url: AnthropicMessages.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(AnthropicMessages.apiVersion, forHTTPHeaderField: "anthropic-version")

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
}
