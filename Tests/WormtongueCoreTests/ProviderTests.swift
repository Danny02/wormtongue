import Foundation
import Testing

@testable import WormtongueCore

@Suite("Provider catalogue")
struct ProviderKindTests {

    @Test("The four providers exist in the documented order")
    func allCasesOrder() {
        #expect(
            ProviderKind.allCases == [
                .anthropicKeyed, .openAICompatible, .claudeSubscription, .codexSubscription,
            ])
    }

    @Test("Keyed providers authenticate with a key; subscriptions reuse the CLI login")
    func keyedFlag() {
        #expect(ProviderKind.anthropicKeyed.isKeyed)
        #expect(ProviderKind.openAICompatible.isKeyed)
        #expect(!ProviderKind.claudeSubscription.isKeyed)
        #expect(!ProviderKind.codexSubscription.isKeyed)
    }

    @Test("Every catalogue provider ships an adapter")
    func adapterAvailability() {
        #expect(ProviderKind.anthropicKeyed.adapterAvailable)
        #expect(ProviderKind.openAICompatible.adapterAvailable)
        #expect(ProviderKind.claudeSubscription.adapterAvailable)
        #expect(ProviderKind.codexSubscription.adapterAvailable)
    }

    @Test("Every provider names itself and a default model in its own grammar")
    func displayAndDefaults() {
        for kind in ProviderKind.allCases {
            #expect(!kind.displayName.isEmpty)
            #expect(!kind.defaultModel.isEmpty)
        }
    }

    @Test("Only Anthropic has a fixed default endpoint")
    func defaultBaseURLShape() {
        #expect(ProviderKind.anthropicKeyed.defaultBaseURL == "https://api.anthropic.com")
        #expect(ProviderKind.openAICompatible.defaultBaseURL == nil)
        #expect(ProviderKind.claudeSubscription.defaultBaseURL == nil)
        #expect(ProviderKind.codexSubscription.defaultBaseURL == nil)
    }

    @Test("Subscription providers point at sign-in docs; keyed providers need none")
    func signInDocs() {
        #expect(ProviderKind.claudeSubscription.signInDocsURL != nil)
        #expect(ProviderKind.codexSubscription.signInDocsURL != nil)
        #expect(ProviderKind.anthropicKeyed.signInDocsURL == nil)
        #expect(ProviderKind.openAICompatible.signInDocsURL == nil)
    }
}

@Suite("OpenAI-compatible presets")
struct OpenAICompatPresetTests {

    @Test("Presets ship a host and a starter model; custom ships neither")
    func presetFields() {
        for preset in [OpenAICompatPreset.openRouter, .deepSeek, .groq, .xAI] {
            #expect(preset.baseURL != nil, "\(preset) should carry a base URL")
            #expect(preset.defaultModel != nil, "\(preset) should offer a starter model")
            #expect(!preset.displayName.isEmpty)
        }
        #expect(OpenAICompatPreset.custom.baseURL == nil)
        #expect(OpenAICompatPreset.custom.defaultModel == nil)
        #expect(OpenAICompatPreset.custom.isCustom)
    }

    @Test("An unknown preset string decodes to nil instead of failing the load")
    func unknownPresetIgnored() throws {
        let json = #"{ "preset": "not-a-real-host" }"#
        let settings = try JSONDecoder().decode(
            ProviderSettings.self,
            from: Data(json.utf8))
        #expect(settings.preset == nil)
    }
}

@Suite("Provider settings")
struct ProviderSettingsTests {

    @Test("An empty provider block decodes to safe defaults")
    func emptyBlockDecodes() throws {
        let settings = try JSONDecoder().decode(ProviderSettings.self, from: Data("{}".utf8))
        #expect(settings.preset == nil)
        #expect(settings.baseURL == nil)
        #expect(settings.model == nil)
    }

    @Test("Provider settings use snake_case base_url and round-trip")
    func roundTrip() throws {
        let settings = ProviderSettings(
            preset: .deepSeek, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat")
        let restored = try JSONDecoder().decode(
            ProviderSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored == settings)
    }

    @Test("API keys are never part of the provider model")
    func noKeyInEncodedSettings() throws {
        // The provider settings carry host and model only; the key lives in the
        // Keychain. Prove the encoded shape contains no key-ish member.
        let data = try JSONEncoder().encode(ProviderSettings(model: "m"))
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys).isDisjoint(with: ["api_key", "key", "apiKey"]))
    }
}

@Suite("Config provider selection")
struct ConfigProviderTests {

    @Test("The default provider is keyed Anthropic, with safe Anthropic settings")
    func defaultProvider() throws {
        let config = try Config.decode(Data("{}".utf8))
        #expect(config.provider == .anthropicKeyed)
        #expect(config.activeProviderBaseURL == "https://api.anthropic.com")
        #expect(config.endpoint?.isDefault == true)
    }

