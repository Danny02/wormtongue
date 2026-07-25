import ApplicationServices

/// Thin Swift veneer over the AXUIElement C API. Every accessor returns nil on
/// failure rather than surfacing an AXError — at the traversal level a missing
/// attribute and a failed IPC are the same thing: skip the node.
enum AX {
    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else {
            return nil
        }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute),
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        copyAttribute(element, attribute) as? [AXUIElement] ?? []
    }

    /// Fetches several attributes in **one** IPC round trip.
    ///
    /// This is the difference that matters in the traversal: reading role and
    /// value separately is two cross-process calls per node, and the AX tree of an
    /// Electron window is hundreds of nodes. Pass a pre-bridged `CFArray` — see
    /// `ContextProbe.nodeAttributes` — so the bridge cost isn't paid per node.
    ///
    /// The returned array is positional. Entries that failed come back as AXValue
    /// error markers, which simply fail to cast to the type you asked for.
    static func values(_ element: AXUIElement, _ attributes: CFArray) -> [CFTypeRef]? {
        var out: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(element, attributes, [], &out)
        guard err == .success, let out = out as? [CFTypeRef] else { return nil }
        return out
    }

    /// Reads a `CFRange`-typed attribute — `kAXSelectedTextRangeAttribute` is one.
    /// The value arrives boxed in an `AXValue` rather than as a plain CFType.
    static func range(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        guard let value = copyAttribute(element, attribute),
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let boxed = value as! AXValue
        guard AXValueGetType(boxed) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(boxed, .cfRange, &range) else { return nil }
        return range
    }

    static func makeRange(location: Int, length: Int) -> AXValue? {
        var range = CFRange(location: location, length: length)
        return AXValueCreate(.cfRange, &range)
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    /// Electron AX trees are large and every hop is IPC. Without this, one
    /// unresponsive app hangs the traversal until the default 6s timeout.
    static func setMessagingTimeout(_ element: AXUIElement, seconds: Float) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }
}
