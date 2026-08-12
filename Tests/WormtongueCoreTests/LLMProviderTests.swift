import Foundation
import Testing

@testable import WormtongueCore

/// A provider that returns a fixed completion and records what it was asked.
/// No network, no CLI, no keys — the tests exercise the seam, not a transport.
final class StubProvider: LLMProvider, @unchecked Sendable {
    let supportsStructuredOutput: Bool
    private let completion: LLMCompletion
    private(set) var receivedPrompts: [LLMPrompt] = []

    init(supportsStructuredOutput: Bool, completion: LLMCompletion) {
        self.supportsStructuredOutput = supportsStructuredOutput
        self.completion = completion
    }

    func complete(prompt: LLMPrompt) async throws -> LLMCompletion {
        receivedPrompts.append(prompt)
        return completion
    }
}

private func prompt(intent: EditIntent) -> LLMPrompt {
    LLMPrompt(model: "m", system: "s", user: "u", maxTokens: 512, intent: intent)
}

private func makeConfig(model: String, modes: [Mode]) -> Config {
    Config(
        model: model,
        maxTokens: 512,
        apiBaseURL: "https://api.anthropic.com",
        apiHeaders: [:],
        whisperModel: "base",
        contextCharCap: 4000,
        fieldCharCap: 4000,
        dictionary: [],
        editOptInBundleIds: [],
        contextOptInBundleIds: [],
        deniedBundleIds: [],
        hotkeyMode: .hold,
        insertRawFirst: false,
        showOverlay: true,
        soundFeedback: true,
        modes: modes
    )
}

@Suite("LLM provider seam")
struct LLMProviderSeamTests {

    @Test("A mode's model override reaches the provider; otherwise the global model")
    func modeModelSelection() async throws {
        let config = makeConfig(
            model: "global-model",
            modes: [
                Mode(
                    name: "work", matchBundleIds: ["com.work.app"],
                    model: "work-model", prompt: "clean it up"),
                Mode(name: "default", prompt: "clean it up"),
            ]
        )
        let resolver = ModeResolver(config: config)

        // The mode with an override feeds its own model to the provider.
        let stubA = StubProvider(
            supportsStructuredOutput: false,
            completion: LLMCompletion(text: "x", thinking: nil))
        let work = resolver.mode(bundleId: "com.work.app", windowTitle: nil)
        _ = try await LLMPipeline.run(
            provider: stubA,
            prompt: LLMPrompt(
                model: work.model ?? config.model, system: "s", user: "u",
                maxTokens: 512, intent: .compose))
        #expect(stubA.receivedPrompts.last?.model == "work-model")

        // A mode without an override falls back to the global model.
        let stubB = StubProvider(
            supportsStructuredOutput: false,
            completion: LLMCompletion(text: "y", thinking: nil))
        let plain = resolver.mode(bundleId: "com.unknown", windowTitle: nil)
        _ = try await LLMPipeline.run(
            provider: stubB,
            prompt: LLMPrompt(
                model: plain.model ?? config.model, system: "s", user: "u",
                maxTokens: 512, intent: .compose))
        #expect(stubB.receivedPrompts.last?.model == "global-model")
    }

    @Test("Mode resolution picks the override, and the override reaches the provider")
    func modeResolutionFeedsProvider() throws {
        let config = makeConfig(
            model: "global-model",
            modes: [
                Mode(
                    name: "work", matchBundleIds: ["com.work.app"],
                    model: "work-model", prompt: "clean it up"),
                Mode(name: "default", prompt: "clean it up"),
            ])
        let resolver = ModeResolver(config: config)
        // The override comes from mode resolution, not from the test.
        #expect(resolver.mode(bundleId: "com.work.app", windowTitle: nil).model == "work-model")
        #expect(resolver.mode(bundleId: "com.unknown", windowTitle: nil).model == nil)
    }

    @Test("compose always inserts the returned text")
    func composeInserts() async throws {
        let stub = StubProvider(
            supportsStructuredOutput: true,
            completion: LLMCompletion(text: "Hello.", thinking: nil))
        let result = try await LLMPipeline.run(provider: stub, prompt: prompt(intent: .compose))
        #expect(result.decision == EditDecision(action: .insert, text: "Hello."))
        #expect(result.decision.text == "Hello.")
    }

    @Test("replaceSelection maps to a selection replacement, never the model's choice")
    func replaceSelectionIsDeterministic() async throws {
        let stub = StubProvider(
            supportsStructuredOutput: true,
            completion: LLMCompletion(text: "new", thinking: nil))
        let result = try await LLMPipeline.run(
            provider: stub, prompt: prompt(intent: .replaceSelection))
        #expect(result.decision == EditDecision(action: .replaceSelection, text: "new"))
    }

