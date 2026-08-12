import AppKit
import ApplicationServices
import WormtongueCore

/// The platform-free `FieldContext` plus the live element, so the inserter can
/// reuse it instead of re-walking the tree.
struct ProbeResult: @unchecked Sendable {
    var context: FieldContext
    var focusedElement: AXUIElement?
}

/// Reads the focused app's AX tree off the main thread, under hard caps.
///
/// Node/depth caps and the deadline are all load-bearing: the AX tree of an
/// Electron app is huge and every hop is IPC. Never block the recording path on
/// this — `AppState` starts the probe on key-*down* so it overlaps the recording
/// instead of sitting in the post-release critical path.
final class ContextProbe {
    /// Starting guesses. M2's job is to tune these against real Slack/VS Code —
    /// the brief's 500/8 is likely too shallow to reach Chromium message content.
    private let maxNodes = 800
    private let maxDepth = 12
    private let budget = Duration.milliseconds(700)
    private let axMessagingTimeout: Float = 0.25

    private let queue = DispatchQueue(
        label: "com.wormtongue.wormtongue.axprobe", qos: .userInitiated)

    /// Bridged once, not per node — `[String] as CFArray` allocates.
    private let nodeAttributes: CFArray =
        [kAXRoleAttribute as String, kAXValueAttribute as String] as CFArray
    private let focusAttributes: CFArray =
        [
            kAXRoleAttribute as String, kAXSubroleAttribute as String, kAXValueAttribute as String,
            kAXSelectedTextAttribute as String,
        ] as CFArray

    /// Roles whose subtrees cannot contain readable conversation text. Skipping
    /// them is the cheapest way to spend the node budget on text instead of chrome.
    private let opaqueRoles: Set<String> = [
        kAXMenuBarRole as String,
        kAXMenuBarItemRole as String,
        kAXMenuRole as String,
        kAXImageRole as String,
        kAXScrollBarRole as String,
        kAXSplitterRole as String,
        kAXProgressIndicatorRole as String,
        kAXBusyIndicatorRole as String,
        kAXSliderRole as String,
        kAXToolbarRole as String,
    ]

    private let textRoles: Set<String> = [
        kAXStaticTextRole as String,
        kAXTextAreaRole as String,
        kAXTextFieldRole as String,
    ]

    struct Target: Sendable {
        var pid: pid_t
        var bundleId: String?
        var appName: String?
    }

    /// The frontmost app, captured on the main actor before we go off-thread.
    @MainActor
    static func frontmostTarget() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return Target(
            pid: app.processIdentifier,
            bundleId: app.bundleIdentifier,
            appName: app.localizedName)
    }

    func probe(_ target: Target, contextCharCap: Int, fieldCharCap: Int) async -> ProbeResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: self.probeSync(
                        target, contextCharCap: contextCharCap, fieldCharCap: fieldCharCap))
            }
        }
    }

    private func probeSync(_ target: Target, contextCharCap: Int, fieldCharCap: Int) -> ProbeResult
    {
        let started = ContinuousClock.now
        let deadline = started.advanced(by: budget)
        var context = FieldContext(bundleId: target.bundleId, appName: target.appName)

        let app = AXUIElementCreateApplication(target.pid)
        AX.setMessagingTimeout(app, seconds: axMessagingTimeout)

        guard let focused = AX.element(app, kAXFocusedUIElementAttribute as String) else {
            context.elapsed = started.duration(to: .now).seconds
            log.debug("probe: no focused element for pid \(target.pid)")
            return ProbeResult(context: context, focusedElement: nil)
        }

        // One round trip for role + subrole + value + selected text. The API
        // documents a parallel array, but a short one would be an out-of-bounds
        // crash in the hot path.
        var fieldValue: String?
        if let values = AX.values(focused, focusAttributes), values.count == 4 {
            context.role = values[0] as? String
            context.subrole = values[1] as? String
            fieldValue = values[2] as? String
            context.selectedText = values[3] as? String
        }
        context.isSecureField = context.subrole == (kAXSecureTextFieldSubrole as String)

        if context.isSecureField {
            // Nothing else gets read, nothing gets sent.
            context.selectedText = nil
            context.elapsed = started.duration(to: .now).seconds
            return ProbeResult(context: context, focusedElement: focused)
        }

        // Where the caret is, or what is selected. This is what tells us whether the
        // dictation is meant to add text or change text that is already there.
        if let range = AX.range(focused, kAXSelectedTextRangeAttribute as String) {
            context.selectionLocation = range.location
            context.selectionLength = range.length
        }

        // A field can be an entire source file. Send the tail, and record that we
        // only saw part of it so nothing downstream tries to rewrite the whole thing.
        if let fieldValue {
            if fieldValue.count > fieldCharCap {
                context.fieldValue = String(fieldValue.suffix(fieldCharCap))
                context.fieldTruncated = true
            } else {
                context.fieldValue = fieldValue
            }
        }
        if let selected = context.selectedText, selected.count > fieldCharCap {
            context.selectedText = String(selected.prefix(fieldCharCap))
        }

        // Walk up to the window for its title (the Slack channel name, etc.).
        var window: AXUIElement?
        var cursor: AXUIElement? = focused
        for _ in 0..<maxDepth {
            guard let current = cursor else { break }
            if AX.string(current, kAXRoleAttribute as String) == (kAXWindowRole as String) {
                window = current
                break
            }
            cursor = AX.element(current, kAXParentAttribute as String)
        }
        if window == nil {
            window = AX.element(app, kAXFocusedWindowAttribute as String)
        }
        context.windowTitle = window.flatMap { AX.string($0, kAXTitleAttribute as String) }

        // Walk down from the window collecting visible static text — this is how
        // we get the surrounding conversation.
        guard let window else {
            context.elapsed = started.duration(to: .now).seconds
            return ProbeResult(context: context, focusedElement: focused)
        }

        // Keeps only the last `charCap` characters as it goes, so a busy channel
        // does not materialise its whole scrollback before we discard most of it.
        var tail = TailBuffer(capacity: contextCharCap)
        var visited = 0
        var stoppedEarly = false
        collect(
            from: window, depth: 0, deadline: deadline,
            visited: &visited, stoppedEarly: &stoppedEarly, into: &tail)

        context.nodesVisited = visited
        context.hitLimit = stoppedEarly || tail.didTruncate
        let joined = tail.joined()
        context.surroundingText = joined.isEmpty ? nil : joined
        context.elapsed = started.duration(to: .now).seconds
        return ProbeResult(context: context, focusedElement: focused)
    }

    private func collect(
        from element: AXUIElement,
        depth: Int,
        deadline: ContinuousClock.Instant,
        visited: inout Int,
        stoppedEarly: inout Bool,
        into tail: inout TailBuffer
    ) {
        if depth > maxDepth || visited >= maxNodes || ContinuousClock.now >= deadline {
            stoppedEarly = true
            return
        }
        visited += 1

        var role: String?
        if let values = AX.values(element, nodeAttributes), values.count == 2 {
            role = values[0] as? String
            if let role, textRoles.contains(role), let text = values[1] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { tail.append(trimmed) }
            }
        }
        // Chrome, not content — do not spend the node budget below here.
        if let role, opaqueRoles.contains(role) { return }

        for child in AX.elements(element, kAXChildrenAttribute as String) {
            if visited >= maxNodes || ContinuousClock.now >= deadline {
                stoppedEarly = true
                return
            }
            collect(
                from: child, depth: depth + 1, deadline: deadline,
                visited: &visited, stoppedEarly: &stoppedEarly, into: &tail)
        }
    }
}
