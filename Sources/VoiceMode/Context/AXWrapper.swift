import ApplicationServices

/// Thin Swift veneer over the AXUIElement C API. Every accessor returns nil on
/// failure rather than surfacing an AXError — at the traversal level a missing
/// attribute and a failed IPC are the same thing: skip the node.
enum AX {
    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        copyAttribute(element, attribute) as? [AXUIElement] ?? []
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    /// Electron AX trees are large and every hop is IPC. Without this, one
    /// unresponsive app hangs the traversal.
    static func setMessagingTimeout(_ element: AXUIElement, seconds: Float) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }
}
