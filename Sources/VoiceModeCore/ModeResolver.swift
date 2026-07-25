import Foundation

/// What the privacy rules decided for one utterance.
public struct Policy: Sendable, Equatable {
    /// Hard-denied app: raw transcript, not even probed, nothing sent.
    public var denied: Bool
    /// App opted in to the LLM rewrite pass.
    public var llmAllowed: Bool
    /// App opted in to having its on-screen text sent along.
    public var contextAllowed: Bool

    public init(denied: Bool, llmAllowed: Bool, contextAllowed: Bool) {
        self.denied = denied
        self.llmAllowed = llmAllowed
        self.contextAllowed = contextAllowed
    }
}

/// Mode matching, the privacy policy, and prompt assembly.
///
/// Built once per config load, not once per dictation: the bundle-id lists become
/// sets and the window-title patterns are compiled up front. The naive version
/// recompiled every `NSRegularExpression` on every utterance, inside the latency
/// budget, for no reason.
public struct ModeResolver: Sendable {
    public let config: Config

    private let llmOptIn: Set<String>
    private let contextOptIn: Set<String>
    private let denied: Set<String>
    private let modesByBundleId: [String: Mode]
    private let titleModes: [(mode: Mode, regex: NSRegularExpression)]
    private let defaultMode: Mode
    private let dictionaryBlock: String?

    public init(config: Config) {
        self.config = config
        self.llmOptIn = Set(config.llmOptInBundleIds)
        self.contextOptIn = Set(config.contextOptInBundleIds)
        self.denied = Set(config.deniedBundleIds)

        // First mode listed wins a given bundle id.
        var byBundle: [String: Mode] = [:]
        for mode in config.modes {
            for id in mode.matchBundleIds where byBundle[id] == nil {
                byBundle[id] = mode
            }
        }
        self.modesByBundleId = byBundle

        self.titleModes = config.modes.compactMap { mode in
            guard let pattern = mode.matchWindowTitleRegex else { return nil }
            guard
                let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { return nil }
            return (mode, regex)
        }

        self.defaultMode =
            config.modes.first { $0.name == "default" }
            ?? config.modes.first
            ?? Config.fallback.modes[0]

        if config.dictionary.isEmpty {
            self.dictionaryBlock = nil
        } else {
            self.dictionaryBlock = """
                <dictionary>
                These terms appear in the speaker's vocabulary. Spell them exactly as
                written here when the transcript approximates them: \
                \(config.dictionary.joined(separator: ", "))
                </dictionary>
                """
        }
    }

    /// Patterns that failed to compile, so the Setup window can say so instead of
    /// the mode silently never matching.
    public var invalidTitlePatterns: [String] {
        let compiled = Set(titleModes.compactMap { $0.mode.matchWindowTitleRegex })
        return config.modes.compactMap { mode in
            guard let pattern = mode.matchWindowTitleRegex, !compiled.contains(pattern) else {
                return nil
            }
            return "\(mode.name): \(pattern)"
        }
    }

    // MARK: - Policy

    public func policy(for bundleId: String?) -> Policy {
        // An app we cannot identify is treated as not opted in.
        guard let bundleId else {
            return Policy(denied: false, llmAllowed: false, contextAllowed: false)
        }
        if denied.contains(bundleId) {
            return Policy(denied: true, llmAllowed: false, contextAllowed: false)
        }
        let llm = llmOptIn.contains(bundleId)
        return Policy(
            denied: false,
            llmAllowed: llm,
            // Context without an LLM pass is meaningless — nothing would consume it.
            contextAllowed: llm && contextOptIn.contains(bundleId)
        )
    }

    // MARK: - Mode

    public func mode(bundleId: String?, windowTitle: String?) -> Mode {
        if let bundleId, let hit = modesByBundleId[bundleId] { return hit }
        if let windowTitle, !windowTitle.isEmpty {
            let range = NSRange(windowTitle.startIndex..., in: windowTitle)
            for candidate in titleModes {
                if candidate.regex.firstMatch(in: windowTitle, range: range) != nil {
                    return candidate.mode
                }
            }
        }
        return defaultMode
    }

    // MARK: - Prompt assembly

    /// System prompt = mode prompt + the static dictionary block.
    public func systemPrompt(for mode: Mode) -> String {
        guard let dictionaryBlock else { return mode.prompt }
        return mode.prompt + "\n\n" + dictionaryBlock
    }

    /// User message = context (when allowed) + the raw transcript.
    public func userMessage(
        transcript: String, context: FieldContext?, contextAllowed: Bool
    )
        -> String
    {
        var parts: [String] = []
        if contextAllowed, let context {
            if let app = context.appName { parts.append(tagged("app", app)) }
            if let title = context.windowTitle, !title.isEmpty {
                parts.append(tagged("window", title))
            }
            if let field = context.fieldValue, !field.isEmpty {
                parts.append(tagged("current_field_content", field, multiline: true))
            }
            if let surrounding = context.surroundingText, !surrounding.isEmpty {
                parts.append(tagged("visible_context", surrounding, multiline: true))
            }
        }
        // The transcript is the payload, not untrusted input — it goes through
        // verbatim. Mangling angle brackets here would corrupt dictated code.
        parts.append(tagged("transcript", transcript, multiline: true, neutralize: false))
        return parts.joined(separator: "\n\n")
    }

    private func tagged(
        _ tag: String, _ body: String, multiline: Bool = false, neutralize: Bool = true
    ) -> String {
        let body = neutralize ? Self.neutralizeTags(in: body) : body
        return multiline ? "<\(tag)>\n\(body)\n</\(tag)>" : "<\(tag)>\(body)</\(tag)>"
    }

    /// Whatever is on screen is untrusted text. A Slack message containing
    /// `</visible_context>` would otherwise let the surrounding conversation close
    /// our own tag and read as instructions. Break the delimiters rather than
    /// drop content — the model still sees the words, just not a usable tag.
    static func neutralizeTags(in text: String) -> String {
        guard text.contains("<") else { return text }
        return text.replacingOccurrences(of: "<", with: "\u{2039}")
            .replacingOccurrences(of: ">", with: "\u{203A}")
    }
}
