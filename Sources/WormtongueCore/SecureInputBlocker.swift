import Foundation

/// Why dictation refused to start while secure input is held session-wide.
///
/// `IsSecureEventInputEnabled()` is a session-global flag: once any app focuses a
/// secure field it stays on for the whole login session until that app releases
/// it, so the flag does not mean "you are in a password field". The cases below
/// drive the user-facing message that names the real culprit instead of blaming
/// the focused field.
public enum SecureInputBlocker: Sendable, Equatable {
    /// A running app holds secure input — name it.
    case knownApp(named: String)
    /// A PID was published but no such process is running. macOS does not always
    /// clear the flag when an app exits without releasing it, so printing the dead
    /// PID would just confuse the user.
    case exitedProcess
    /// No process could be resolved — fall back to the historical wording.
    case unidentified

    /// The short sentence shown to the user when dictation is refused.
    public var message: String {
        switch self {
        case .knownApp(let name):
            return
                "\(name) has secure input enabled — dictation is disabled until it releases the keyboard."
        case .exitedProcess:
            return
                "An app that is no longer running has secure input enabled — dictation is disabled until macOS releases the keyboard."
        case .unidentified:
            return "A password field has the keyboard — dictation is disabled."
        }
    }
}
