import Foundation

/// What the privacy rules decided for one utterance.
///
/// A ladder, each rung strictly wider than the last: the rewrite pass, then the
/// focused field's own text, then everything visible in the window. Editing an
/// existing draft requires the middle rung — you cannot revise text you were not
/// allowed to read.
public struct Policy: Sendable, Equatable {
    /// Hard-denied app: raw transcript, not even probed, nothing sent.
    public var denied: Bool
    /// App opted in to the rewrite pass.
    public var llmAllowed: Bool
    /// App opted in to having the focused field's own content sent, which is what
    /// makes selection replacement and draft revision possible.
    public var fieldAllowed: Bool
    /// App opted in to having its surrounding on-screen text sent along.
    public var contextAllowed: Bool

    public init(denied: Bool, llmAllowed: Bool, fieldAllowed: Bool, contextAllowed: Bool) {
        self.denied = denied
        self.llmAllowed = llmAllowed
        self.fieldAllowed = fieldAllowed
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
    private let editOptIn: Set<String>
    private let contextOptIn: Set<String>
    private let denied: Set<String>
    private let modesByBundleId: [String: Mode]
    private let titleModes: [(mode: Mode, regex: NSRegularExpression)]
    private let defaultMode: Mode
    private let dictionaryBlock: String?

    public init(config: Config) {
        self.config = config
        self.llmOptIn = Set(config.llmOptInBundleIds)
        self.editOptIn = Set(config.editOptInBundleIds)
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

    /// Bundle ids listed on a wider rung but missing from `llmOptInBundleIds`, which
    /// makes them inert: every rung above the first is meaningless without the
    /// rewrite pass to consume it. Silence here would look like a broken feature.
    public var inertOptIns: [String] {
        editOptIn.union(contextOptIn).subtracting(llmOptIn).sorted()
    }

    // MARK: - Policy

    public func policy(for bundleId: String?) -> Policy {
        // An app we cannot identify is treated as not opted in.
        guard let bundleId else {
            return Policy(
                denied: false, llmAllowed: false, fieldAllowed: false, contextAllowed: false)
        }
        if denied.contains(bundleId) {
            return Policy(
                denied: true, llmAllowed: false, fieldAllowed: false, contextAllowed: false)
        }
        let llm = llmOptIn.contains(bundleId)
        // Sending the whole window already includes the field inside it, so
        // context opt-in implies field opt-in.
        let context = llm && contextOptIn.contains(bundleId)
        return Policy(
            denied: false,
            llmAllowed: llm,
            fieldAllowed: llm && (context || editOptIn.contains(bundleId)),
            // Context without a rewrite pass is meaningless — nothing would consume it.
            contextAllowed: context
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

    /// System prompt = mode prompt + the static dictionary block + how to treat
    /// whatever is already in the field.
    ///
    /// The mode prompt is the user's; it owns voice and formatting. The editing
    /// block is ours and owns mechanics, so the two do not fight.
    public func systemPrompt(for mode: Mode, intent: EditIntent = .compose) -> String {
        var parts = [mode.prompt]
        if let dictionaryBlock { parts.append(dictionaryBlock) }
        parts.append(Self.editingBlock(for: intent))
        return parts.joined(separator: "\n\n")
    }

    static func editingBlock(for intent: EditIntent) -> String {
        switch intent {
        case .compose:
            return """
                <editing>
                The field is empty or its contents are unavailable. Produce the text to
                insert at the caret. Output only that text.
                </editing>
                """
        case .replaceSelection:
            return """
                <editing>
                The user has selected part of their draft, shown in <selected_text>.
                Your output will replace exactly that selection, so return the
                replacement for it and nothing else — not the whole field, and no
                commentary. If the dictation is an instruction about the selected text
                ("make this shorter", "past tense"), apply it to the selection and
                return the result. Match the surrounding punctuation and spacing so the
                replacement reads correctly in place.
                </editing>
                """
        case .revise:
            return """
                <editing>
                The field already contains a draft, shown in <current_field_content>,
                with the caret position marked. Decide what the dictation means:

                - "insert" — it is more text to add. Return only the text to insert at
                  the caret. This is the default: choose it unless the dictation is
                  clearly about the existing text.
                - "replace_all" — it is an instruction to change the draft ("make that
                  more formal", "change tomorrow to Thursday", "drop the last
                  sentence"). Return the complete new content of the field, with the
                  instruction applied and everything else left alone.

                When in doubt choose "insert": adding text is recoverable, rewriting the
                draft is disruptive. Never return an empty replacement.
                </editing>
                """
        }
    }

    /// User message = whatever the policy allows + the raw transcript.
    ///
    /// The two tiers stay separate on purpose: an app can be allowed to have its
    /// draft edited without also having the whole window's text sent.
    public func userMessage(
        transcript: String,
        context: FieldContext?,
        policy: Policy,
        intent: EditIntent = .compose
    ) -> String {
        var parts: [String] = []
        if let context {
            if policy.contextAllowed {
                if let app = context.appName { parts.append(tagged("app", app)) }
                if let title = context.windowTitle, !title.isEmpty {
                    parts.append(tagged("window", title))
                }
            }
            if policy.fieldAllowed {
                parts.append(contentsOf: fieldParts(context, intent: intent))
            }
            if policy.contextAllowed, let surrounding = context.surroundingText,
                !surrounding.isEmpty
            {
                parts.append(tagged("visible_context", surrounding, multiline: true))
            }
        }
        // The transcript is the payload, not untrusted input — it goes through
        // verbatim. Mangling angle brackets here would corrupt dictated code.
        parts.append(tagged("transcript", transcript, multiline: true, neutralize: false))
        return parts.joined(separator: "\n\n")
    }

    /// The field's own content, marked up so the model can see where the caret is
    /// and what, if anything, is selected.
    private func fieldParts(_ context: FieldContext, intent: EditIntent) -> [String] {
        var parts: [String] = []
        if intent == .replaceSelection, let selected = context.selectedText, !selected.isEmpty {
            parts.append(tagged("selected_text", selected, multiline: true))
            // The rest of the field is context for making the replacement fit.
            if let field = context.fieldValue, !field.isEmpty {
                parts.append(tagged("current_field_content", field, multiline: true))
            }
            return parts
        }
        guard let field = context.fieldValue, !field.isEmpty else { return parts }
        if let split = context.caretSplit {
            // A literal marker beats describing an offset the model has to count to.
            let marked =
                Self.neutralizeTags(in: split.before) + Self.caretMarker
                + Self.neutralizeTags(in: split.after)
            parts.append("<current_field_content>\n\(marked)\n</current_field_content>")
            parts.append(
                tagged("note", "\(Self.caretMarker) marks the caret. It is not part of the text."))
        } else {
            parts.append(tagged("current_field_content", field, multiline: true))
        }
        if context.fieldTruncated {
            parts.append(
                tagged(
                    "note",
                    "Only part of the field is shown, so it cannot be rewritten as a whole."))
        }
        return parts
    }

    /// Unlikely in dictated prose, and `neutralizeTags` leaves it alone.
    static let caretMarker = "\u{2038}"

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
