import Foundation

/// Latency instrumentation. Required from M1 onward: the whole premise dies if
/// key-release to inserted-text creeps past ~1.5s.
///
/// Uses `ContinuousClock`, not `Date` — monotonic, so a clock adjustment mid
/// dictation cannot produce a negative stage duration.
public struct Stopwatch: Sendable {
    private let start = ContinuousClock.now
    private var last = ContinuousClock.now
    public private(set) var stages: [(name: String, seconds: TimeInterval)] = []

    public init() {}

    public mutating func lap(_ name: String) {
        let now = ContinuousClock.now
        stages.append((name, last.duration(to: now).seconds))
        last = now
    }

    /// Records a stage that ran concurrently with another, so its cost is visible
    /// without being double-counted against the total.
    public mutating func note(_ name: String, seconds: TimeInterval) {
        stages.append((name, seconds))
    }

    public var total: TimeInterval { start.duration(to: .now).seconds }

    public var summary: String {
        let parts = stages.map { "\($0.name) \(Int(($0.seconds * 1000).rounded()))ms" }
        return (parts + ["total \(Int((total * 1000).rounded()))ms"]).joined(separator: " · ")
    }
}

extension Duration {
    /// `Duration` exposes only (seconds, attoseconds) components.
    public var seconds: TimeInterval {
        let (secs, attos) = components
        return TimeInterval(secs) + TimeInterval(attos) / 1e18
    }
}
