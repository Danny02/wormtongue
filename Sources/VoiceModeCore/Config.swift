import Foundation

/// One rewrite mode. Resolution order is bundle id → window title regex → default.
public struct Mode: Codable, Sendable, Equatable {
    public var name: String
    public var matchBundleIds: [String]
    public var matchWindowTitleRegex: String?
    /// Overrides `Config.model` for this mode.
    public var model: String?
    public var prompt: String

    enum CodingKeys: String, CodingKey {
        case name, model, prompt
        case matchBundleIds = "match_bundle_ids"
        case matchWindowTitleRegex = "match_window_title_regex"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        matchBundleIds = try c.decodeIfPresent([String].self, forKey: .matchBundleIds) ?? []
        matchWindowTitleRegex = try c.decodeIfPresent(String.self, forKey: .matchWindowTitleRegex)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        prompt = try c.decode(String.self, forKey: .prompt)
    }

    public init(
        name: String,
        matchBundleIds: [String] = [],
        matchWindowTitleRegex: String? = nil,
        model: String? = nil,
        prompt: String
    ) {
        self.name = name
        self.matchBundleIds = matchBundleIds
        self.matchWindowTitleRegex = matchWindowTitleRegex
        self.model = model
        self.prompt = prompt
    }
}

/// Push-to-talk, or press once to start and again to stop.
///
/// §8 of the brief left this open; both are implemented and the config picks.
public enum HotkeyMode: String, Codable, Sendable, Equatable {
    case hold
    case toggle
}

/// JSON at ~/.config/voicemode/config.json.
///
/// The brief allowed TOML or JSON; JSON avoids pulling in a TOML parser
/// dependency for a file only this app reads.
///
/// Every key is optional on decode: a config missing half its fields loads with
/// defaults for the rest rather than refusing to start, so one typo cannot brick
/// the app.
public struct Config: Codable, Sendable, Equatable {
    // MARK: Rewrite pass

    public var model: String
    public var maxTokens: Int
    /// Base URL for the Messages API. Point this at a gateway, a proxy, or a local
    /// mock; the wire format is unchanged. An invalid value falls back to
    /// Anthropic's host and is reported.
    public var apiBaseURL: String
    /// Extra request headers, for gateways that need their own auth. Applied first,
    /// so the built-in `x-api-key` and `anthropic-version` always win — the key
    /// stays in the Keychain and cannot be overridden from a plaintext file.
    public var apiHeaders: [String: String]

    // MARK: Local pass

    /// Hugging Face id of an MLX model for the on-device rewrite pass. Only
    /// meaningful in a build made with the local pass enabled.
    public var localModel: String
    /// Apps whose rewrite runs **on this Mac** instead of hitting the API. Answers
    /// §8 of the brief: sensitive apps get a real rewrite rather than the pass being
    /// skipped. Nothing leaves the machine, so these apps get field and window
    /// context without needing the opt-in rungs below.
    public var localOptInBundleIds: [String]

    // MARK: Transcription

    /// WhisperKit model name. Start with "base" — it downloads in seconds.
    /// Move to "large-v3-v20240930_turbo" once the pipeline works.
    public var whisperModel: String

    // MARK: Context and privacy

    /// Hard cap on surrounding-text characters sent to the API.
    public var contextCharCap: Int
    /// Hard cap on the focused field's own content. A field longer than this is
    /// sent truncated — and a truncated field is never rewritten wholesale, since
    /// that would replace text we never read.
    public var fieldCharCap: Int
    /// Proper nouns, ticket prefixes, internal jargon. Injected into every
    /// system prompt — the cheap substitute for fine-tuning.
    public var dictionary: [String]
    /// Denylist is on by default: apps opt IN to the cloud rewrite pass. Anything
    /// not listed here gets the raw transcript inserted, nothing leaves the machine.
    public var llmOptInBundleIds: [String]
    /// Apps allowed to have the *focused field's own* content sent. This is what
    /// enables editing an existing draft — replacing a selection, or acting on an
    /// instruction like "make that more formal" — because none of that is possible
    /// without reading the text first. Implied by `contextOptInBundleIds`.
    public var editOptInBundleIds: [String]
    /// Widest rung: apps allowed to have their surrounding on-screen text sent.
    public var contextOptInBundleIds: [String]
    /// Hard denies. Never transcribe, never probe, never send, never rewrite — not
    /// even locally. Wins over everything.
    public var deniedBundleIds: [String]

