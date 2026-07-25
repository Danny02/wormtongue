import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let dictate = Self("dictate")
}

enum Hotkey {
    /// Push-to-talk hold on ⌘⌥D unless the user has recorded something else.
    /// (Assumption from §8 of the brief: hold, not toggle.)
    @MainActor
    static func installDefaultIfUnset() {
        guard KeyboardShortcuts.getShortcut(for: .dictate) == nil else { return }
        KeyboardShortcuts.setShortcut(.init(.d, modifiers: [.command, .option]), for: .dictate)
    }
}
