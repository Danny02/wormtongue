import Foundation

/// One stateless completion per utterance, exactly as the rewrite pass needs it.
///
/// The pipeline builds this from the resolved mode, the privacy policy, and the
/// transcript; a provider consumes it and returns text plus any reasoning.
public struct LLMPrompt: Sendable, Equatable {
    public let model: String
    public let system: String
    public let user: String
    public let maxTokens: Int
    /// Why the dictation happened. The transport uses it to decide whether to ask
    /// for structured output (only `.revise` needs a decision, not plain text).
    public let intent: EditIntent

    public init(
        model: String, system: String, user: String, maxTokens: Int, intent: EditIntent
    ) {
        self.model = model
        self.system = system
        self.user = user
        self.maxTokens = maxTokens
        self.intent = intent
    }
}

/// The raw outcome of one completion: the text to use, plus any reasoning the
/// endpoint volunteered. What the app shows in History as thinking.
public struct LLMCompletion: Sendable, Equatable {
    public let text: String
    public let thinking: String?

    public init(text: String, thinking: String?) {
        self.text = text
        self.thinking = thinking
    }
}

/// What the pipeline turns a completion into: the edit decision, plus any
/// reasoning the endpoint volunteered. The text to use is `decision.text`.
public struct LLMResult: Sendable, Equatable {
    public let thinking: String?
    public let decision: EditDecision

    public init(thinking: String?, decision: EditDecision) {
        self.thinking = thinking
        self.decision = decision
    }
}

/// The single seam between the app's rewrite pipeline and a provider.
///
/// The pipeline depends on this interface and never on a concrete adapter;
/// adding a provider means adding one conforming type. A provider is stateless:
/// each utterance is one `complete`, and everything it needs is in the prompt.
public protocol LLMProvider: Sendable {
    /// Declared statically by each adapter; never feature-detected at runtime.
    ///
    /// When false, a `.revise` intent cannot produce a structured decision and
    /// degrades to a plain insert — never a guessed rewrite.
    var supportsStructuredOutput: Bool { get }

    /// One stateless completion per utterance → the raw text, plus any reasoning.
    func complete(prompt: LLMPrompt) async throws -> LLMCompletion
}

/// Maps a provider's raw completion to the edit decision an intent calls for.
///
/// Public so the seam's behavior — including the structured-output fallback — is
/// testable without a transport.
public enum EditDecisionInterpreter {
    public static func decision(
        intent: EditIntent,
        supportsStructuredOutput: Bool,
        text: String
    ) -> EditDecision {
        switch intent {
        case .compose, .replaceSelection:
            // Deterministic: the field state already named the action.
            return EditDecision(
                action: intent == .replaceSelection ? .replaceSelection : .insert,
                text: text)
        case .revise:
            // Ambiguous: the model must choose between adding to the draft and
            // rewriting it. That choice only arrives as a structured decision, so
            // without structured output we cannot trust one — degrade to a plain
            // insert rather than guessing at a rewrite.
            guard supportsStructuredOutput else {
                return EditDecision(action: .insert, text: text)
            }
            return AnthropicMessages.parse(decision: text)
        }
    }
}

/// Runs one completion through the seam and produces the pipeline's result.
public enum LLMPipeline {
    public static func run(
        provider: any LLMProvider,
        prompt: LLMPrompt
    ) async throws -> LLMResult {
        let completion = try await provider.complete(prompt: prompt)
        let decision = EditDecisionInterpreter.decision(
            intent: prompt.intent,
            supportsStructuredOutput: provider.supportsStructuredOutput,
            text: completion.text)
        return LLMResult(thinking: completion.thinking, decision: decision)
    }
}