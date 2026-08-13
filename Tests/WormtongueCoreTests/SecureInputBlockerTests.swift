import Foundation
import Testing

@testable import WormtongueCore

@Suite("Secure-input block messaging")
struct SecureInputBlockerTests {

    @Test("A named running app appears in the message so the user knows who to release")
    func knownApp() {
        let message = SecureInputBlocker.knownApp(named: "Zen").message
        #expect(message.contains("Zen"))
        #expect(message.contains("until it releases the keyboard"))
    }

    @Test("The historical wording is the fallback when no PID is resolved")
    func unidentifiedFallsBack() {
        #expect(
            SecureInputBlocker.unidentified.message
                == "A password field has the keyboard — dictation is disabled.")
    }

    @Test("A dead process is explained honestly instead of printing a stale PID")
    func exitedProcessIsHonest() {
        let message = SecureInputBlocker.exitedProcess.message
        #expect(message.contains("no longer running"))
        #expect(!message.contains("PID"))
    }

    @Test("Every case yields a non-empty sentence for the user")
    func allCasesHaveMessage() {
        for case let blocker in [
            SecureInputBlocker.knownApp(named: "Zen"),
            SecureInputBlocker.exitedProcess,
            SecureInputBlocker.unidentified,
        ] {
            #expect(!blocker.message.isEmpty)
        }
    }
}
