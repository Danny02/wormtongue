import Foundation
import os

let log = Logger(subsystem: "com.wormtongue.voicemode", category: "pipeline")

/// Latency instrumentation. Required from M1 onward: the whole premise dies if
/// key-release to inserted-text creeps past ~1.5s.
struct Stopwatch {
    private let start = Date()
    private var last = Date()
    private(set) var stages: [(name: String, seconds: TimeInterval)] = []

    mutating func lap(_ name: String) {
        let now = Date()
        stages.append((name, now.timeIntervalSince(last)))
        last = now
    }

    var total: TimeInterval { Date().timeIntervalSince(start) }

    var summary: String {
        let parts = stages.map { "\($0.name) \(Int($0.seconds * 1000))ms" }
        return (parts + ["total \(Int(total * 1000))ms"]).joined(separator: " · ")
    }
}
