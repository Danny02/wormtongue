import Foundation

/// The one place the seam turns a structured "rewrite decision" into an
/// `EditDecision`.
///
/// Every structured-output transport (Anthropic `output_config`, the OpenAI-
/// compatible `chat/completions` JSON mode) ends up with a JSON *string* for the
/// revise decision. This is the single parser both share, so behaviour cannot
/// drift between providers. Anything we cannot read as a decision degrades to a
/// verbatim insert — a malformed reply must never mean "replace the draft".
public enum EditDecisionJSON {
    private struct RawDecision: Decodable {
        let action: String
        let text: String
    }

    public static func parse(decision text: String) -> EditDecision {
        let candidate = stripCodeFence(text)
        guard
            let data = candidate.data(using: .utf8),
            let raw = try? JSONDecoder().decode(RawDecision.self, from: data)
        else {
            return EditDecision(action: .insert, text: text)
        }

        let body = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return EditDecision(action: .insert, text: text) }

        // Only the two the model is allowed to pick; anything else is a mistake on
        // its part and falls back to the non-destructive action.
        guard let action = InsertionAction(rawValue: raw.action),
            InsertionAction.modelChoosable.contains(action)
        else {
            return EditDecision(action: .insert, text: body)
        }
        return EditDecision(action: action, text: body)
    }

    /// Structured outputs should not fence the JSON, but models sometimes do.
    static func stripCodeFence(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```")
        else { return text }
        lines.removeFirst()
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}