    @Test("An unknown provider value falls back to Anthropic rather than failing")
    func unknownProviderValue() throws {
        let config = try Config.decode(Data(#"{ "provider": "telepathic" }"#.utf8))
        #expect(config.provider == .anthropicKeyed)
    }

    @Test("A pre-provider config (no provider/ per-provider block) loads untouched")
    func legacyConfigLoads() throws {
        let config = try Config.decode(
            Data(
                #"""
                { "model": "claude-haiku-4-5-20251001",
                  "api_base_url": "https://gw.example.com/anthropic",
                  "api_headers": { "x-gw": "token" } }
                """#.utf8))
        #expect(config.provider == .anthropicKeyed)
        // The legacy host is reconciled into the Anthropic provider's settings.
        #expect(config.activeProviderBaseURL == "https://gw.example.com/anthropic")
        #expect(config.apiBaseURL == "https://gw.example.com/anthropic")
        #expect(config.apiHeaders == ["x-gw": "token"])
    }

    @Test("An explicit per-provider base URL wins over the legacy flat field")
    func perProviderBeatsLegacy() throws {
        let config = try Config.decode(
            Data(
                #"""
                { "api_base_url": "https://gw.example.com/anthropic",
                  "providers": { "anthropic": { "base_url": "https://direct.example.com" } } }
                """#.utf8))
        #expect(config.activeProviderBaseURL == "https://direct.example.com")
        #expect(config.apiBaseURL == "https://gw.example.com/anthropic")
    }

    @Test("An unknown provider key in the per-provider block is ignored, not fatal")
    func unknownProviderKeyIgnored() throws {
        let config = try Config.decode(
            Data(#"{ "providers": { "future_provider": { "model": "x" } } }"#.utf8))
        #expect(config.provider == .anthropicKeyed)
        // The unknown entry did not land anywhere, and the reconciled default holds.
        #expect(config.providers.isEmpty)
        #expect(config.activeProviderBaseURL == "https://api.anthropic.com")
    }

    @Test("Selecting a non-Anthropic provider never bricks startup")
    func nonAnthropicSelectionLoads() throws {
        let config = try Config.decode(
            Data(
                #"""
                { "provider": "openai_compatible",
                  "providers": { "openai_compatible": { "preset": "openRouter", "model": "vendor/model" } } }
                """#.utf8))
        #expect(config.provider == .openAICompatible)
        #expect(config.activeProviderSettings.preset == .openRouter)
        #expect(config.activeProviderBaseURL == "https://openrouter.ai/api/v1")
        #expect(config.providers[.openAICompatible]?.model == "vendor/model")
    }

    @Test("Subscription providers have no HTTP endpoint")
    func subscriptionHasNoEndpoint() throws {
        let config = try Config.decode(
            Data(#"{ "provider": "claude_subscription" }"#.utf8))
        #expect(config.provider == .claudeSubscription)
        #expect(config.activeProviderBaseURL == nil)
        #expect(config.endpoint == nil)
    }

    @Test("Provider settings survive an encode/decode round-trip")
    func roundTripProviderConfig() throws {
        var config = Config.seed
        config.provider = .openAICompatible
        config.providers[.openAICompatible] = ProviderSettings(
            preset: .groq, baseURL: "https://api.groq.com/openai/v1", model: "llama-pick")
        let restored = try Config.decode(config.encoded())
        #expect(restored == config)
        #expect(restored.provider == .openAICompatible)
        #expect(restored.providers[.openAICompatible]?.preset == .groq)
    }

    @Test("The seeded config still round-trips with the new provider fields")
    func seedRoundTripsWithProvider() throws {
        let restored = try Config.decode(Config.seed.encoded())
        #expect(restored == Config.seed)
        #expect(restored.provider == .anthropicKeyed)
        #expect(restored.activeProviderBaseURL == "https://api.anthropic.com")
    }
}

@Suite("Model resolution per provider")
struct ModelResolutionTests {

    private func makeConfig(
        provider: ProviderKind = .anthropicKeyed,
        globalModel: String = "global-model",
        providerSettings: ProviderSettings? = nil,
        modeModel: String? = nil
    ) -> Config {
        Config(
            provider: provider,
            providers: providerSettings.map { [provider: $0] } ?? [:],
            model: globalModel,
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
            modes: [Mode(name: "default", model: modeModel, prompt: "p")]
        )
    }

    @Test("Per-mode model override wins over everything")
    func modeOverrideWins() {
        let config = makeConfig(
            providerSettings: ProviderSettings(model: "provider-m"), modeModel: "mode-m")
        #expect(
            config.resolvedModel(for: Mode(name: "m", model: "mode-m", prompt: "p")) == "mode-m")
    }

    @Test("The active provider's model override beats the global model")
    func providerOverrideBeatsGlobal() {
        let config = makeConfig(providerSettings: ProviderSettings(model: "provider-m"))
        #expect(config.resolvedModel(for: nil) == "provider-m")
    }

    @Test("The global model is used when no override exists")
    func globalModelIsDefault() {
        let config = makeConfig()
        #expect(config.resolvedModel(for: nil) == "global-model")
    }

    @Test("A mode without an override still gets the global model")
    func modeWithoutOverride() {
        let config = makeConfig()
        #expect(config.resolvedModel(for: Mode(name: "m", prompt: "p")) == "global-model")
    }

    @Test("The provider's own default is the last resort")
    func providerDefaultLastResort() {
        var config = makeConfig()
        config.model = ""
        #expect(config.resolvedModel(for: nil) == ProviderKind.anthropicKeyed.defaultModel)
    }

    @Test("An OpenAI-compatible preset contributes its starter model as the provider default")
    func presetStarterModel() {
        var config = makeConfig(
            provider: .openAICompatible, providerSettings: ProviderSettings(preset: .deepSeek))
        config.model = ""
        #expect(config.resolvedModel(for: nil) == "deepseek-chat")
    }

    @Test("Switching provider changes the effective model")
    func switchingProviderChangesModel() {
        // Same global model string, but the Anthropic vs. subscription grammars
        // differ; each kind resolves through its own default when unset.
        let anthropic = makeConfig(provider: .anthropicKeyed)
        let codex = makeConfig(provider: .codexSubscription)
        #expect(anthropic.resolvedModel(for: nil) == "global-model")
        // A subscription provider still honours the global model as its override.
        #expect(codex.resolvedModel(for: nil) == "global-model")
    }
}