    // MARK: Behaviour

    public var hotkeyMode: HotkeyMode
    /// Insert the raw transcript immediately, then replace it when the rewrite
    /// returns. Off by default — replacement is backspace-based and fragile.
    public var insertRawFirst: Bool
    /// Floating status overlay near the bottom of the screen.
    public var showOverlay: Bool
    /// Short system sounds on start / insert / failure.
    public var soundFeedback: Bool
    public var modes: [Mode]

    public static let fallback = Config(
        model: "claude-haiku-4-5-20251001",
        maxTokens: 1024,
        apiBaseURL: "https://api.anthropic.com",
        apiHeaders: [:],
        localModel: "mlx-community/Qwen3-4B-4bit",
        localOptInBundleIds: [],
        whisperModel: "base",
        contextCharCap: 4000,
        fieldCharCap: 4000,
        dictionary: [],
        llmOptInBundleIds: [],
        editOptInBundleIds: [],
        contextOptInBundleIds: [],
        deniedBundleIds: [
            "com.apple.keychainaccess",
            "com.1password.1password",
            "com.agilebits.onepassword7",
        ],
        hotkeyMode: .hold,
        insertRawFirst: false,
        showOverlay: true,
        soundFeedback: true,
        modes: [
            Mode(
                name: "default",
                prompt:
                    "Clean up filler words and punctuation. Change nothing else. Output only the cleaned text."
            )
        ]
    )

    /// Spelled out rather than relying on `.convertFromSnakeCase`, which is not the
    /// inverse of `.convertToSnakeCase` for names containing acronyms: it turns
    /// `api_base_url` into `apiBaseUrl`, missing `apiBaseURL` entirely.
    enum CodingKeys: String, CodingKey {
        case model, dictionary, modes
        case maxTokens = "max_tokens"
        case apiBaseURL = "api_base_url"
        case apiHeaders = "api_headers"
        case localModel = "local_model"
        case localOptInBundleIds = "local_opt_in_bundle_ids"
        case whisperModel = "whisper_model"
        case contextCharCap = "context_char_cap"
        case fieldCharCap = "field_char_cap"
        case llmOptInBundleIds = "llm_opt_in_bundle_ids"
        case editOptInBundleIds = "edit_opt_in_bundle_ids"
        case contextOptInBundleIds = "context_opt_in_bundle_ids"
        case deniedBundleIds = "denied_bundle_ids"
        case hotkeyMode = "hotkey_mode"
        case insertRawFirst = "insert_raw_first"
        case showOverlay = "show_overlay"
        case soundFeedback = "sound_feedback"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.fallback
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? d.maxTokens
        apiBaseURL = try c.decodeIfPresent(String.self, forKey: .apiBaseURL) ?? d.apiBaseURL
        apiHeaders =
            try c.decodeIfPresent([String: String].self, forKey: .apiHeaders) ?? d.apiHeaders
        localModel = try c.decodeIfPresent(String.self, forKey: .localModel) ?? d.localModel
        localOptInBundleIds =
            try c.decodeIfPresent([String].self, forKey: .localOptInBundleIds)
            ?? d.localOptInBundleIds
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? d.whisperModel
        contextCharCap =
            try c.decodeIfPresent(Int.self, forKey: .contextCharCap) ?? d.contextCharCap
        fieldCharCap = try c.decodeIfPresent(Int.self, forKey: .fieldCharCap) ?? d.fieldCharCap
        dictionary = try c.decodeIfPresent([String].self, forKey: .dictionary) ?? d.dictionary
        llmOptInBundleIds =
            try c.decodeIfPresent([String].self, forKey: .llmOptInBundleIds) ?? d.llmOptInBundleIds
        editOptInBundleIds =
            try c.decodeIfPresent([String].self, forKey: .editOptInBundleIds)
            ?? d.editOptInBundleIds
        contextOptInBundleIds =
            try c.decodeIfPresent([String].self, forKey: .contextOptInBundleIds)
            ?? d.contextOptInBundleIds
        deniedBundleIds =
            try c.decodeIfPresent([String].self, forKey: .deniedBundleIds) ?? d.deniedBundleIds
        // An unrecognised hotkey mode falls back rather than failing the decode.
        hotkeyMode = (try? c.decodeIfPresent(HotkeyMode.self, forKey: .hotkeyMode)) ?? d.hotkeyMode
        insertRawFirst =
            try c.decodeIfPresent(Bool.self, forKey: .insertRawFirst) ?? d.insertRawFirst
        showOverlay = try c.decodeIfPresent(Bool.self, forKey: .showOverlay) ?? d.showOverlay
        soundFeedback = try c.decodeIfPresent(Bool.self, forKey: .soundFeedback) ?? d.soundFeedback
        modes = try c.decodeIfPresent([Mode].self, forKey: .modes) ?? d.modes
        // A config with "modes": [] would otherwise leave nothing to resolve to.
        if modes.isEmpty { modes = d.modes }
    }

