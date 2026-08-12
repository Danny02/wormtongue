import Foundation
import Testing

@testable import WormtongueCore

@Suite("Anthropic request encoding")
struct AnthropicRequestTests {

    @Test("The body has the shape the Messages API expects")
    func requestShape() throws {
        let request = AnthropicMessages.Request(
            model: "claude-haiku-4-5-20251001",
            system: "you rewrite speech",
            user: "<transcript>hello</transcript>",
            maxTokens: 1024
        )
        let json =
            try JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any] ?? [:]

        #expect(json["model"] as? String == "claude-haiku-4-5-20251001")
        #expect(json["max_tokens"] as? Int == 1024)  // snake_case on the wire
        #expect(json["system"] as? String == "you rewrite speech")
        // Latency: the rewrite pass always opts out of the model's thinking block.
        #expect(json["thinking"] as? [String: String] == ["type": "disabled"])

        let messages = json["messages"] as? [[String: Any]]
        #expect(messages?.count == 1)
        #expect(messages?[0]["role"] as? String == "user")
        #expect(messages?[0]["content"] as? String == "<transcript>hello</transcript>")
    }

    @Test("Unicode in the transcript survives encoding")
    func unicodeBody() throws {
        let request = AnthropicMessages.Request(
            model: "m", system: "s", user: "meeting mit Heiko wegen EN‑66 — morgen früh",
            maxTokens: 10)
        let decoded =
            try JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any] ?? [:]
        let messages = decoded["messages"] as? [[String: Any]]
        #expect(messages?[0]["content"] as? String == "meeting mit Heiko wegen EN‑66 — morgen früh")
    }
}

@Suite("Anthropic response parsing")
struct AnthropicResponseTests {

    private func body(_ json: String) -> Data { Data(json.utf8) }

    @Test("Text is pulled out of the content block array")
    func happyPath() throws {
        let json = """
            { "content": [{ "type": "text", "text": "Meeting with @heiko re EN-66 tomorrow." }],
              "stop_reason": "end_turn" }
            """
        let text = try AnthropicMessages.text(fromStatus: 200, body: body(json))
        #expect(text == "Meeting with @heiko re EN-66 tomorrow.")
    }

    @Test("A thinking block is captured for History, never mixed into the output")
    func thinkingIsSeparate() throws {
        let json = """
            { "content": [
                { "type": "thinking", "thinking": "the draft is already polite" },
                { "type": "text", "text": "Thursday works." }],
              "stop_reason": "end_turn" }
            """
        let completion = try AnthropicMessages.completion(fromStatus: 200, body: body(json))
        #expect(completion.text == "Thursday works.")
        #expect(completion.thinking == "the draft is already polite")
    }

    @Test("No thinking block leaves the trace nil rather than empty")
    func thinkingAbsent() throws {
        let json = #"{ "content": [{ "type": "text", "text": "ok" }] }"#
        #expect(try AnthropicMessages.completion(fromStatus: 200, body: body(json)).thinking == nil)
    }

