import Foundation
import Testing

@testable import VoiceModeCore

@Suite("Config decoding")
struct ConfigTests {

    @Test("Missing keys fall back to defaults instead of failing the whole decode")
    func partialConfigLoads() throws {
        let json = #"{ "whisper_model": "large-v3-v20240930_turbo" }"#
        let config = try Config.decode(Data(json.utf8))

        #expect(config.whisperModel == "large-v3-v20240930_turbo")
        #expect(config.model == Config.fallback.model)
        #expect(config.maxTokens == Config.fallback.maxTokens)
        #expect(config.contextCharCap == Config.fallback.contextCharCap)
        #expect(config.fieldCharCap == Config.fallback.fieldCharCap)
        #expect(config.showOverlay)
        #expect(config.soundFeedback)
        #expect(config.modes.count == 1)
    }

    @Test("snake_case keys map onto camelCase properties")
    func snakeCaseKeys() throws {
        let json = """
            {
              "max_tokens": 42,
              "context_char_cap": 99,
              "field_char_cap": 55,
              "llm_opt_in_bundle_ids": ["a"],
              "edit_opt_in_bundle_ids": ["e"],
              "context_opt_in_bundle_ids": ["b"],
              "denied_bundle_ids": ["c"],
              "insert_raw_first": true,
              "show_overlay": false,
              "sound_feedback": false
            }
            """
        let config = try Config.decode(Data(json.utf8))

        #expect(config.maxTokens == 42)
        #expect(config.contextCharCap == 99)
        #expect(config.fieldCharCap == 55)
        #expect(config.llmOptInBundleIds == ["a"])
        #expect(config.editOptInBundleIds == ["e"])
        #expect(config.contextOptInBundleIds == ["b"])
        #expect(config.deniedBundleIds == ["c"])
        #expect(config.insertRawFirst)
        #expect(!config.showOverlay)
        #expect(!config.soundFeedback)
    }

    @Test("Comment-style unknown keys are ignored, as the example config relies on")
    func unknownKeysIgnored() throws {
        let json = #"{ "//": "a note", "model": "m", "future_flag": 3 }"#
        let config = try Config.decode(Data(json.utf8))
        #expect(config.model == "m")
    }

    @Test("An explicitly empty modes array still leaves something to resolve to")
    func emptyModesBackfilled() throws {
        let config = try Config.decode(Data(#"{ "modes": [] }"#.utf8))
        #expect(config.modes.count == 1)
        #expect(config.modes[0].name == "default")
    }

    @Test("A mode without a prompt is a hard error — silently dropping it would hide the typo")
    func modeRequiresPrompt() {
        let json = #"{ "modes": [{ "name": "slack" }] }"#
        #expect(throws: (any Error).self) {
            try Config.decode(Data(json.utf8))
        }
    }

    @Test("Malformed JSON throws rather than half-loading")
    func malformedJSON() {
        #expect(throws: (any Error).self) {
            try Config.decode(Data("{ not json".utf8))
        }
    }

    @Test("The seeded config round-trips through encode and decode")
    func seedRoundTrips() throws {
        let restored = try Config.decode(Config.seed.encoded())
        #expect(restored == Config.seed)
    }

    @Test("Every field round-trips at a non-default value")
    func roundTripsWithNonDefaults() throws {
        // Comparing a round-tripped default against the default proves nothing: a
        // key that fails to decode falls back to exactly the value being compared.
        var config = Config.seed
        config.model = "some-other-model"
        config.maxTokens = 4321
        config.apiBaseURL = "https://gw.example.com/anthropic"
        config.apiHeaders = ["x-gw": "token"]
        config.whisperModel = "tiny"
        config.contextCharCap = 111
        config.fieldCharCap = 222
        config.dictionary = ["Heiko"]
        config.llmOptInBundleIds = ["llm.app"]
        config.editOptInBundleIds = ["edit.app"]
        config.contextOptInBundleIds = ["ctx.app"]
        config.deniedBundleIds = ["denied.app"]
        config.hotkeyMode = .toggle
        config.insertRawFirst = true
        config.showOverlay = false
        config.soundFeedback = false

        let restored = try Config.decode(config.encoded())
        #expect(restored == config)
    }

    @Test("The shipped example config parses and matches its documented intent")
    func exampleConfigParses() throws {
        // Walk up from Tests/VoiceModeCoreTests/ to the package root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "config.example.json"))
        let config = try Config.decode(data)

        #expect(config.modes.contains { $0.name == "slack" })
        #expect(config.modes.contains { $0.name == "default" })
        // Slack may see context; VS Code gets the LLM pass but no screen text.
        #expect(config.contextOptInBundleIds == ["com.tinyspeck.slackmacgap"])
        #expect(config.llmOptInBundleIds.contains("com.microsoft.VSCode"))
        #expect(!config.contextOptInBundleIds.contains("com.microsoft.VSCode"))
        // VS Code may edit its own field without the whole window being sent.
        #expect(config.editOptInBundleIds.contains("com.microsoft.VSCode"))
        let resolver = ModeResolver(config: config)
        let code = resolver.policy(for: "com.microsoft.VSCode")
        #expect(code.fieldAllowed)
        #expect(!code.contextAllowed)
        // Every regex in the example must actually compile.
        #expect(resolver.invalidTitlePatterns.isEmpty)
    }
}
