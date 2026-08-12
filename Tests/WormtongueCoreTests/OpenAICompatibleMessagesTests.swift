import Foundation
import Testing

@testable import WormtongueCore

@Suite("OpenAI-compatible request encoding")
struct OpenAICompatibleRequestTests {

    @Test("The body has the chat/completions shape with a system+user message pair")
    func requestShape() throws {
        let request = OpenAICompatibleMessages.Request(
            model: "anthropic/claude-sonnet-4-5",
            system: "you rewrite speech",
            user: "<transcript>hello</transcript>",
            maxTokens: 1024,
            structured: .none
        )
        let json =
            try JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any] ?? [:]

        #expect(json["model"] as? String == "anthropic/claude-sonnet-4-5")
        #expect(json["max_tokens"] as? Int == 1024)  // snake_case on the wire

        let messages = json["messages"] as? [[String: Any]]
        #expect(messages?.count == 2)
        #expect(messages?[0]["role"] as? String == "system")
        #expect(messages?[0]["content"] as? String == "you rewrite speech")
        #expect(messages?[1]["role"] as? String == "user")
        #expect(messages?[1]["content"] as? String == "<transcript>hello</transcript>")
    }

    @Test("Plain text requests carry no response_format")
    func noStructuredWhenNone() throws {
        let request = OpenAICompatibleMessages.Request(
            model: "grok-x", system: "s", user: "u", maxTokens: 10, structured: .none)
        let json =
            try JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any] ?? [:]
        #expect(json["response_format"] == nil)
    }

    @Test("A structured request asks for a JSON object response")
    func structuredAsksForJSONObject() throws {
        let request = OpenAICompatibleMessages.Request(
            model: "deepseek-chat", system: "s", user: "u", maxTokens: 10,
            structured: .jsonObject)
        let json =
            try JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any] ?? [:]
        #expect(json["response_format"] as? [String: String] == ["type": "json_object"])
    }

    @Test("The model string passes through verbatim — vendor/model is untouched")
    func modelStringPassesThrough() throws {
        let request = OpenAICompatibleMessages.Request(
            model: "vendor/model@latest", system: "s", user: "u", maxTokens: 5,
            structured: .none)
        let json =
            try JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any] ?? [:]
        #expect(json["model"] as? String == "vendor/model@latest")
    }

    @Test("Unicode in the transcript survives encoding")
    func unicodeBody() throws {
        let request = OpenAICompatibleMessages.Request(
            model: "m", system: "s", user: "meeting mit Heiko wegen EN‑66 — morgen früh",
            maxTokens: 10, structured: .none)
        let json =
            try JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any] ?? [:]
        let messages = json["messages"] as? [[String: Any]]
        #expect(messages?[1]["content"] as? String == "meeting mit Heiko wegen EN‑66 — morgen früh")
    }
}

@Suite("OpenAI-compatible response parsing")
struct OpenAICompatibleResponseTests {

    private func body(_ json: String) -> Data { Data(json.utf8) }

    @Test("Text is pulled from the first choice's message content")
    func happyPath() throws {
        let json = """
            { "choices": [
                { "message": { "role": "assistant", "content": "Meeting with @heiko re EN-66." },
                  "finish_reason": "stop" } ] }
            """
        let text = try OpenAICompatibleMessages.text(fromStatus: 200, body: body(json))
        #expect(text == "Meeting with @heiko re EN-66.")
    }

    @Test("A structured decision comes back as JSON text inside content")
    func structuredContent() throws {
        let json = """
            { "choices": [
                { "message": { "role": "assistant",
                               "content": "{\\"action\\":\\"replace_all\\",\\"text\\":\\"New draft.\\"}" } } ] }
            """
        let text = try OpenAICompatibleMessages.text(fromStatus: 200, body: body(json))
        #expect(text == #"{"action":"replace_all","text":"New draft."}"#)
    }

    @Test("DeepSeek's reasoning_content is surfaced as thinking, not mixed into text")
    func thinkingIsSeparate() throws {
        let json = """
            { "choices": [
                { "message": { "role": "assistant",
                               "reasoning_content": "the draft is already polite",
                               "content": "Thursday works." } } ] }
            """
        let completion = try OpenAICompatibleMessages.completion(
            fromStatus: 200, body: body(json))
        #expect(completion.text == "Thursday works.")
        #expect(completion.thinking == "the draft is already polite")
    }

