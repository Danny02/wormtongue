import Foundation

/// Which AI provider drives the rewrite pass. One is active globally; a mode may
/// override only the *model string*, never the provider.
///
/// The four cases are the whole catalogue: the existing keyed Anthropic path, an
/// OpenAI-compatible API (with presets), and the two subscription CLIs whose
/// login the app detects but does not own.
public enum ProviderKind: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case anthropicKeyed = "anthropic"
    case openAICompatible = "openai_compatible"
    case claudeSubscription = "claude_subscription"
    case codexSubscription = "codex_subscription"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropicKeyed: return "Anthropic (API key)"
        case .openAICompatible: return "OpenAI-compatible"
        case .claudeSubscription: return "Claude subscription"
        case .codexSubscription: return "Codex subscription"
        }
    }

    /// A one-line rationale for the provider picker.
    public var summary: String {
        switch self {
        case .anthropicKeyed:
            return "Messages API with a key stored in the Keychain"
        case .openAICompatible:
            return "Chat-completions host with a key — presets for OpenRouter, DeepSeek, Groq, xAI"
        case .claudeSubscription:
            return "Your paid Claude plan, driven through the `claude` CLI"
        case .codexSubscription:
            return "Your OpenAI Codex plan, driven through the `codex` CLI"
        }
    }

    /// Keyed providers authenticate with an API key stored in the Keychain.
    /// Subscription providers reuse the user's existing CLI login instead and
    /// Wormtongue stores nothing secret for them.
    public var isKeyed: Bool {
        switch self {
        case .anthropicKeyed, .openAICompatible: return true
        case .claudeSubscription, .codexSubscription: return false
        }
    }

    /// True when a conforming `LLMProvider` adapter exists in this build.
    ///
    /// All four catalogue providers ship adapters; the subscription providers
    /// reuse the user's existing CLI login and Wormtongue stores nothing secret.
    public var adapterAvailable: Bool {
        switch self {
        case .anthropicKeyed, .openAICompatible, .claudeSubscription, .codexSubscription:
            return true
        }
    }

    /// The default model string this provider serves when nothing overrides it,
    /// written in the provider's own model-string grammar:
    /// an Anthropic id / a `vendor/model` / a CLI model name.
    ///
    /// The concrete adapters (tickets #4–#6) finalize these values; here they back
    /// the status panel and the ultimate fallback in model resolution.
    public var defaultModel: String {
        switch self {
        case .anthropicKeyed: return "claude-haiku-4-5-20251001"
        case .openAICompatible: return "deepseek/deepseek-chat"
        case .claudeSubscription: return "claude-sonnet-4-5"
        case .codexSubscription: return "gpt-5-codex"
        }
    }

    /// Default base URL for a keyed provider, or nil for providers that get their
    /// host from a preset / the user, and for the subscription CLIs (no HTTP).
    public var defaultBaseURL: String? {
        switch self {
        case .anthropicKeyed: return "https://api.anthropic.com"
        case .openAICompatible: return nil
        case .claudeSubscription, .codexSubscription: return nil
        }
    }

    /// Where to read how to install and sign in to the CLI. For subscription
    /// providers only, and it is detect-and-document: there is no in-app OAuth.
    public var signInDocsURL: URL? {
        switch self {
        case .claudeSubscription:
            return URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup")
        case .codexSubscription:
            return URL(string: "https://developers.openai.com/codex/")
        case .anthropicKeyed, .openAICompatible:
            return nil
        }
    }

    /// The model string this provider should fall back to given its own
    /// per-provider settings. An OpenAI-compatible preset contributes its
    /// `vendor/model` default; otherwise the kind's default applies.
    public func defaultModel(settings: ProviderSettings?) -> String {
        if self == .openAICompatible, let preset = settings?.preset, let model = preset.defaultModel
        {
            return model
        }
        return defaultModel
    }
}

