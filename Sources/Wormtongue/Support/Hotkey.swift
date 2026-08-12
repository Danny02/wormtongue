import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let dictate = Self("dictate")
}

enum Hotkey {
    /// Push-to-talk hold on ⌃⌥Space unless the user has recorded something else.
    /// Control-based so an uncaptured press types nothing; the previous default
    /// ⌘⌥D collides with the macOS Dock toggle, so a stored ⌘⌥D is migrated.
    @MainActor
    static func installDefaultIfUnset() {
        let oldDefault = KeyboardShortcuts.Shortcut(.d, modifiers: [.command, .option])
        let current = KeyboardShortcuts.getShortcut(for: .dictate)
        guard current == nil || current == oldDefault else { return }
        KeyboardShortcuts.setShortcut(.init(.space, modifiers: [.control, .option]), for: .dictate)
    }
}
