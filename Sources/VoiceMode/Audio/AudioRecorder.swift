import AVFoundation

enum AudioError: LocalizedError {
    case noInputDevice
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No usable audio input device."
        case .converterUnavailable: return "Could not build a 16 kHz mono converter for the input format."
        }
    }
}

/// AVAudioEngine input tap, converted to what Whisper wants: 16 kHz mono Float32.
final class AudioRecorder {
    static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    /// One converter per session: sample-rate conversion is stateful.
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    private(set) var isRecording = false

    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / Self.targetSampleRate
    }

    func start() throws {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioError.converterUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
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
        lock.lock()
        let captured = samples
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
        return captured
    }

    // Runs on the audio render thread. NSLock here is a prototype shortcut —
    // a lock-free ring buffer is the right answer if this ever ships.
    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

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
            log.error("audio conversion failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            return
        }
        guard out.frameLength > 0, let channel = out.floatChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
    }
}