    public init(
        model: String,
        maxTokens: Int,
        apiBaseURL: String,
        apiHeaders: [String: String],
        localModel: String,
        localOptInBundleIds: [String],
        whisperModel: String,
        contextCharCap: Int,
        fieldCharCap: Int,
        dictionary: [String],
        llmOptInBundleIds: [String],
        editOptInBundleIds: [String],
        contextOptInBundleIds: [String],
        deniedBundleIds: [String],
        hotkeyMode: HotkeyMode,
        insertRawFirst: Bool,
        showOverlay: Bool,
        soundFeedback: Bool,
        modes: [Mode]
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.apiBaseURL = apiBaseURL
        self.apiHeaders = apiHeaders
        self.localModel = localModel
        self.localOptInBundleIds = localOptInBundleIds
        self.whisperModel = whisperModel
        self.contextCharCap = contextCharCap
        self.fieldCharCap = fieldCharCap
        self.dictionary = dictionary
        self.llmOptInBundleIds = llmOptInBundleIds
        self.editOptInBundleIds = editOptInBundleIds
        self.contextOptInBundleIds = contextOptInBundleIds
        self.deniedBundleIds = deniedBundleIds
        self.hotkeyMode = hotkeyMode
        self.insertRawFirst = insertRawFirst
        self.showOverlay = showOverlay
        self.soundFeedback = soundFeedback
        self.modes = modes
    }

    /// The parsed endpoint, or nil when `apiBaseURL` is unusable.
    public var endpoint: APIEndpoint? { APIEndpoint(base: apiBaseURL) }

    // MARK: - Coding

    public static func decode(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

extension Config {
    /// What lands on disk the first time the app runs — the modes from §5 of the
    /// brief, with every opt-in list empty so nothing is sent until the user says so.
    public static let seed = Config(
        model: "claude-haiku-4-5-20251001",
        maxTokens: 1024,
        apiBaseURL: "https://api.anthropic.com",
        apiHeaders: [:],
        localModel: "mlx-community/Qwen3-4B-4bit",
        localOptInBundleIds: [],
        whisperModel: "base",
        contextCharCap: 4000,
        fieldCharCap: 4000,
        dictionary: [],
        llmOptInBundleIds: [],
        editOptInBundleIds: [],
        contextOptInBundleIds: [],
        deniedBundleIds: Config.fallback.deniedBundleIds,
        hotkeyMode: .hold,
        insertRawFirst: false,
        showOverlay: true,
        soundFeedback: true,
        modes: [
            Mode(
                name: "slack",
                matchBundleIds: ["com.tinyspeck.slackmacgap"],
                prompt: """
                    You rewrite dictated speech into a Slack message.
                    Preserve the speaker's intent and tone; do not add content.
                    Use @mentions for names that appear in the provided channel context.
                    Keep ticket keys like EN-66 uppercase. Use Slack markdown.
                    Output only the message text.
                    """),
            Mode(
                name: "code",
                matchBundleIds: ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"],
                prompt: """
                    You rewrite dictated speech into text for a code editor.
                    Identifiers, file paths, and type names keep their exact casing.
                    Do not explain and do not add commentary.
                    Output only the text to insert.
                    """),
            Mode(
                name: "default",
                prompt:
                    "Clean up filler words and punctuation. Change nothing else. Output only the cleaned text."
            ),
        ]
    )
}
