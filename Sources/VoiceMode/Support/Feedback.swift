import AppKit

/// Short system sounds so push-to-talk has an edge you can feel without watching
/// the screen. Sounds are loaded once — `NSSound(named:)` re-reads the file each
/// call, which is not something to do on the hotkey path.
@MainActor
enum Feedback {
    private static let start = NSSound(named: "Tink")
    private static let success = NSSound(named: "Pop")
    private static let failure = NSSound(named: "Basso")

    static var enabled = true

    static func recordingStarted() { play(start) }
    static func inserted() { play(success) }
    static func failed() { play(failure) }

    /// No sound of its own — a cancelled dictation should feel like nothing happened.
    static func cancelled() {}

    private static func play(_ sound: NSSound?) {
        guard enabled, let sound else { return }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
