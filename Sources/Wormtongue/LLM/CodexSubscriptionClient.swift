import Foundation
import WormtongueCore

/// The Codex subscription adapter behind the `LLMProvider` seam.
///
/// Drives the installed `codex` CLI in a headless one-shot (`codex exec …`),
/// reusing the user's own subscription login — Wormtongue never stores a codex
/// token. Startup is primed on key-down via `codex login status` so it overlaps
/// dictation. All the spawn/parse/env logic lives in `SubscriptionCLI` (Core);
/// this actor is only the seam conformance.
actor CodexSubscriptionClient: LLMProvider {
    private let variant = CodexSubscriptionCLI.variant

    /// Headless `codex exec` emits freeform text events, not a structured decision
    /// we can trust, so `.revise` degrades to a plain insert via the interpreter —
    /// never a guessed rewrite.
    func supportsStructuredOutput() async -> Bool { false }

    func complete(prompt: LLMPrompt) async throws -> LLMCompletion {
        try await SubscriptionCLI.complete(variant: variant, prompt: prompt)
    }

    /// Primes the CLI on key-down (boots its runtime and refreshes auth) so the
    /// real one-shot pays a warm start.
    func warm() async {
        await SubscriptionCLI.prime(variant: variant)
    }
}
