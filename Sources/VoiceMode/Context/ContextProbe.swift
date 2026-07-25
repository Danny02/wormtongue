import AppKit
import ApplicationServices

/// Everything we learned about where the caret is. Carries the focused element so
/// the inserter can reuse it instead of re-walking the tree.
struct ProbeResult: @unchecked Sendable {
    var bundleId: String?
    var appName: String?
    var pid: pid_t
    var windowTitle: String?
    var role: String?
    var subrole: String?
    var fieldValue: String?
    var surroundingText: String?
    /// Password field or similar. Abort silently.
    var isSecureField: Bool = false
    var nodesVisited: Int = 0
    var hitLimit: Bool = false
    var focusedElement: AXUIElement?

    var debugSummary: String {
        """
        app=\(appName ?? "?") (\(bundleId ?? "?"))
        window=\(windowTitle ?? "-")
        role=\(role ?? "-") subrole=\(subrole ?? "-") secure=\(isSecureField)
        field=\(fieldValue?.count ?? 0) chars
        surrounding=\(surroundingText?.count ?? 0) chars (\(nodesVisited) nodes\(hitLimit ? ", hit limit" : ""))
        """
    }
}

/// Reads the focused app's AX tree off the main thread, under hard caps.
///
/// Node/depth caps and the wall-clock deadline are all load-bearing: the AX tree
/// of an Electron app is huge and every hop is IPC. Never block the recording
/// path on this.
final class ContextProbe {
    /// Starting guesses. M2's job is to tune these against real Slack/VS Code —
    /// the brief's 500/8 is likely too shallow to reach Chromium message content.
    private let maxNodes = 800
    private let maxDepth = 12
    private let deadlineSeconds: TimeInterval = 0.7
    private let axMessagingTimeout: Float = 0.25

    private let queue = DispatchQueue(label: "com.wormtongue.voicemode.axprobe", qos: .userInitiated)

    struct Target: Sendable {
        var pid: pid_t
        var bundleId: String?
        var appName: String?
    }

    /// The frontmost app, captured on the main actor before we go off-thread.
    @MainActor
    static func frontmostTarget() -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return Target(pid: app.processIdentifier,
                      bundleId: app.bundleIdentifier,
                      appName: app.localizedName)
    }

    func probe(_ target: Target, charCap: Int) async -> ProbeResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.probeSync(target, charCap: charCap))
            }
        }
    }

    private func probeSync(_ target: Target, charCap: Int) -> ProbeResult {
        var result = ProbeResult(bundleId: target.bundleId, appName: target.appName, pid: target.pid)
        let deadline = Date().addingTimeInterval(deadlineSeconds)

        let app = AXUIElementCreateApplication(target.pid)
        AX.setMessagingTimeout(app, seconds: axMessagingTimeout)

        guard let focused = AX.element(app, kAXFocusedUIElementAttribute as String) else {
            log.debug("probe: no focused element for pid \(target.pid)")
            return result
        }
        result.focusedElement = focused
        result.role = AX.string(focused, kAXRoleAttribute as String)
        result.subrole = AX.string(focused, kAXSubroleAttribute as String)
        result.fieldValue = AX.string(focused, kAXValueAttribute as String)
        result.isSecureField = result.subrole == (kAXSecureTextFieldSubrole as String)

        if result.isSecureField {
            // Nothing else gets read, nothing gets sent.
            result.fieldValue = nil
            return result
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
        result.windowTitle = window.flatMap { AX.string($0, kAXTitleAttribute as String) }

        // Walk down from the window collecting visible static text — this is how
        // we get the surrounding conversation.
        guard let window else { return result }
        var collected: [String] = []
        var visited = 0
        var hitLimit = false
        collectText(from: window, depth: 0, deadline: deadline,
                    visited: &visited, hitLimit: &hitLimit, into: &collected)
        result.nodesVisited = visited
        result.hitLimit = hitLimit

        // Keep the TAIL: in a chat window the most recent messages are last.
        var joined = collected.joined(separator: "\n")
        if joined.count > charCap {
            joined = String(joined.suffix(charCap))
            result.hitLimit = true
        }
        result.surroundingText = joined.isEmpty ? nil : joined
        return result
    }

    private func collectText(from element: AXUIElement, depth: Int, deadline: Date,
                             visited: inout Int, hitLimit: inout Bool, into out: inout [String]) {
        if depth > maxDepth || visited >= maxNodes || Date() >= deadline {
            hitLimit = true
            return
        }
        visited += 1

        let role = AX.string(element, kAXRoleAttribute as String)
        if role == (kAXStaticTextRole as String)
            || role == (kAXTextAreaRole as String)
            || role == (kAXTextFieldRole as String) {
            if let value = AX.string(element, kAXValueAttribute as String) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
            }
        }

        for child in AX.elements(element, kAXChildrenAttribute as String) {
            if visited >= maxNodes || Date() >= deadline {
                hitLimit = true
                return
            }
            collectText(from: child, depth: depth + 1, deadline: deadline,
                        visited: &visited, hitLimit: &hitLimit, into: &out)
        }
    }
}