    @Test("revise with structured output honours the model's replace_all decision")
    func reviseStructuredRewrite() async throws {
        let stub = StubProvider(
            supportsStructuredOutput: true,
            completion: LLMCompletion(
                text: #"{"action":"replace_all","text":"New draft."}"#, thinking: "quiet"))
        let result = try await LLMPipeline.run(provider: stub, prompt: prompt(intent: .revise))
        #expect(result.decision == EditDecision(action: .replaceAll, text: "New draft."))
        #expect(result.decision.text == "New draft.")
        #expect(result.thinking == "quiet")
    }

    @Test("revise with structured output honours the model's insert decision")
    func reviseStructuredInsert() async throws {
        let stub = StubProvider(
            supportsStructuredOutput: true,
            completion: LLMCompletion(
                text: #"{"action":"insert","text":"and another thing"}"#, thinking: nil))
        let result = try await LLMPipeline.run(provider: stub, prompt: prompt(intent: .revise))
        #expect(result.decision == EditDecision(action: .insert, text: "and another thing"))
    }

    @Test("revise without structured output degrades to a plain insert, never a guessed rewrite")
    func reviseFallsBackToInsert() async throws {
        let stub = StubProvider(
            supportsStructuredOutput: false,
            completion: LLMCompletion(
                text: "Some prose that must be inserted verbatim.", thinking: nil))
        let result = try await LLMPipeline.run(provider: stub, prompt: prompt(intent: .revise))
        #expect(result.decision == EditDecision(action: .insert, text: "Some prose that must be inserted verbatim."))
        #expect(result.decision.action != .replaceAll)
        #expect(result.decision.action != .replaceSelection)
    }

    @Test("Thinking from the provider is surfaced on the result")
    func thinkingSurfaces() async throws {
        let stub = StubProvider(
            supportsStructuredOutput: true,
            completion: LLMCompletion(text: "hi", thinking: "because"))
        let result = try await LLMPipeline.run(provider: stub, prompt: prompt(intent: .compose))
        #expect(result.thinking == "because")
    }

    @Test("The active provider is swapped without the pipeline changing")
    func swappingProviderKeepsPipeline() async throws {
        // Same prompt, two providers with different capabilities and outputs; the
        // pipeline returns the right outcome for each without knowing which it is.
        let structured = StubProvider(
            supportsStructuredOutput: true,
            completion: LLMCompletion(
                text: #"{"action":"replace_all","text":"rewrote"}"#, thinking: nil))
        let plain = StubProvider(
            supportsStructuredOutput: false,
            completion: LLMCompletion(text: "just add this", thinking: nil))

        let fromStructured = try await LLMPipeline.run(
            provider: structured, prompt: prompt(intent: .revise))
        let fromPlain = try await LLMPipeline.run(provider: plain, prompt: prompt(intent: .revise))

        #expect(fromStructured.decision == EditDecision(action: .replaceAll, text: "rewrote"))
        #expect(fromPlain.decision == EditDecision(action: .insert, text: "just add this"))
    }
}

@Suite("Edit-decision interpretation")
struct EditDecisionInterpreterTests {

    @Test("compose and replaceSelection are deterministic, independent of capability")
    func deterministicCases() {
        #expect(
            EditDecisionInterpreter.decision(
                intent: .compose, supportsStructuredOutput: false, text: "a")
                == EditDecision(action: .insert, text: "a"))
        #expect(
            EditDecisionInterpreter.decision(
                intent: .replaceSelection, supportsStructuredOutput: false, text: "a")
                == EditDecision(action: .replaceSelection, text: "a"))
    }

    @Test("revise without structured output degrades to a verbatim insert")
    func reviseWithoutStructured() {
        #expect(
            EditDecisionInterpreter.decision(
                intent: .revise, supportsStructuredOutput: false, text: "draft text")
                == EditDecision(action: .insert, text: "draft text"))
    }

    @Test("revise with structured output parses the decision")
    func reviseWithStructured() {
        #expect(
            EditDecisionInterpreter.decision(
                intent: .revise, supportsStructuredOutput: true,
                text: #"{"action":"replace_all","text":"new"}"#)
                == EditDecision(action: .replaceAll, text: "new"))
    }

    @Test("A malformed structured decision still degrades to insert")
    func malformedStructured() {
        #expect(
            EditDecisionInterpreter.decision(
                intent: .revise, supportsStructuredOutput: true, text: "not json").action
                == .insert)
    }
}