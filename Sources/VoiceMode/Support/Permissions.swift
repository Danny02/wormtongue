import AVFoundation
import AppKit
import ApplicationServices
import Carbon
import IOKit.hid

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
        case .accessibility: return "Read the focused app's text field and post the paste keystroke."
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

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openSettings(for permission: Permission) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsAnchor)")
        if let url { NSWorkspace.shared.open(url) }
    }

    /// True when a password field (or anything else using secure input) has the
    /// keyboard. Never record, never paste — §7 of the brief.
    static var secureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }
}
