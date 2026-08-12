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
    public static let apiVersion = "2023-06-01"

    // MARK: - Request

    public struct Request: Encodable, Sendable {
        public struct Message: Encodable, Sendable {
            public let role: String
            public let content: String
        }

        public let model: String
        public let maxTokens: Int
        public let system: String
        public let messages: [Message]
        /// Present only for `.revise`, where we need a decision and not just text.
        public let outputConfig: OutputConfig?
        /// Explicit `thinking: disabled`. Models that reason by default (DeepSeek,
        /// newer Claude) roughly double latency with a thinking block; a rewrite
        /// pass is mechanical, so we always opt out.
        public let thinking: Thinking = Thinking()

        public struct Thinking: Encodable, Sendable {
            public let type = "disabled"
        }

        // Keys are spelled out rather than using `.convertToSnakeCase`, because
        // that strategy would also rewrite the JSON Schema's own `additionalProperties`
        // key and the API would reject the schema.
        enum CodingKeys: String, CodingKey {
            case model, system, messages, thinking
            case maxTokens = "max_tokens"
            case outputConfig = "output_config"
        }

        public init(
            model: String, system: String, user: String, maxTokens: Int,
            structured: Bool = false
        ) {
            self.model = model
            self.system = system
            self.maxTokens = maxTokens
            self.messages = [Message(role: "user", content: user)]
            self.outputConfig = structured ? OutputConfig.decision : nil
        }

        public func encoded() throws -> Data {
            try JSONEncoder().encode(self)
        }
    }

    /// Structured outputs, so a revision comes back as a decision we can act on
    /// rather than prose we have to guess at.
    public struct OutputConfig: Encodable, Sendable {
        public let format: Format

        public struct Format: Encodable, Sendable {
            public let type = "json_schema"
            public let schema = DecisionSchema()
        }

        static let decision = OutputConfig(format: Format())
    }

    /// Hand-written rather than generated: the schema is fixed, and structured
    /// outputs reject anything but `additionalProperties: false` plus `required`.
    public struct DecisionSchema: Encodable, Sendable {
        public let type = "object"
        public let properties = Properties()
        public let required = ["action", "text"]
        public let additionalProperties = false

        public struct Properties: Encodable, Sendable {
            public let action = ActionProperty()
            public let text = TextProperty()
        }
        public struct ActionProperty: Encodable, Sendable {
            public let type = "string"
            public let `enum` = InsertionAction.modelChoosable.map(\.rawValue)
        }
        public struct TextProperty: Encodable, Sendable {
            public let type = "string"
        }
    }

    // MARK: - Response

    struct Response: Decodable {
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
            /// Present only when the endpoint returns reasoning. This app never asks
            /// for it, but a gateway in front of the API may add it, and History is
            /// more useful with it than without.
            let thinking: String?
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

    /// What came back: the text to use, plus any reasoning the endpoint volunteered.
    public struct Completion: Equatable, Sendable {
        public let text: String
        public let thinking: String?
    }

    /// Turns an HTTP status plus body into either the rewritten text or a typed
    /// error. Pure, so it can be tested without a network.
    public static func text(fromStatus status: Int, body: Data) throws -> String {
        try completion(fromStatus: status, body: body).text
    }

    public static func completion(fromStatus status: Int, body: Data) throws -> Completion {
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

        let blocks = response.content ?? []
        let text = blocks
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { throw AnthropicError.emptyResponse }

        let thinking = blocks
            .filter { $0.type == "thinking" }
            .compactMap(\.thinking)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Completion(text: text, thinking: thinking.isEmpty ? nil : thinking)
    }

    /// The `.revise` counterpart: an action plus the text to apply it with.
    public static func decision(fromStatus status: Int, body: Data) throws -> EditDecision {
        parse(decision: try text(fromStatus: status, body: body))
    }

    /// Anything we cannot read as a decision degrades to inserting the response
    /// verbatim. A malformed reply must never be able to mean "replace the draft".
    /// The shared parser lives in `EditDecisionJSON` so every provider ends up with
    /// the same behaviour; this is a thin convenience for the Anthropic path.
    public static func parse(decision text: String) -> EditDecision {
        EditDecisionJSON.parse(decision: text)
    }
}
