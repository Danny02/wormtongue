import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum InsertionMethod: String {
    case axSelectedText = "AX"
    case axValue = "AX-value"
    case paste = "paste"
    case selectAllPaste = "select-all+paste"
    case aborted = "aborted"
    case notPermitted = "no-accessibility"

    /// Nothing reached the field, so the pipeline must not report success.
    var failed: Bool { self == .aborted || self == .notPermitted }
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
    /// The user's pasteboard as it was before *our first* paste of a sequence.
    /// Two pastes in quick succession — raw-first then the replacement — used to
    /// leave it clobbered: the second paste bumped the change count, the first
    /// restore saw the mismatch and bailed, and nothing ever put it back.
    private var savedPasteboard: [[NSPasteboard.PasteboardType: Data]]?
    private var restoreTask: Task<Void, Never>?

    /// Both paths out of here need Accessibility: the AX write obviously, and the
    /// paste because `CGEvent.post` is dropped silently for an untrusted process.
    /// Without this check a stale grant — which every ad-hoc rebuild can cause —
    /// looks like a successful dictation that inserts nothing.
    private var canReachTheField: Bool { AXIsProcessTrusted() }

    func insert(_ text: String, into element: AXUIElement?) -> InsertionMethod {
        guard !text.isEmpty else { return .aborted }
        guard canReachTheField else { return .notPermitted }
        // Re-check: a password field may have taken focus while we were working.
        if Permissions.secureInputEnabled {
            log.notice("insertion aborted: secure input is enabled")
            return .aborted
        }

        if let element, tryAX(text, element) { return .axSelectedText }
        paste(text)
        return .paste
    }

    /// Replaces the field's entire contents.
    ///
    /// Only reached when the model decided the dictation was an instruction about
    /// the existing draft. Three ways down, cheapest and safest first:
    ///   1. Set `kAXValueAttribute`. For whole-field replacement, clobbering the
    ///      value is exactly what we want, so the usual objection to it does not
    ///      apply — but it is verified by reading back, because Electron and web
    ///      views accept the write and ignore it.
    ///   2. Select the whole range via AX, then write the selection.
    ///   3. ⌘A then paste. Works nearly everywhere; the risk is an app where ⌘A
    ///      is not "select all in this field".
    func replaceAll(with text: String, in element: AXUIElement?) -> InsertionMethod {
        guard !text.isEmpty else { return .aborted }
        guard canReachTheField else { return .notPermitted }
        if Permissions.secureInputEnabled {
            log.notice("whole-field replacement aborted: secure input is enabled")
            return .aborted
        }

        if let element {
            let valueAttribute = kAXValueAttribute as String
            if AX.isSettable(element, valueAttribute),
                AX.set(element, valueAttribute, text as CFString),
                AX.string(element, valueAttribute) == text
            {
                return .axValue
            }
            // Select everything, then replace the selection.
            if let current = AX.string(element, valueAttribute),
                let whole = AX.makeRange(location: 0, length: current.utf16.count),
                AX.isSettable(element, kAXSelectedTextRangeAttribute as String),
                AX.set(element, kAXSelectedTextRangeAttribute as String, whole),
                tryAX(text, element)
            {
                return .axSelectedText
            }
        }

        tap(keyCode: CGKeyCode(kVK_ANSI_A), flags: .maskCommand)
        paste(text)
        return .selectAllPaste
    }

    /// Replaces `characterCount` characters before the caret with `text`.
    /// Used only by the raw-first path; backspace-based and therefore fragile.
    func replaceTrailing(
        characterCount: Int, with text: String, into element: AXUIElement?
    ) -> InsertionMethod {
        guard characterCount > 0 else { return insert(text, into: element) }
        if Permissions.secureInputEnabled { return .aborted }
        guard canReachTheField else { return .notPermitted }
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
        // A restore already pending means this is the second paste of a sequence;
        // keep the *original* snapshot rather than saving our own text over it.
        restoreTask?.cancel()
        if savedPasteboard == nil { savedPasteboard = snapshot(pasteboard) }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        tap(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)

        // Give the target app time to read the pasteboard before we put it back.
        restoreTask = Task { [pasteboardRestoreDelay] in
            try? await Task.sleep(for: .seconds(pasteboardRestoreDelay))
            guard !Task.isCancelled else { return }
            defer {
                savedPasteboard = nil
                restoreTask = nil
            }
            // Someone else wrote to the pasteboard after us: theirs wins.
            guard pasteboard.changeCount == ourChangeCount else { return }
            guard let saved = savedPasteboard else { return }
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
