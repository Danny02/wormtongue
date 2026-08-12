import Foundation
import WormtongueCore

/// The Claude subscription adapter behind the `LLMProvider` seam.
///
/// Drives the installed `claude` CLI in a headless one-shot (`claude -p …`),
/// reusing the user's own OAuth login — Wormtongue never stores a subscription
/// token. Startup is primed on key-down via `claude auth status` so it overlaps
/// dictation. All the spawn/parse/env logic lives in `SubscriptionCLI` (Core);
/// this actor is only the seam conformance.
actor ClaudeSubscriptionClient: LLMProvider {
    private let variant = ClaudeSubscriptionCLI.variant

    /// Headless `claude -p` emits freeform text, not a structured decision we can
    /// trust, so `.revise` degrades to a plain insert via the interpreter — never
    /// a guessed rewrite.
    nonisolated var supportsStructuredOutput: Bool { false }

    func complete(prompt: LLMPrompt) async throws -> LLMCompletion {
        try await SubscriptionCLI.complete(variant: variant, prompt: prompt)
    }

    /// Primes the CLI on key-down (boots its runtime and refreshes auth) so the
    /// real one-shot pays a warm start.
    func warm() async {
        await SubscriptionCLI.prime(variant: variant)
    }
}
