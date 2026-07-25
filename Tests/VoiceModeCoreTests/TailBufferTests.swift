import Foundation
import Testing

@testable import VoiceModeCore

@Suite("Context tail buffer")
struct TailBufferTests {

    @Test("Everything is kept when it fits")
    func underCapacity() {
        var buffer = TailBuffer(capacity: 100)
        buffer.append("alpha")
        buffer.append("beta")
        #expect(buffer.joined() == "alpha\nbeta")
        #expect(!buffer.didTruncate)
        #expect(buffer.characterCount == 9)
    }

    @Test("The tail is kept and the front dropped — recent messages are at the bottom")
    func keepsTail() {
        var buffer = TailBuffer(capacity: 10)
        buffer.append("aaaaa")  // 5
        buffer.append("bbbbb")  // 10, still fits
        buffer.append("ccccc")  // 15, must drop "aaaaa"

        #expect(buffer.didTruncate)
        #expect(buffer.joined() == "bbbbb\nccccc")
        #expect(!buffer.joined().contains("aaaaa"))
    }

    @Test("A single chunk larger than the budget keeps its own tail and discards the rest")
    func oversizedChunk() {
        var buffer = TailBuffer(capacity: 5)
        buffer.append("earlier")
        buffer.append("0123456789")

        #expect(buffer.didTruncate)
        #expect(buffer.joined() == "56789")
        #expect(!buffer.joined().contains("earlier"))
    }

    @Test("Zero capacity collects nothing but records that it truncated")
    func zeroCapacity() {
        var buffer = TailBuffer(capacity: 0)
        buffer.append("anything")
        #expect(buffer.isEmpty)
        #expect(buffer.joined().isEmpty)
        #expect(buffer.didTruncate)
    }

    @Test("Negative capacity is clamped rather than trapping")
    func negativeCapacity() {
        var buffer = TailBuffer(capacity: -10)
        buffer.append("x")
        #expect(buffer.capacity == 0)
        #expect(buffer.joined().isEmpty)
    }

    @Test("Peak retention stays near the budget across many chunks")
    func compactionKeepsRetentionBounded() {
        var buffer = TailBuffer(capacity: 50)
        for index in 0..<5000 {
            buffer.append("chunk-\(index)")
        }
        // The invariant that matters: we are holding ~capacity, not ~5000 chunks.
        #expect(buffer.characterCount <= 50)
        #expect(buffer.joined().count <= 50 + 8)
        #expect(buffer.joined().contains("4999"))
        #expect(buffer.didTruncate)
    }

    @Test("Multi-byte characters are counted as characters, not bytes")
    func unicodeCounting() {
        var buffer = TailBuffer(capacity: 4)
        buffer.append("äöü")  // 3 characters
        #expect(!buffer.didTruncate)
        buffer.append("x")  // 4, still fits
        #expect(buffer.joined() == "äöü\nx")
        #expect(!buffer.didTruncate)
    }

    @Test("An untouched buffer joins to the empty string")
    func emptyBuffer() {
        let buffer = TailBuffer(capacity: 10)
        #expect(buffer.isEmpty)
        #expect(buffer.joined().isEmpty)
        #expect(!buffer.didTruncate)
    }
}