    @Test("No reasoning leaves the trace nil rather than empty")
    func thinkingAbsent() throws {
        let json = #"{ "choices": [{ "message": { "content": "ok" } }] }"#
        #expect(
            try OpenAICompatibleMessages.completion(fromStatus: 200, body: body(json)).thinking
                == nil)
    }

    @Test("Surrounding whitespace is trimmed — it would land in the user's field")
    func trimsWhitespace() throws {
        let json = #"{ "choices": [{ "message": { "content": "\n  hello  \n" } }] }"#
        #expect(try OpenAICompatibleMessages.text(fromStatus: 200, body: body(json)) == "hello")
    }

    @Test("An empty or content-free response is an error, not an empty insert")
    func emptyResponse() {
        #expect(throws: OpenAICompatibleError.emptyResponse) {
            try OpenAICompatibleMessages.text(fromStatus: 200, body: body(#"{ "choices": [] }"#))
        }
        #expect(throws: OpenAICompatibleError.emptyResponse) {
            try OpenAICompatibleMessages.text(
                fromStatus: 200,
                body: body(#"{ "choices": [{ "message": { "content": "   " } }] }"#))
        }
        #expect(throws: OpenAICompatibleError.emptyResponse) {
            try OpenAICompatibleMessages.text(
                fromStatus: 200, body: body(#"{ "choices": [{ "message": { "content": null } }] }"#)
            )
        }
        #expect(throws: OpenAICompatibleError.emptyResponse) {
            try OpenAICompatibleMessages.text(fromStatus: 200, body: body("{}"))
        }
    }

    @Test("The OpenAI-style error envelope surfaces its type, code and message")
    func errorEnvelope() {
        let json = """
            { "error": { "message": "Rate limit reached", "type": "rate_limit_error",
                         "code": 429 } }
            """
        #expect(
            throws: OpenAICompatibleError.http(
                status: 429, type: "rate_limit_error", code: "429", message: "Rate limit reached")
        ) {
            try OpenAICompatibleMessages.text(fromStatus: 429, body: body(json))
        }
    }

    @Test("A non-JSON error body still produces a usable message")
    func nonJSONErrorBody() throws {
        let error = #expect(throws: OpenAICompatibleError.self) {
            try OpenAICompatibleMessages.text(fromStatus: 502, body: Data("<html>bad gateway".utf8))
        }
        guard case let .http(status, _, _, message) = try #require(error) else {
            Issue.record("expected an http error")
            return
        }
        #expect(status == 502)
        #expect(message.contains("bad gateway"))
    }

    @Test("An empty error body does not produce an empty message")
    func emptyErrorBody() throws {
        let error = #expect(throws: OpenAICompatibleError.self) {
            try OpenAICompatibleMessages.text(fromStatus: 500, body: Data())
        }
        guard case let .http(_, _, _, message) = try #require(error) else {
            Issue.record("expected an http error")
            return
        }
        #expect(message == "no body")
    }

    @Test("A 200 with an unparseable body is an error, not a crash")
    func unparseableSuccessBody() {
        #expect(throws: OpenAICompatibleError.self) {
            try OpenAICompatibleMessages.text(fromStatus: 200, body: Data("not json".utf8))
        }
    }

    @Test("Only 429 and 5xx are worth retrying")
    func retryClassification() {
        #expect(
            OpenAICompatibleError.http(status: 429, type: nil, code: nil, message: "").isRetryable)
        #expect(
            OpenAICompatibleError.http(status: 500, type: nil, code: nil, message: "").isRetryable)
        #expect(
            OpenAICompatibleError.http(status: 529, type: nil, code: nil, message: "").isRetryable)
        #expect(
            !OpenAICompatibleError.http(status: 400, type: nil, code: nil, message: "").isRetryable)
        #expect(
            !OpenAICompatibleError.http(status: 401, type: nil, code: nil, message: "").isRetryable)
        #expect(!OpenAICompatibleError.missingAPIKey.isRetryable)
    }

    @Test("Errors carry a message the menu can actually show")
    func errorDescriptions() {
        #expect(
            OpenAICompatibleError.missingAPIKey.errorDescription?.contains("API key") == true)
        #expect(
            OpenAICompatibleError.missingBaseURL.errorDescription?.contains("base URL") == true)
        #expect(
            OpenAICompatibleError.http(status: 429, type: nil, code: "rate_limit", message: "slow")
                .errorDescription?.contains("429") == true)
    }
}

