import Foundation

/// One rewrite mode. Resolution order is bundle id → window title regex → default.
struct Mode: Codable {
    var name: String
    var matchBundleIds: [String]
    var matchWindowTitleRegex: String?
    /// Overrides `Config.model` for this mode.
    var model: String?
    var prompt: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        matchBundleIds = try c.decodeIfPresent([String].self, forKey: .matchBundleIds) ?? []
        matchWindowTitleRegex = try c.decodeIfPresent(String.self, forKey: .matchWindowTitleRegex)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        prompt = try c.decode(String.self, forKey: .prompt)
    }

    init(name: String, matchBundleIds: [String] = [], matchWindowTitleRegex: String? = nil,
         model: String? = nil, prompt: String) {
        self.name = name
        self.matchBundleIds = matchBundleIds
        self.matchWindowTitleRegex = matchWindowTitleRegex
        self.model = model
        self.prompt = prompt
    }
}

/// JSON at ~/.config/voicemode/config.json.
///
/// The brief allowed TOML or JSON; JSON avoids pulling in a TOML parser
/// dependency for a file only this app reads.
struct Config: Codable {
    var model: String
    var maxTokens: Int
    /// WhisperKit model name. Start with "base" — it downloads in seconds.
    /// Move to "large-v3-v20240930_turbo" once the pipeline works.
    var whisperModel: String
    /// Hard cap on surrounding-text characters sent to the API.
    var contextCharCap: Int
    /// Proper nouns, ticket prefixes, internal jargon. Injected into every
    /// system prompt — the cheap substitute for fine-tuning.
    var dictionary: [String]
    /// Denylist is on by default: apps opt IN to the LLM pass. Anything not
    /// listed here gets the raw transcript inserted, nothing leaves the machine.
    var llmOptInBundleIds: [String]
    /// Narrower still: apps allowed to have their on-screen text sent to the API.
    var contextOptInBundleIds: [String]
    /// Hard denies. Never transcribe, never probe, never send. Wins over everything.
    var deniedBundleIds: [String]
    /// Insert the raw transcript immediately, then replace it when the LLM
    /// returns. Off by default — replacement is backspace-based and fragile.
    var insertRawFirst: Bool
    var modes: [Mode]

    static let `default` = Config(
        model: "claude-haiku-4-5-20251001",
        maxTokens: 1024,
        whisperModel: "base",
        contextCharCap: 4000,
        dictionary: [],
        llmOptInBundleIds: [],
        contextOptInBundleIds: [],
        deniedBundleIds: [
            "com.apple.keychainaccess",
            "com.1password.1password",
            "com.agilebits.onepassword7",
        ],
        insertRawFirst: false,
        modes: [
            Mode(name: "default",
                 prompt: "Clean up filler words and punctuation. Change nothing else. Output only the cleaned text.")
        ]
    )

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.default
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? d.maxTokens
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? d.whisperModel
        contextCharCap = try c.decodeIfPresent(Int.self, forKey: .contextCharCap) ?? d.contextCharCap
        dictionary = try c.decodeIfPresent([String].self, forKey: .dictionary) ?? d.dictionary
        llmOptInBundleIds = try c.decodeIfPresent([String].self, forKey: .llmOptInBundleIds) ?? d.llmOptInBundleIds
        contextOptInBundleIds = try c.decodeIfPresent([String].self, forKey: .contextOptInBundleIds) ?? d.contextOptInBundleIds
        deniedBundleIds = try c.decodeIfPresent([String].self, forKey: .deniedBundleIds) ?? d.deniedBundleIds
        insertRawFirst = try c.decodeIfPresent(Bool.self, forKey: .insertRawFirst) ?? d.insertRawFirst
        modes = try c.decodeIfPresent([Mode].self, forKey: .modes) ?? d.modes
    }

    init(model: String, maxTokens: Int, whisperModel: String, contextCharCap: Int,
         dictionary: [String], llmOptInBundleIds: [String], contextOptInBundleIds: [String],
         deniedBundleIds: [String], insertRawFirst: Bool, modes: [Mode]) {
        self.model = model
        self.maxTokens = maxTokens
        self.whisperModel = whisperModel
        self.contextCharCap = contextCharCap
        self.dictionary = dictionary
        self.llmOptInBundleIds = llmOptInBundleIds
        self.contextOptInBundleIds = contextOptInBundleIds
        self.deniedBundleIds = deniedBundleIds
        self.insertRawFirst = insertRawFirst
        self.modes = modes
    }
}

enum ConfigStore {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/voicemode/config.json")
    }

    /// Loads the config, seeding the file from the bundled example on first run.
    static func load() -> (config: Config, error: String?) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do { try seed() } catch {
                return (.default, "Could not write \(url.path): \(error.localizedDescription)")
            }
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return (try decoder.decode(Config.self, from: data), nil)
        } catch {
            return (.default, "\(url.lastPathComponent) is invalid, using defaults: \(error.localizedDescription)")
        }
    }

    private static func seed() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Config.exampleForSeeding).write(to: url)
    }
}

extension Config {
    /// What lands on disk the first time the app runs — the modes from §5 of the
    /// brief, with the opt-in lists empty so nothing is sent until the user says so.
    static let exampleForSeeding = Config(
        model: "claude-haiku-4-5-20251001",
        maxTokens: 1024,
        whisperModel: "base",
        contextCharCap: 4000,
        dictionary: [],
        llmOptInBundleIds: [],
        contextOptInBundleIds: [],
        deniedBundleIds: Config.default.deniedBundleIds,
        insertRawFirst: false,
        modes: [
            Mode(name: "slack",
                 matchBundleIds: ["com.tinyspeck.slackmacgap"],
                 prompt: """
                 You rewrite dictated speech into a Slack message.
                 Preserve the speaker's intent and tone; do not add content.
                 Use @mentions for names that appear in the provided channel context.
                 Keep ticket keys like EN-66 uppercase. Use Slack markdown.
                 Output only the message text.
                 """),
            Mode(name: "code",
                 matchBundleIds: ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"],
                 prompt: """
                 You rewrite dictated speech into text for a code editor.
                 Identifiers, file paths, and type names keep their exact casing.
                 Do not explain and do not add commentary.
                 Output only the text to insert.
                 """),
            Mode(name: "default",
                 prompt: "Clean up filler words and punctuation. Change nothing else. Output only the cleaned text."),
        ]
    )
}
