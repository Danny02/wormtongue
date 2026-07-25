import Foundation

public enum AnthropicError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case http(status: Int, type: String?, message: String)
    case emptyResponse
    case refused(category: String?)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Anthropic API key. Add one in Setup, or export ANTHROPIC_API_KEY."
        case let .http(status, type, message):
            return "Anthropic API \(status)\(type.map { " (\($0))" } ?? ""): \(message)"
        case .emptyResponse:
            return "Anthropic API returned no text content."
        case let .refused(category):
            return "Request was refused\(category.map { " (\($0))" } ?? "")."
        case .cancelled:
            return "Cancelled."
        }
    }

    /// 429 and 5xx are worth one retry; everything else is a bug in our request.
    public var isRetryable: Bool {
        if case let .http(status, _, _) = self { return status == 429 || status >= 500 }
        return false
    }
}

/// Wire types for `POST /v1/messages`.
///
/// A single stateless completion per utterance. Not the Claude Agent SDK
/// (Python/TypeScript only, built for multi-turn tool loops) and not an official
/// Swift SDK — there isn't one — so this is the raw HTTP shape.
public enum AnthropicMessages {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// GET-able, free, and cheap: used only to warm the TLS connection.
    public static let modelsEndpoint = URL(string: "https://api.anthropic.com/v1/models")!
    public static let apiVersion = "2023-06-01"

    public struct Request: Encodable, Sendable {
        public struct Message: Encodable, Sendable {
            public let role: String
            public let content: String
        }

        public let model: String
        public let maxTokens: Int
        public let system: String
        public let messages: [Message]

        // No `thinking` block: latency matters more than depth for a rewrite pass,
        // and Haiku 4.5 does not think unless asked.
        public init(model: String, system: String, user: String, maxTokens: Int) {
            self.model = model
            self.system = system
            self.maxTokens = maxTokens
            self.messages = [Message(role: "user", content: user)]
        }

        public func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            return try encoder.encode(self)
        }
    }

    struct Response: Decodable {
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
        struct StopDetails: Decodable {
            let category: String?
        }

        let content: [ContentBlock]?
        let stopReason: String?
        let stopDetails: StopDetails?
    }

    struct ErrorEnvelope: Decodable {
        struct Payload: Decodable {
            let type: String?
            let message: String?
        }
        let error: Payload?
    }

    /// Turns an HTTP status plus body into either the rewritten text or a typed
    /// error. Pure, so it can be tested without a network.
    public static func text(fromStatus status: Int, body: Data) throws -> String {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        guard (200..<300).contains(status) else {
            let envelope = try? decoder.decode(ErrorEnvelope.self, from: body)
            throw AnthropicError.http(
                status: status,
                type: envelope?.error?.type,
                message: envelope?.error?.message
                    ?? String(data: body, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "no body"
            )
        }

        guard let response = try? decoder.decode(Response.self, from: body) else {
            throw AnthropicError.http(
                status: status, type: nil, message: "unparseable response body")
        }

        // Check stop_reason before reading content: a refusal comes back 200 with
        // an empty content array, and indexing content[0] would crash on it.
        if response.stopReason == "refusal" {
            throw AnthropicError.refused(category: response.stopDetails?.category)
        }

        let text = (response.content ?? [])
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { throw AnthropicError.emptyResponse }
        return text
    }
}