/// The OpenAI-compatible "chat/completions" hosts shipped as presets, plus custom.
///
/// A preset fixes the base URL and offers a sensible default model; the user may
/// still override the model (and the base URL is fixed for a preset). Choosing
/// custom means supplying both the base URL and a model yourself.
public enum OpenAICompatPreset: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case openRouter
    case deepSeek
    case groq
    case xAI
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .deepSeek: return "DeepSeek"
        case .groq: return "Groq"
        case .xAI: return "xAI"
        case .custom: return "Custom base URL"
        }
    }

    public var isCustom: Bool { self == .custom }

    /// Base URL for `chat/completions`, nil for custom (the user supplies it).
    public var baseURL: String? {
        switch self {
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .xAI: return "https://api.x.ai/v1"
        case .custom: return nil
        }
    }

    /// A sensible starter model for the preset, as a `vendor/model` (or provider
    /// id) string. Only a suggestion the user can override.
    public var defaultModel: String? {
        switch self {
        case .openRouter: return "anthropic/claude-sonnet-4-5"
        case .deepSeek: return "deepseek-chat"
        case .groq: return "llama-3.3-70b-versatile"
        case .xAI: return "grok-x"
        case .custom: return nil
        }
    }

    /// How this host can express the structured revise decision, declared
    /// statically per host (never probed at runtime) because JSON structured
    /// output is not portable across hosts: DeepSeek offers only the object form,
    /// xAI rejects `additionalProperties:false`, and Groq's strict schema mode is
    /// limited to specific models.
    ///
    /// Custom is an unknown host, so it gets no structured output and a `.revise`
    /// degrades to a plain insert via the seam. The JSON-object presets ask the
    /// model for valid JSON; the seam's `EditDecisionJSON` parse still degrades
    /// any malformed decision to a verbatim insert, so a rewrite is never guessed.
    public var structuredMode: OpenAICompatStructured {
        switch self {
        case .openRouter, .deepSeek, .groq, .xAI: return .jsonObject
        case .custom: return .none
        }
    }

    /// True when this host can express the structured revise decision.
    public var supportsStructuredOutput: Bool { structuredMode != .none }
}

/// Per-provider settings for the config file.
///
/// Keyed providers hold a base URL (or preset) and an optional model; the API key
/// itself lives in the Keychain and is never here. Subscription providers hold
/// nothing secret — only an optional model override for the `claude`/`codex`
/// `-m` flag. Every property is optional, so a missing or empty block decodes
/// without bricking startup.
public struct ProviderSettings: Codable, Sendable, Equatable {
    /// Which OpenAI-compatible preset, if any. Meaningful only for
    /// `.openAICompatible`.
    public var preset: OpenAICompatPreset?
    /// Base URL override. For a custom OpenAI-compatible host this is where the
    /// user supplies their endpoint; for Anthropic it can point at a gateway.
    public var baseURL: String?
    /// Optional model override for this provider, in the provider's grammar.
    public var model: String?

    public init(
        preset: OpenAICompatPreset? = nil, baseURL: String? = nil, model: String? = nil
    ) {
        self.preset = preset
        self.baseURL = baseURL
        self.model = model
    }

    // Sensible Anthropic defaults: everything derived, nothing stored.
    public static let anthropic = ProviderSettings()

    private enum CodingKeys: String, CodingKey {
        case preset, model
        case baseURL = "base_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown preset string must not brick the whole config load.
        preset = (try? c.decodeIfPresent(OpenAICompatPreset.self, forKey: .preset))
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        model = try c.decodeIfPresent(String.self, forKey: .model)
    }
}

/// Errors the rewrite pass can hit purely from the provider selection — no
/// transport involved — so the failure message is honest rather than a generic
/// network error.
public enum ProviderError: Error, LocalizedError, Equatable, Sendable {
    /// The selected provider has no `LLMProvider` adapter in this build yet.
    /// Selection still works; dictation reports the gap.
    case adapterUnavailable(ProviderKind)

    public var errorDescription: String? {
        switch self {
        case let .adapterUnavailable(kind):
            return
                "\(kind.displayName) is not wired into this build yet — select a provider below or check Setup."
        }
    }
}
