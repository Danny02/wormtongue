import AVFoundation
import AppKit
import ApplicationServices
import Carbon
import IOKit
import IOKit.hid
import WormtongueCore

enum Permission: String, CaseIterable, Identifiable {
    case accessibility
    case microphone
    case inputMonitoring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .microphone: return "Microphone"
        case .inputMonitoring: return "Input Monitoring"
        }
    }

    var why: String {
        switch self {
        case .accessibility:
            return "Read the focused app's text field and post the paste keystroke."
        case .microphone: return "Capture audio while the hotkey is held."
        case .inputMonitoring: return "Detect the global hotkey. Not always required."
        }
    }

    /// System Settings deep-link anchor.
    var settingsAnchor: String {
        switch self {
        case .accessibility: return "Privacy_Accessibility"
        case .microphone: return "Privacy_Microphone"
        case .inputMonitoring: return "Privacy_ListenEvent"
        }
    }
}

enum Permissions {
    static func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted()
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .inputMonitoring:
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        }
    }

    /// Shows the system Accessibility prompt. The user still has to flip the
    /// switch by hand — the prompt only points them at the right pane.
    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// `requestAccess` only ever shows the system prompt from `.notDetermined`.
    /// From `.denied` it returns false immediately and nothing appears on screen,
    /// which reads as a dead button — so callers need `microphoneStatus` to explain.
    static func requestMicrophone() async -> Bool {
        // A menu-bar accessory is not the active app, and the prompt can open
        // behind whatever is. Bring ourselves forward first.
        await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// What macOS currently records for the microphone, in the user's words.
    static var microphoneStatus: (label: String, canPrompt: Bool) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return ("granted", false)
        case .notDetermined: return ("never asked — Grant will show the system prompt", true)
        case .denied:
            return ("denied for this build — macOS will not ask again, use Settings", false)
        case .restricted: return ("restricted by policy", false)
        @unknown default: return ("unknown", false)
        }
    }

    static func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Ventura moved Privacy panes to a new bundle id. The old URL still resolves on
    /// some systems and silently does nothing on others, which is why this button
    /// used to look broken — so try the current one first, then the legacy one, and
    /// fall back to just opening System Settings.
    static func openSettings(for permission: Permission) {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(permission.settingsAnchor)",
            "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsAnchor)",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
        let settings = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.open(settings)
    }

    /// The bundle the *running* process came from.
    ///
    /// Worth showing: an entry in the Accessibility list is bound to the signature
    /// of the binary that asked for it. `bundle.sh` re-signs ad-hoc on every build,
    /// so a stale entry can sit there switched on while this process is untrusted —
    /// which looks exactly like the checkbox lying to you.
    static var runningBundleURL: URL { Bundle.main.bundleURL }

    /// True when any app has secure input enabled for this login session, which
    /// is what happens while a password field has the keyboard. This is a
    /// session-global flag, not "you are in a password field": browsers and
    /// password managers routinely leave it on after the secure field loses focus.
    /// Never record, never paste — §7 of the brief.
    static var secureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }

    /// The app holding secure input session-wide, resolved to the message to show.
    ///
    /// `IsSecureEventInputEnabled()` above is the authority on whether to block.
    /// This lookup only explains *who* holds it, so a failed lookup must never
    /// change the decision to block — it can only choose a more honest explanation.
    static var secureInputBlocker: SecureInputBlocker {
        guard let pid = secureInputPID else { return .unidentified }
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            // The PID was published but the process is gone: macOS does not always
            // clear the flag when an app exits without releasing it.
            return .exitedProcess
        }
        if let name = app.localizedName, !name.isEmpty {
            return .knownApp(named: name)
        }
        return .unidentified
    }

    /// The PID macOS publishes as holding secure input, read from the console-user
    /// session dictionary (`kCGSSessionSecureInputPID` inside `IOConsoleUsers`).
    private static var secureInputPID: pid_t? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOResources"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard
            let users = IORegistryEntryCreateCFProperty(
                service, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [[String: Any]]
        else { return nil }
        for user in users {
            if let pid = user["kCGSSessionSecureInputPID"] as? Int, pid > 0 {
                return pid_t(pid)
            }
        }
        return nil
    }
}