@Suite("OpenAI-compatible structured capability")
struct OpenAICompatStructuredCapabilityTests {

    @Test("The real presets can express the JSON-object decision; custom cannot")
    func presetCapability() {
        for preset in [OpenAICompatPreset.openRouter, .deepSeek, .groq, .xAI] {
            #expect(preset.structuredMode == .jsonObject, "\(preset) should use JSON mode")
            #expect(preset.supportsStructuredOutput)
        }
        #expect(OpenAICompatPreset.custom.structuredMode == .none)
        #expect(!OpenAICompatPreset.custom.supportsStructuredOutput)
    }

    @Test("A custom host (no structured output) degrades a revise to a plain insert")
    func customHostReviseInserts() async throws {
        // The adapter declares `.custom` as not supporting structured output; the
        // seam then must never guess a rewrite, only insert verbatim.
        let stub = StubProvider(
            supportsStructured: OpenAICompatPreset.custom.supportsStructuredOutput,
            completion: LLMCompletion(text: "Some prose the draft must keep.", thinking: nil))
        let result = try await LLMPipeline.run(
            provider: stub,
            prompt: LLMPrompt(
                model: "m", system: "s", user: "u", maxTokens: 512, intent: .revise))
        #expect(
            result.decision
                == EditDecision(action: .insert, text: "Some prose the draft must keep."))
    }

    @Test("A structured preset honours the model's rewrite decision through the same parsing path")
    func openRouterReviseWorks() async throws {
        let stub = StubProvider(
            supportsStructured: OpenAICompatPreset.openRouter.supportsStructuredOutput,
            completion: LLMCompletion(
                text: #"{"action":"replace_all","text":"New draft."}"#, thinking: nil))
        let result = try await LLMPipeline.run(
            provider: stub,
            prompt: LLMPrompt(
                model: "vendor/model", system: "s", user: "u", maxTokens: 512, intent: .revise))
        #expect(result.decision == EditDecision(action: .replaceAll, text: "New draft."))
    }
}

@Suite("Shared edit-decision JSON")
struct EditDecisionJSONTests {

    @Test("The shared parser reads a replace_all decision")
    func parsesReplaceAll() {
        #expect(
            EditDecisionJSON.parse(decision: #"{"action":"replace_all","text":"New draft."}"#)
                == EditDecision(action: .replaceAll, text: "New draft."))
    }

    @Test("The shared parser reads an insert decision")
    func parsesInsert() {
        #expect(
            EditDecisionJSON.parse(decision: #"{"action":"insert","text":"and another thing"}"#)
                == EditDecision(action: .insert, text: "and another thing"))
    }

    @Test("A fenced decision (models sometimes fence JSON) still parses")
    func parsesFenced() {
        #expect(
            EditDecisionJSON.parse(
                decision: "```json\n{\"action\":\"insert\",\"text\":\"hi\"}\n```")
                == EditDecision(action: .insert, text: "hi"))
    }

    @Test("Prose and malformed JSON degrade to a verbatim insert")
    func degradesToInsert() {
        #expect(
            EditDecisionJSON.parse(decision: "Sure, here is the text.")
                == EditDecision(action: .insert, text: "Sure, here is the text."))
        #expect(EditDecisionJSON.parse(decision: "not json").action == .insert)
    }

    @Test("A non-choosable action (e.g. replace_selection) degrades to insert")
    func rejectsNonChoosableAction() {
        #expect(
            EditDecisionJSON.parse(decision: #"{"action":"replace_selection","text":"x"}"#)
                == EditDecision(action: .insert, text: "x"))
    }
}
