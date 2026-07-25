import Foundation

/// What the privacy rules decided for one utterance.
struct Policy {
    /// Hard-denied app: raw transcript, no probe values used, nothing sent.
    var denied: Bool
    /// App opted in to the LLM rewrite pass.
    var llmAllowed: Bool
    /// App opted in to having its on-screen text sent along.
    var contextAllowed: Bool
}

struct ModeResolver {
    let config: Config

    func policy(for bundleId: String?) -> Policy {
        guard let bundleId else {
            // Unknown app: treat as not opted in.
            return Policy(denied: false, llmAllowed: false, contextAllowed: false)
        }
        if config.deniedBundleIds.contains(bundleId) {
            return Policy(denied: true, llmAllowed: false, contextAllowed: false)
        }
        return Policy(
            denied: false,
            llmAllowed: config.llmOptInBundleIds.contains(bundleId),
            contextAllowed: config.contextOptInBundleIds.contains(bundleId)
        )
    }

    /// bundle id match → window title regex → the mode named "default" → a built-in.
    func mode(bundleId: String?, windowTitle: String?) -> Mode {
        if let bundleId, let hit = config.modes.first(where: { $0.matchBundleIds.contains(bundleId) }) {
            return hit
        }
        if let windowTitle {
            for mode in config.modes {
                guard let pattern = mode.matchWindowTitleRegex else { continue }
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                    log.error("mode \(mode.name, privacy: .public): bad window title regex")
                    continue
                }
                let range = NSRange(windowTitle.startIndex..., in: windowTitle)
                if regex.firstMatch(in: windowTitle, range: range) != nil { return mode }
            }
        }
        return config.modes.first { $0.name == "default" } ?? Config.default.modes[0]
    }

    /// System prompt = mode prompt + the static dictionary block.
    func systemPrompt(for mode: Mode) -> String {
        guard !config.dictionary.isEmpty else { return mode.prompt }
        let terms = config.dictionary.joined(separator: ", ")
        return """
        \(mode.prompt)

        <dictionary>
        These terms appear in the speaker's vocabulary. Spell them exactly as
        written here when the transcript approximates them: \(terms)
        </dictionary>
        """
    }

    /// User message = context (when allowed) + the raw transcript.
    func userMessage(transcript: String, probe: ProbeResult?, contextAllowed: Bool) -> String {
        var parts: [String] = []
        if contextAllowed, let probe {
            if let app = probe.appName { parts.append("<app>\(app)</app>") }
            if let title = probe.windowTitle, !title.isEmpty {
                parts.append("<window>\(title)</window>")
            }
            if let field = probe.fieldValue, !field.isEmpty {
                parts.append("<current_field_content>\n\(field)\n</current_field_content>")
            }
            if let surrounding = probe.surroundingText, !surrounding.isEmpty {
                parts.append("<visible_context>\n\(surrounding)\n</visible_context>")
            }
        }
        parts.append("<transcript>\n\(transcript)\n</transcript>")
        return parts.joined(separator: "\n\n")
    }
}
