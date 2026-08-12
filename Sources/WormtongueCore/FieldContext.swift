import Foundation

/// What the probe found, with no AppKit or Accessibility types in it.
///
/// The macOS side wraps this in a `ProbeResult` that also carries the live
/// `AXUIElement`; everything downstream — mode resolution, the privacy policy,
/// prompt assembly, and the edit-intent decision — only needs this, which is what
/// makes those parts testable off a Mac.
public struct FieldContext: Sendable, Equatable {
    public var bundleId: String?
    public var appName: String?
    public var windowTitle: String?
    public var role: String?
    public var subrole: String?
    /// The focused field's current content. Nil when the app has not opted in to
    /// field access, or when there is nothing focused to read.
    public var fieldValue: String?
    /// True when `fieldValue` is only part of the field. Whole-field rewrites are
    /// refused in that case — replacing text we never saw would destroy it.
    public var fieldTruncated: Bool
    /// The user's current selection inside the field, if any.
    public var selectedText: String?
    /// Caret / selection start, as the UTF-16 offset the AX API reports.
    public var selectionLocation: Int?
    public var selectionLength: Int?
    public var surroundingText: String?
    /// Password field or similar. The utterance is discarded.
    public var isSecureField: Bool
    public var nodesVisited: Int
    /// Traversal stopped on a cap, or context was truncated to the char budget.
    public var hitLimit: Bool
    public var elapsed: TimeInterval

    public init(
        bundleId: String? = nil,
        appName: String? = nil,
        windowTitle: String? = nil,
        role: String? = nil,
        subrole: String? = nil,
        fieldValue: String? = nil,
        fieldTruncated: Bool = false,
        selectedText: String? = nil,
        selectionLocation: Int? = nil,
        selectionLength: Int? = nil,
        surroundingText: String? = nil,
        isSecureField: Bool = false,
        nodesVisited: Int = 0,
        hitLimit: Bool = false,
        elapsed: TimeInterval = 0
    ) {
        self.bundleId = bundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.role = role
        self.subrole = subrole
        self.fieldValue = fieldValue
        self.fieldTruncated = fieldTruncated
        self.selectedText = selectedText
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
        self.surroundingText = surroundingText
        self.isSecureField = isSecureField
        self.nodesVisited = nodesVisited
        self.hitLimit = hitLimit
        self.elapsed = elapsed
    }

    // MARK: - Derived state

    /// A selection we can actually describe to the model. A reported length with
    /// no text behind it is treated as no selection.
    public var hasSelection: Bool {
        guard let selectedText, !selectedText.isEmpty else { return false }
        return (selectionLength ?? selectedText.utf16.count) > 0
    }

    /// Whitespace-only counts as empty: there is nothing there to revise.
    public var fieldIsEmpty: Bool {
        guard let fieldValue else { return true }
        return fieldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The field's text either side of the caret, so the model can write something
    /// that fits where it will land rather than something bolted onto the end.
    ///
    /// Nil when the field was truncated (the offsets would not line up) or when the
    /// reported offset is not on a character boundary.
    public var caretSplit: (before: String, after: String)? {
        guard !fieldTruncated, let fieldValue, let location = selectionLocation else { return nil }
        let utf16 = fieldValue.utf16
        let clamped = min(max(0, location), utf16.count)
        guard
            let offset = utf16.index(
                utf16.startIndex, offsetBy: clamped, limitedBy: utf16.endIndex),
            let index = String.Index(offset, within: fieldValue)
        else { return nil }
        return (String(fieldValue[..<index]), String(fieldValue[index...]))
    }

    public var debugSummary: String {
        var lines = [
            "app=\(appName ?? "?") (\(bundleId ?? "?"))",
            "window=\(windowTitle ?? "-")",
            "role=\(role ?? "-") subrole=\(subrole ?? "-") secure=\(isSecureField)",
            "field=\(fieldValue?.count ?? 0) chars\(fieldTruncated ? " (truncated)" : "")",
        ]
        if hasSelection {
            lines.append(
                "selection=\(selectedText?.count ?? 0) chars at \(selectionLocation.map(String.init) ?? "?")"
            )
        } else {
            lines.append("caret=\(selectionLocation.map(String.init) ?? "?") (no selection)")
        }
        lines.append("surrounding=\(surroundingText?.count ?? 0) chars")
        lines.append(
            "\(nodesVisited) nodes in \(Int((elapsed * 1000).rounded()))ms\(hitLimit ? " (hit a limit)" : "")"
        )
        return lines.joined(separator: "\n")
    }
}
