import Foundation

/// Where the Messages API lives.
///
/// Overridable so the app can be pointed at a gateway, a company proxy, a local
/// mock, or anything else that speaks the same wire format — the request and
/// response shapes are unchanged, only the host is.
public struct APIEndpoint: Sendable, Equatable {
    public let base: URL
    public let messages: URL
    public let models: URL

    public static let anthropic = APIEndpoint(base: URL(string: "https://api.anthropic.com")!)

    public init(base: URL) {
        self.base = base
        self.messages = base.appending(path: "v1/messages")
        self.models = base.appending(path: "v1/models")
    }

    /// Parses a configured base URL. Returns nil rather than throwing so the caller
    /// can fall back to the default and report the problem, instead of the app
    /// failing to start over a typo.
    ///
    /// A path on the base is preserved — `https://gw.example.com/anthropic` yields
    /// `https://gw.example.com/anthropic/v1/messages` — which is what gateways
    /// that mount the API under a prefix need.
    public init?(base string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Trailing slashes would produce a double slash once a path is appended.
        var cleaned = trimmed
        while cleaned.hasSuffix("/") { cleaned.removeLast() }
        guard !cleaned.isEmpty, let url = URL(string: cleaned) else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return nil
        }
        guard url.host?.isEmpty == false else { return nil }
        self.init(base: url)
    }

    /// True when requests leave the machine. `http://localhost` is the usual local
    /// mock, and worth *not* warning about.
    public var isLoopback: Bool {
        guard let host = base.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /// Anything other than Anthropic's own host is worth saying out loud, since it
    /// means the transcript is going somewhere the user configured by hand.
    public var isDefault: Bool { self == .anthropic }
}
