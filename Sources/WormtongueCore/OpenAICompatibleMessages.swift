import Foundation

/// Errors from the OpenAI-compatible `chat/completions` transport.
///
/// Distinct from `AnthropicError` so the menu can say which provider failed; the
/// keyed setup is different (an `.openAICompatible` key vs an `ANTHROPIC_API_KEY`).
public enum OpenAICompatibleError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case missingBaseURL
    case http(status: Int, type: String?, code: String?, message: String)
    case emptyResponse
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key for the OpenAI-compatible provider. Add one in Setup."
        case .missingBaseURL:
            return
                "No base URL set for the OpenAI-compatible provider. Choose a preset or enter a custom URL in Setup."
        case let .http(status, type, code, message):
            return
                "OpenAI-compatible API \(status)\(code.map { " (\($0))" } ?? "")\(type.map { " (\($0))" } ?? ""): \(message)"
        case .emptyResponse:
            return "The OpenAI-compatible API returned no text."
        case .cancelled:
            return "Cancelled."
        }
    }

    /// 429 and 5xx are worth one retry; everything else is a bug in our request.
    public var isRetryable: Bool {
        if case let .http(status, _, _, _) = self { return status == 429 || status >= 500 }
        return false
    }
}

/// How an OpenAI-compatible host can express the structured revise decision.
///
/// The `chat/completions` transport asks for structured output via
/// `response_format`. The forms are not portable across hosts (see
/// `OpenAICompatPreset.structuredMode`), so each preset declares the one it can
/// honestly express. `.none` means no structured output: the adapter returns
/// plain text and the seam degrades a `.revise` to a plain insert.
public enum OpenAICompatStructured: Sendable, Equatable {
    /// No `response_format`; plain text out.
    case none
    /// `response_format: { "type": "json_object" }` — valid JSON, schema unconstrained.
    case jsonObject
}

/// Wire types for `POST /chat/completions`.
///
/// A single stateless completion per utterance, exactly like `AnthropicMessages`
/// but over the OpenAI-compatible shape. No SDK — the raw HTTP body is hand-coded
/// so it can be unit-tested without any network.
public enum OpenAICompatibleMessages {
    // MARK: - Request

    public struct Request: Encodable, Sendable {
        public struct Message: Encodable, Sendable {
            public let role: String
            public let content: String

            public init(role: String, content: String) {
                self.role = role
                self.content = content
            }
        }

        public let model: String
        public let messages: [Message]
        public let maxTokens: Int
        /// `response_format`, present only when structured output is requested.
        public let responseFormat: ResponseFormat?

        enum CodingKeys: String, CodingKey {
            case model, messages
            case maxTokens = "max_tokens"
            case responseFormat = "response_format"
        }

        public init(
            model: String, system: String, user: String, maxTokens: Int,
            structured: OpenAICompatStructured
        ) {
            self.model = model
            self.maxTokens = maxTokens
            var messages = [Message(role: "system", content: system)]
            if !user.isEmpty { messages.append(Message(role: "user", content: user)) }
            self.messages = messages
            self.responseFormat = structured == .none ? nil : ResponseFormat(structured: structured)
        }

        public func encoded() throws -> Data {
            try JSONEncoder().encode(self)
        }
    }

    public struct ResponseFormat: Encodable, Sendable {
        public let type: String

        public init(structured: OpenAICompatStructured) {
            switch structured {
            case .none: self.type = ""
            case .jsonObject: self.type = "json_object"
            }
        }
    }

    // MARK: - Response

    /// What came back: the text to use, plus any reasoning the endpoint
    /// volunteered (DeepSeek's reasoner models return `reasoning_content`).
    public struct Completion: Equatable, Sendable {
        public let text: String
        public let thinking: String?

        public init(text: String, thinking: String?) {
            self.text = text
            self.thinking = thinking
        }
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
                let reasoningContent: String?
            }
            let message: Message?
            let finishReason: String?
        }
        struct ErrorPayload: Decodable {
            let message: String?
            let type: String?
            let code: FlexibleString?
        }
        let choices: [Choice]?
        let error: ErrorPayload?
    }

    /// Turns an HTTP status plus body into the text to use. Pure, so it can be
    /// tested without a network.
    public static func text(fromStatus status: Int, body: Data) throws -> String {
        try completion(fromStatus: status, body: body).text
    }

    public static func completion(fromStatus status: Int, body: Data) throws -> Completion {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        guard (200..<300).contains(status) else {
            throw httpError(status: status, body: body, decoder: decoder)
        }

        guard let response = try? decoder.decode(Response.self, from: body) else {
            throw OpenAICompatibleError.http(
                status: status, type: nil, code: nil, message: "unparseable response body")
        }
        guard let message = response.choices?.first?.message, let content = message.content
        else { throw OpenAICompatibleError.emptyResponse }

        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OpenAICompatibleError.emptyResponse }

        let rawThinking =
            message.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines)
        let thinking = (rawThinking?.isEmpty ?? true) ? nil : rawThinking
        return Completion(text: text, thinking: thinking)
    }

    /// Hosts disagree on the error shape, so read it tolerantly: the OpenAI-style
    /// `{ "error": { "message", "type", "code" } }` envelope, else the raw body.
    private static func httpError(
        status: Int, body: Data, decoder: JSONDecoder
    ) -> OpenAICompatibleError {
        if let envelope = try? decoder.decode(Response.self, from: body),
            let e = envelope.error
        {
            return OpenAICompatibleError.http(
                status: status, type: e.type, code: e.code?.value,
                message: e.message ?? "no message")
        }
        let raw =
            String(data: body, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 } ?? "no body"
        return OpenAICompatibleError.http(status: status, type: nil, code: nil, message: raw)
    }

    /// A `String` that also decodes from a number, because hosts disagree on the
    /// type of `error.code` (OpenRouter sends an HTTP status as a number, Groq a
    /// string) and a decode failure there must not hide the whole error message.
    struct FlexibleString: Decodable, Sendable {
        let value: String

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                value = s
            } else if let n = try? c.decode(Int.self) {
                value = String(n)
            } else if let d = try? c.decode(Double.self) {
                value = String(d)
            } else {
                throw DecodingError.typeMismatch(
                    String.self,
                    DecodingError.Context(
                        codingPath: decoder.codingPath, debugDescription: "not a string or number"))
            }
        }
    }
}
