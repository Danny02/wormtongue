import Foundation
import VoiceModeCore

/// One rewrite pass. `AnthropicClient` sends it to the Messages API;
/// `LocalRewriter` runs it on this Mac.
///
/// The rest of the pipeline does not care which it got — `Policy.destination`
/// decides, and everything downstream works off the returned `EditDecision`.
protocol Rewriter: Sendable {
    /// Prepares the pass so the first dictation does not pay for setup.
    func prewarm(model: String) async

    func edit(
        model: String, system: String, user: String, maxTokens: Int, intent: EditIntent
    ) async throws -> EditDecision
}

enum RewriterError: LocalizedError {
    case localPassNotBuilt
    case localModelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .localPassNotBuilt:
            return """
                This build has no on-device rewrite pass. Rebuild with \
                ./Scripts/bundle.sh release --local-pass, or remove the app from \
                local_opt_in_bundle_ids.
                """
        case let .localModelUnavailable(detail):
            return "On-device model unavailable: \(detail)"
        }
    }
}
