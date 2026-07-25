import Foundation

/// What the probe found, with no AppKit or Accessibility types in it.
///
/// The macOS side wraps this in a `ProbeResult` that also carries the live
/// `AXUIElement`; everything downstream — mode resolution, the privacy policy,
/// prompt assembly — only needs this, which is what makes those parts testable
/// off a Mac.
public struct FieldContext: Sendable, Equatable {
    public var bundleId: String?
    public var appName: String?
    public var windowTitle: String?
    public var role: String?
    public var subrole: String?
    public var fieldValue: String?
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
        self.surroundingText = surroundingText
        self.isSecureField = isSecureField
        self.nodesVisited = nodesVisited
        self.hitLimit = hitLimit
        self.elapsed = elapsed
    }

    public var debugSummary: String {
        """
        app=\(appName ?? "?") (\(bundleId ?? "?"))
        window=\(windowTitle ?? "-")
        role=\(role ?? "-") subrole=\(subrole ?? "-") secure=\(isSecureField)
        field=\(fieldValue?.count ?? 0) chars
        surrounding=\(surroundingText?.count ?? 0) chars
        \(nodesVisited) nodes in \(Int((elapsed * 1000).rounded()))ms\(hitLimit ? " (hit a limit)" : "")
        """
    }
}
