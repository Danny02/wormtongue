import Foundation
import Testing

@testable import WormtongueCore

@Suite("Caret and selection reading")
struct FieldContextTests {

    @Test("An empty or whitespace-only field counts as nothing to revise")
    func emptyField() {
        #expect(FieldContext().fieldIsEmpty)
        #expect(FieldContext(fieldValue: "").fieldIsEmpty)
        #expect(FieldContext(fieldValue: "  \n ").fieldIsEmpty)
        #expect(!FieldContext(fieldValue: "hi").fieldIsEmpty)
    }

    @Test("A reported length with no text behind it is not a selection")
    func selectionNeedsText() {
        #expect(!FieldContext(selectionLength: 5).hasSelection)
        #expect(!FieldContext(selectedText: "", selectionLength: 5).hasSelection)
        #expect(FieldContext(selectedText: "abc", selectionLength: 3).hasSelection)
        // Length missing but text present: trust the text.
        #expect(FieldContext(selectedText: "abc").hasSelection)
    }

    @Test("The field splits at the caret")
    func caretSplit() throws {
        let context = FieldContext(fieldValue: "Hello world", selectionLocation: 5)
        let split = try #require(context.caretSplit)
        #expect(split.before == "Hello")
        #expect(split.after == " world")
    }

    @Test("Caret at either end splits cleanly")
    func caretAtEnds() throws {
        let start = try #require(FieldContext(fieldValue: "abc", selectionLocation: 0).caretSplit)
        #expect(start.before.isEmpty)
        #expect(start.after == "abc")

        let end = try #require(FieldContext(fieldValue: "abc", selectionLocation: 3).caretSplit)
        #expect(end.before == "abc")
        #expect(end.after.isEmpty)
    }

    @Test("An out-of-range offset is clamped, not trapped")
    func caretOutOfRange() throws {
        let past = try #require(FieldContext(fieldValue: "abc", selectionLocation: 999).caretSplit)
        #expect(past.before == "abc")
        let negative = try #require(
            FieldContext(fieldValue: "abc", selectionLocation: -5).caretSplit)
        #expect(negative.before.isEmpty)
    }

    @Test("Offsets are UTF-16, as the Accessibility API reports them")
    func utf16Offsets() throws {
        // "🎉" is one Character but two UTF-16 units.
        let context = FieldContext(fieldValue: "🎉ab", selectionLocation: 2)
        let split = try #require(context.caretSplit)
        #expect(split.before == "🎉")
        #expect(split.after == "ab")
    }

    @Test("An offset inside a surrogate pair yields no split rather than mangled text")
    func caretInsideSurrogatePair() {
        #expect(FieldContext(fieldValue: "🎉ab", selectionLocation: 1).caretSplit == nil)
    }

    @Test("A truncated field has no usable caret split — the offsets would not line up")
    func truncatedFieldHasNoSplit() {
        let context = FieldContext(
            fieldValue: "tail of a longer field", fieldTruncated: true, selectionLocation: 3)
        #expect(context.caretSplit == nil)
    }

    @Test("No caret reported means no split")
    func noCaret() {
        #expect(FieldContext(fieldValue: "abc").caretSplit == nil)
    }
}

@Suite("Edit intent")
struct EditIntentResolutionTests {

    @Test("An empty field composes")
    func emptyComposes() {
        let context = FieldContext(fieldValue: "")
        #expect(EditIntent.resolve(context: context, fieldAllowed: true) == .compose)
    }

    @Test("A selection means replace it, whatever else is going on")
    func selectionWins() {
        let context = FieldContext(
            fieldValue: "the whole draft", selectedText: "whole", selectionLocation: 4,
            selectionLength: 5)
        #expect(EditIntent.resolve(context: context, fieldAllowed: true) == .replaceSelection)
    }

    @Test("A draft with no selection is ambiguous, so the model decides")
    func draftRevises() {
        let context = FieldContext(fieldValue: "an existing draft", selectionLocation: 17)
        #expect(EditIntent.resolve(context: context, fieldAllowed: true) == .revise)
        #expect(EditIntent.revise.needsDecision)
        #expect(!EditIntent.compose.needsDecision)
        #expect(!EditIntent.replaceSelection.needsDecision)
    }

    @Test("Without field access we cannot revise text we were not allowed to read")
    func noFieldAccessComposes() {
        let context = FieldContext(
            fieldValue: "an existing draft", selectedText: "existing", selectionLength: 8)
        #expect(EditIntent.resolve(context: context, fieldAllowed: false) == .compose)
    }

    @Test("A truncated field is never rewritten wholesale")
    func truncatedFieldNeverRevises() {
        let context = FieldContext(fieldValue: "…tail only", fieldTruncated: true)
        #expect(EditIntent.resolve(context: context, fieldAllowed: true) == .compose)
    }

    @Test(
        "A selection in a truncated field can still be replaced — the mechanism does not need the rest"
    )
    func truncatedFieldStillReplacesSelection() {
        let context = FieldContext(
            fieldValue: "…tail only", fieldTruncated: true, selectedText: "tail",
            selectionLength: 4)
        #expect(EditIntent.resolve(context: context, fieldAllowed: true) == .replaceSelection)
    }

