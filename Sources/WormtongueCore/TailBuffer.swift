import Foundation

/// Collects text while keeping only the last `capacity` characters.
///
/// The probe walks a window top to bottom, but in a chat window the messages we
/// care about are the ones at the *bottom*. The naive version — accumulate
/// everything, then `String(joined.suffix(cap))` — builds the entire visible text
/// of a Slack channel in memory before throwing most of it away. This drops from
/// the front as it goes, so peak memory is O(capacity) regardless of how much
/// text the window contains.
public struct TailBuffer {
    public let capacity: Int
    /// True if anything was dropped, i.e. the caller is seeing a truncated tail.
    public private(set) var didTruncate = false

    private var chunks: [(text: String, count: Int)] = []
    private var head = 0
    private var total = 0

    public init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    public var isEmpty: Bool { total == 0 }
    public var characterCount: Int { total }

    public mutating func append(_ text: String) {
        guard capacity > 0 else {
            if !text.isEmpty { didTruncate = true }
            return
        }
        // A single chunk bigger than the whole budget: keep only its tail and
        // discard everything before it.
        var text = text
        var count = text.count
        if count > capacity {
            text = String(text.suffix(capacity))
            count = capacity
            chunks.removeAll(keepingCapacity: true)
            head = 0
            total = 0
            didTruncate = true
        }

        chunks.append((text, count))
        total += count
        dropUntilWithinCapacity()
    }

    private mutating func dropUntilWithinCapacity() {
        while total > capacity, head < chunks.count {
            total -= chunks[head].count
            head += 1
            didTruncate = true
        }
        // Reclaim the dropped prefix occasionally rather than on every drop —
        // removeFirst is O(n) and this runs inside the AX traversal.
        if head > 64 {
            chunks.removeFirst(head)
            head = 0
        }
    }

    public func joined(separator: String = "\n") -> String {
        guard head < chunks.count else { return "" }
        var out = ""
        out.reserveCapacity(total + (chunks.count - head))
        for index in head..<chunks.count {
            if !out.isEmpty { out += separator }
            out += chunks[index].text
        }
        return out
    }
}
