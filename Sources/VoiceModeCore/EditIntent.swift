import Foundation

/// What a dictation is *for*, given the state of the field it lands in.
///
/// Appending at the caret is only right when the field is empty. Once there is a
/// draft, the same utterance can mean two different things — "and another thing…"
/// versus "make that less blunt" — and once text is selected it almost always
/// means "replace this".
public enum EditIntent: String, Sendable, Equatable {
    /// Nothing there yet. Produce text; it goes in at the caret.
    case compose
    /// The user selected part of the draft. Our output replaces exactly that.
    /// Deterministic — no need to ask the model what to do.
    case replaceSelection
    /// There is a draft and no selection. Genuinely ambiguous, so the model
    /// decides between adding to it and rewriting it.
    case revise

    /// True when the model is asked for a structured decision rather than plain text.
    public var needsDecision: Bool { self == .revise }
}

/// What to do with the model's output.
public enum InsertionAction: String, Sendable, Equatable, Codable {
    case insert
    case replaceAll = "replace_all"
    case replaceSelection = "replace_selection"

    /// Destructive actions overwrite text the user already had, so they are the
    /// ones that need a captured previous value to revert to.
    public var isDestructive: Bool { self != .insert }

    /// The only two the model is allowed to pick. `replaceSelection` is decided by
    /// the presence of a selection, not by the model.
    public static let modelChoosable: [InsertionAction] = [.insert, .replaceAll]
}

extension EditIntent {
    /// Shown in the overlay while the request is in flight.
    public var label: String {
        switch self {
        case .compose: return "composing"
        case .replaceSelection: return "replacing selection"
        case .revise: return "revising draft"
        }
    }
}

extension InsertionAction {
    /// Shown in the menu and history, where the user needs to know whether
    /// something was overwritten.
    public var label: String {
        switch self {
        case .insert: return "inserted"
        case .replaceAll: return "rewrote field"
        case .replaceSelection: return "replaced selection"
        }
    }
}

public struct EditDecision: Sendable, Equatable {
    public let action: InsertionAction
    public let text: String

    public init(action: InsertionAction, text: String) {
        self.action = action
        self.text = text
    }
}

extension EditIntent {
    /// Picks the intent from the field state.
    ///
    /// Two hard rules, both about not destroying text:
    ///   - Without field access we cannot see the draft, so we can only compose.
    ///   - A truncated field must never be rewritten wholesale: we would be
    ///     replacing content we never read.
    public static func resolve(context: FieldContext, fieldAllowed: Bool) -> EditIntent {
        guard fieldAllowed else { return .compose }
        if context.hasSelection { return .replaceSelection }
        if context.fieldTruncated { return .compose }
        if !context.fieldIsEmpty { return .revise }
        return .compose
    }
}