    @Test("Only whole-field and selection replacement are destructive")
    func destructiveActions() {
        #expect(!InsertionAction.insert.isDestructive)
        #expect(InsertionAction.replaceAll.isDestructive)
        #expect(InsertionAction.replaceSelection.isDestructive)
    }

    @Test("The model may only pick insert or replace_all")
    func modelChoosable() {
        #expect(InsertionAction.modelChoosable == [.insert, .replaceAll])
        #expect(InsertionAction.replaceAll.rawValue == "replace_all")
    }
}

@Suite("Edit decision parsing")
struct EditDecisionTests {

    @Test("A well-formed decision is used as given")
    func wellFormed() {
        let decision = AnthropicMessages.parse(
            decision: #"{"action": "replace_all", "text": "The revised draft."}"#)
        #expect(decision.action == .replaceAll)
        #expect(decision.text == "The revised draft.")
    }

    @Test("An insert decision is used as given")
    func insertDecision() {
        let decision = AnthropicMessages.parse(
            decision: #"{"action": "insert", "text": "and another thing"}"#)
        #expect(decision.action == .insert)
        #expect(decision.text == "and another thing")
    }

    @Test("Fenced JSON is still understood")
    func fencedJSON() {
        let fenced = """
            ```json
            {"action": "replace_all", "text": "Revised."}
            ```
            """
        let decision = AnthropicMessages.parse(decision: fenced)
        #expect(decision.action == .replaceAll)
        #expect(decision.text == "Revised.")
    }

    @Test("Plain prose degrades to inserting it — never to replacing the draft")
    func proseFallsBackToInsert() {
        let decision = AnthropicMessages.parse(decision: "Sure, here is the text you asked for.")
        #expect(decision.action == .insert)
        #expect(decision.text == "Sure, here is the text you asked for.")
    }

    @Test("An unknown or non-choosable action falls back to insert")
    func unknownAction() {
        #expect(
            AnthropicMessages.parse(decision: #"{"action": "delete_everything", "text": "x"}"#)
                .action == .insert)
        // replace_selection is ours to decide, not the model's to ask for.
        #expect(
            AnthropicMessages.parse(decision: #"{"action": "replace_selection", "text": "x"}"#)
                .action == .insert)
    }

    @Test("An empty replacement is refused — it would wipe the field")
    func emptyReplacementRefused() {
        let decision = AnthropicMessages.parse(
            decision: #"{"action": "replace_all", "text": "   "}"#)
        #expect(decision.action == .insert)
    }

    @Test("Whitespace around the decision text is trimmed")
    func trimsText() {
        let decision = AnthropicMessages.parse(
            decision: #"{"action": "insert", "text": "\n  hello \n"}"#)
        #expect(decision.text == "hello")
    }

    @Test("A decision comes back through the full HTTP path")
    func throughHTTPPath() throws {
        let body = Data(
            #"{"content":[{"type":"text","text":"{\"action\":\"replace_all\",\"text\":\"Done.\"}"}]}"#
                .utf8)
        let decision = try AnthropicMessages.decision(fromStatus: 200, body: body)
        #expect(decision.action == .replaceAll)
        #expect(decision.text == "Done.")
    }

    @Test("HTTP and refusal errors still surface on the decision path")
    func errorsPropagate() {
        #expect(throws: AnthropicError.self) {
            try AnthropicMessages.decision(fromStatus: 500, body: Data())
        }
        #expect(throws: AnthropicError.refused(category: nil)) {
            try AnthropicMessages.decision(
                fromStatus: 200, body: Data(#"{"content":[],"stop_reason":"refusal"}"#.utf8))
        }
    }
}

@Suite("Structured output request")
struct StructuredRequestTests {

    private func json(_ request: AnthropicMessages.Request) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any] ?? [:]
    }

    @Test("output_config is absent unless a decision is needed")
    func absentByDefault() throws {
        let plain = AnthropicMessages.Request(model: "m", system: "s", user: "u", maxTokens: 10)
        #expect(try json(plain)["output_config"] == nil)
    }

    @Test("The schema is the shape structured outputs require")
    func schemaShape() throws {
        let request = AnthropicMessages.Request(
            model: "m", system: "s", user: "u", maxTokens: 10, structured: true)
        let body = try json(request)

        let format = try #require(
            (body["output_config"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")

        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["required"] as? [String] == ["action", "text"])
        // Structured outputs reject a schema without this, and the key must stay
        // camelCase — a snake_case encoding strategy would break it.
        #expect(schema["additionalProperties"] as? Bool == false)

        let properties = try #require(schema["properties"] as? [String: Any])
        let action = try #require(properties["action"] as? [String: Any])
        #expect(action["enum"] as? [String] == ["insert", "replace_all"])
        #expect((properties["text"] as? [String: Any])?["type"] as? String == "string")
    }

    @Test("max_tokens stays snake_case now that keys are spelled out by hand")
    func snakeCaseKeysPreserved() throws {
        let request = AnthropicMessages.Request(
            model: "m", system: "s", user: "u", maxTokens: 77, structured: true)
        #expect(try json(request)["max_tokens"] as? Int == 77)
    }
}