    @Test("Multiple text blocks are concatenated, non-text blocks skipped")
    func multipleBlocks() throws {
        let json = """
            { "content": [
                { "type": "thinking", "thinking": "hmm" },
                { "type": "text", "text": "part one " },
                { "type": "text", "text": "part two" }
              ], "stop_reason": "end_turn" }
            """
        #expect(
            try AnthropicMessages.text(fromStatus: 200, body: body(json)) == "part one part two")
    }

    @Test("Surrounding whitespace is trimmed — it would land in the user's field")
    func trimsWhitespace() throws {
        let json = #"{ "content": [{ "type": "text", "text": "\n  hello  \n" }] }"#
        #expect(try AnthropicMessages.text(fromStatus: 200, body: body(json)) == "hello")
    }

    @Test("A refusal is a 200 with empty content — it must not be read as text")
    func refusal() {
        let json = """
            { "content": [], "stop_reason": "refusal",
              "stop_details": { "type": "refusal", "category": "cyber" } }
            """
        #expect(throws: AnthropicError.refused(category: "cyber")) {
            try AnthropicMessages.text(fromStatus: 200, body: body(json))
        }
    }

    @Test("A refusal without a category still throws a refusal")
    func refusalWithoutCategory() {
        let json = #"{ "content": [], "stop_reason": "refusal" }"#
        #expect(throws: AnthropicError.refused(category: nil)) {
            try AnthropicMessages.text(fromStatus: 200, body: body(json))
        }
    }

    @Test("An empty or text-free response is an error, not an empty insert")
    func emptyResponse() {
        #expect(throws: AnthropicError.emptyResponse) {
            try AnthropicMessages.text(fromStatus: 200, body: body(#"{ "content": [] }"#))
        }
        #expect(throws: AnthropicError.emptyResponse) {
            try AnthropicMessages.text(
                fromStatus: 200, body: body(#"{ "content": [{"type":"text","text":"   "}] }"#))
        }
        #expect(throws: AnthropicError.emptyResponse) {
            try AnthropicMessages.text(fromStatus: 200, body: body("{}"))
        }
    }

    @Test("The error envelope is surfaced with its type and message")
    func errorEnvelope() {
        let json = """
            { "type": "error",
              "error": { "type": "invalid_request_error", "message": "max_tokens: too large" } }
            """
        #expect(
            throws: AnthropicError.http(
                status: 400, type: "invalid_request_error", message: "max_tokens: too large")
        ) {
            try AnthropicMessages.text(fromStatus: 400, body: body(json))
        }
    }

    @Test("A non-JSON error body still produces a usable message")
    func nonJSONErrorBody() throws {
        let error = #expect(throws: AnthropicError.self) {
            try AnthropicMessages.text(fromStatus: 502, body: Data("<html>bad gateway".utf8))
        }
        guard case let .http(status, type, message) = try #require(error) else {
            Issue.record("expected an http error")
            return
        }
        #expect(status == 502)
        #expect(type == nil)
        #expect(message.contains("bad gateway"))
    }

    @Test("An empty error body does not produce an empty message")
    func emptyErrorBody() throws {
        let error = #expect(throws: AnthropicError.self) {
            try AnthropicMessages.text(fromStatus: 500, body: Data())
        }
        guard case let .http(_, _, message) = try #require(error) else {
            Issue.record("expected an http error")
            return
        }
        #expect(message == "no body")
    }

    @Test("A 200 with an unparseable body is an error, not a crash")
    func unparseableSuccessBody() {
        #expect(throws: AnthropicError.self) {
            try AnthropicMessages.text(fromStatus: 200, body: Data("not json at all".utf8))
        }
    }

    @Test("Only 429 and 5xx are worth retrying")
    func retryClassification() {
        #expect(AnthropicError.http(status: 429, type: nil, message: "").isRetryable)
        #expect(AnthropicError.http(status: 500, type: nil, message: "").isRetryable)
        #expect(AnthropicError.http(status: 529, type: nil, message: "").isRetryable)
        #expect(!AnthropicError.http(status: 400, type: nil, message: "").isRetryable)
        #expect(!AnthropicError.http(status: 401, type: nil, message: "").isRetryable)
        #expect(!AnthropicError.missingAPIKey.isRetryable)
        #expect(!AnthropicError.refused(category: nil).isRetryable)
    }

    @Test("Errors carry a message the menu can actually show")
    func errorDescriptions() {
        #expect(AnthropicError.missingAPIKey.errorDescription?.contains("API key") == true)
        #expect(
            AnthropicError.http(status: 429, type: "rate_limit_error", message: "slow down")
                .errorDescription?.contains("429") == true)
        #expect(
            AnthropicError.refused(category: "cyber").errorDescription?.contains("cyber") == true)
    }
}

@Suite("Stopwatch")
struct StopwatchTests {

    @Test("Stages are recorded in order and the summary names each one")
    func summaryFormat() {
        var watch = Stopwatch()
        watch.lap("transcribe")
        watch.lap("llm")
        watch.note("probe", seconds: 0.25)

        #expect(watch.stages.map(\.name) == ["transcribe", "llm", "probe"])
        let summary = watch.summary
        #expect(summary.contains("transcribe "))
        #expect(summary.contains("probe 250ms"))
        #expect(summary.contains("total "))
        #expect(summary.contains("·"))
    }

    @Test("Durations are non-negative and monotonic")
    func monotonic() {
        var watch = Stopwatch()
        watch.lap("a")
        watch.lap("b")
        #expect(watch.stages.allSatisfy { $0.seconds >= 0 })
        #expect(watch.total >= 0)
    }

    @Test("Duration.seconds converts sub-second values")
    func durationSeconds() {
        #expect(abs(Duration.milliseconds(250).seconds - 0.25) < 0.000_001)
        #expect(abs(Duration.seconds(2).seconds - 2.0) < 0.000_001)
    }
}
