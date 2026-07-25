import Foundation

enum AnthropicError: LocalizedError {
    case missingAPIKey
    case http(status: Int, type: String?, message: String)
    case emptyResponse
    case refused(category: String?)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Anthropic API key. Add one in the menu, or export ANTHROPIC_API_KEY."
        case let .http(status, type, message):
            return "Anthropic API \(status)\(type.map { " (\($0))" } ?? ""): \(message)"
        case .emptyResponse:
            return "Anthropic API returned no text content."
        case let .refused(category):
            return "Request was refused\(category.map { " (\($0))" } ?? "")."
        }
    }

    /// 429 and 5xx are worth one retry; everything else is a bug in our request.
    var isRetryable: Bool {
        if case let .http(status, _, _) = self { return status == 429 || status >= 500 }
        return false
    }
}

/// A single stateless completion per utterance over `POST /v1/messages`.
///
/// Not the Claude Agent SDK (Python/TypeScript only, built for multi-turn tool
/// loops) and not an official Swift SDK (there isn't one) — plain URLSession.
struct AnthropicClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    let session: URLSession

    init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    func rewrite(model: String, system: String, user: String, maxTokens: Int) async throws -> String {
        guard let apiKey = Keychain.apiKey() else { throw AnthropicError.missingAPIKey }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")

        // No `thinking` block: latency matters more than depth for a rewrite pass,
        // and Haiku 4.5 does not think by default.
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard (200..<300).contains(status) else {
            let error = json?["error"] as? [String: Any]
            throw AnthropicError.http(
                status: status,
                type: error?["type"] as? String,
                message: error?["message"] as? String
                    ?? String(data: data, encoding: .utf8)
                    ?? "no body"
            )
        }

        // Check stop_reason before reading content: a refusal can come back 200
        // with an empty content array.
        if let stopReason = json?["stop_reason"] as? String, stopReason == "refusal" {
            let details = json?["stop_details"] as? [String: Any]
            throw AnthropicError.refused(category: details?["category"] as? String)
        }

        // content is an array of blocks; take the text ones.
        let blocks = json?["content"] as? [[String: Any]] ?? []
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { throw AnthropicError.emptyResponse }
        return text
    }
}
