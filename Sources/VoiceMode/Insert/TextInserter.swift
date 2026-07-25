import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum InsertionMethod: String {
    case axSelectedText = "AX"
    case paste = "paste"
    case aborted = "aborted"
}

/// Puts text into the focused field.
///
/// Tries `kAXSelectedTextAttribute` first — it inserts at the caret cleanly on
/// native apps. Electron and most web views either silently ignore it or clobber
/// the field, so the fallback is pasteboard + synthetic ⌘V with the pasteboard
/// restored afterwards.
@MainActor
final class TextInserter {
    private let pasteboardRestoreDelay: TimeInterval = 0.35

    func insert(_ text: String, into element: AXUIElement?) -> InsertionMethod {
        guard !text.isEmpty else { return .aborted }
        // Re-check: a password field may have taken focus while we were working.
        if Permissions.secureInputEnabled {
            log.notice("insertion aborted: secure input is enabled")
            return .aborted
        }

        if let element, tryAX(text, element) { return .axSelectedText }
        paste(text)
        return .paste
    }

    /// Replaces `characterCount` characters before the caret with `text`.
    /// Used only by the raw-first path; backspace-based and therefore fragile.
    func replaceTrailing(
        characterCount: Int, with text: String, into element: AXUIElement?
    ) -> InsertionMethod {
        guard characterCount > 0 else { return insert(text, into: element) }
        if Permissions.secureInputEnabled { return .aborted }
        for _ in 0..<characterCount {
            tap(keyCode: CGKeyCode(kVK_Delete), flags: [])
        }
        return insert(text, into: element)
    }

    // MARK: - AX path

    private func tryAX(_ text: String, _ element: AXUIElement) -> Bool {
        let attribute = kAXSelectedTextAttribute as String
        guard AX.isSettable(element, attribute) else { return false }
        guard AX.set(element, attribute, text as CFString) else { return false }
        // Read back: some apps report the attribute settable and then no-op.
        if let value = AX.string(element, kAXValueAttribute as String), !value.contains(text) {
            log.debug(
                "AX insertion reported success but value does not contain the text; falling back to paste"
            )
            return false
        }
        return true
    }

    // MARK: - Paste path

    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        tap(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)

        // Give the target app time to read the pasteboard before we put it back.
        Task { [pasteboardRestoreDelay] in
            try? await Task.sleep(for: .seconds(pasteboardRestoreDelay))
            // If something else wrote to the pasteboard in the meantime, leave it alone.
            guard pasteboard.changeCount == ourChangeCount else { return }
            restore(saved, to: pasteboard)
        }
    }

    private func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var payload: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { payload[type] = data }
            }
            return payload
        }
    }

    private func restore(
        _ snapshot: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        let items = snapshot.compactMap { payload -> NSPasteboardItem? in
            guard !payload.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in payload { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    // MARK: - Synthetic keystrokes

    private func tap(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }
}
