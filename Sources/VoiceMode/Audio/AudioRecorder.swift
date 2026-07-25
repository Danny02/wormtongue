import AVFoundation
import os

enum AudioError: LocalizedError {
    case noInputDevice
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No usable audio input device."
        case .converterUnavailable:
            return "Could not build a 16 kHz mono converter for the input format."
        }
    }
}

/// AVAudioEngine input tap, converted to what Whisper wants: 16 kHz mono Float32.
///
/// The tap runs on the realtime audio render thread, so the callback path is built
/// to avoid allocating: the destination PCM buffer is created once and reused, the
/// sample store is preallocated for `maxSeconds`, and the critical section is a
/// `memcpy` under an unfair lock rather than an `Array.append(contentsOf:)` under
/// an `NSLock`.
final class AudioRecorder {
    static let targetSampleRate: Double = 16_000
    /// Recording stops accumulating past this. 2 minutes of Float32 at 16 kHz is
    /// ~7.7 MB, allocated once at start.
    private let maxSeconds = 120.0

    /// Preallocated sample store. Only ever touched under `lock`.
    private final class Sink {
        let capacity: Int
        let storage: UnsafeMutablePointer<Float>
        var count = 0
        var overflowed = false
        /// Most recent RMS, mapped to 0…1 for the level meter.
        var level: Float = 0

        init(capacity: Int) {
            self.capacity = capacity
            storage = .allocate(capacity: capacity)
        }

        deinit { storage.deallocate() }
    }

    private let engine = AVAudioEngine()
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    private let lock = OSAllocatedUnfairLock()
    private var sink: Sink?
    /// One converter per session: sample-rate conversion is stateful.
    private var converter: AVAudioConverter?
    /// Reused across callbacks so the render thread never allocates a buffer.
    private var scratch: AVAudioPCMBuffer?
    private(set) var isRecording = false

    /// Seconds captured so far.
    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(sink?.count ?? 0) / Self.targetSampleRate
    }

    /// Input level, 0…1, for the overlay meter. Polled at ~20 Hz by `AppState`
    /// rather than pushed, so the audio thread never touches SwiftUI.
    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return sink?.level ?? 0
    }

    func start() throws {
        guard !isRecording else { return }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioError.converterUnavailable
        }
        self.converter = converter

        let tapFrames: AVAudioFrameCount = 4096
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        // Generous headroom: the converter can emit slightly more than the ratio
        // implies, and a tap can hand us more frames than we asked for.
        let scratchCapacity = AVAudioFrameCount(Double(tapFrames) * ratio * 2) + 2048
        scratch = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: scratchCapacity)

        let newSink = Sink(capacity: Int(Self.targetSampleRate * maxSeconds))
        lock.lock()
        sink = newSink
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: tapFrames, format: inputFormat) {
            [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            self.scratch = nil
            throw error
        }
        isRecording = true
    }

    /// Stops the tap and hands back everything captured.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil
        scratch = nil

        lock.lock()
        let captured =
            sink.map { Array(UnsafeBufferPointer(start: $0.storage, count: $0.count)) } ?? []
        let overflowed = sink?.overflowed ?? false
        sink = nil
        lock.unlock()

        if overflowed {
            log.notice("recording hit the \(Int(maxSeconds))s cap; tail was discarded")
        }
        return captured
    }

    /// Discards the recording without returning it.
    func cancel() {
        _ = stop()
    }

    // MARK: - Render thread

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        // Reuse the scratch buffer; only allocate if a tap hands us an unusually
        // large chunk, which should not happen with a fixed bufferSize.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let needed = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        var out = scratch
        if out == nil || out!.frameCapacity < needed {
            out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: needed)
            scratch = out
        }
        guard let out else { return }
        out.frameLength = 0

        var provided = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            log.error(
                "audio conversion failed: \(error?.localizedDescription ?? "unknown", privacy: .public)"
            )
            return
        }
        let frames = Int(out.frameLength)
        guard frames > 0, let channel = out.floatChannelData else { return }
        let samples = channel[0]

        // Level is computed outside the lock to keep the critical section to a memcpy.
        var sumOfSquares: Float = 0
        for index in 0..<frames {
            let sample = samples[index]
            sumOfSquares += sample * sample
        }
        let level = Self.meterLevel(rms: (sumOfSquares / Float(frames)).squareRoot())

        lock.lock()
        if let sink {
            let room = sink.capacity - sink.count
            if room <= 0 {
                sink.overflowed = true
            } else {
                let copied = min(room, frames)
                (sink.storage + sink.count).update(from: samples, count: copied)
                sink.count += copied
                if copied < frames { sink.overflowed = true }
            }
            // Attack fast, release slow — a meter that tracks RMS directly looks jittery.
            sink.level = level > sink.level ? level : sink.level * 0.82 + level * 0.18
        }
        lock.unlock()
    }

    /// RMS is bunched up near zero; dB spreads it out so the meter reads naturally.
    private static func meterLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let floor: Float = -55
        guard db > floor else { return 0 }
        return min(1, (db - floor) / -floor)
    }
}
