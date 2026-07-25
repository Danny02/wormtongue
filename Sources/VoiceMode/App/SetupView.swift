import Combine
import KeyboardShortcuts
import SwiftUI
import VoiceModeCore

/// First-run checklist. Getting permissions wrong is the #1 way this app looks
/// broken, so every one of them gets a live status dot and a deep link.
struct SetupView: View {
    @EnvironmentObject private var state: AppState
    @State private var granted: [Permission: Bool] = [:]
    @State private var apiKeyField = ""
    @State private var apiKeyStatus = ""

    // Permissions get toggled in System Settings, outside this process — poll.
    @State private var poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                GroupBox("Permissions") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Permission.allCases) { permission in
                            permissionRow(permission)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Hotkey") {
                    VStack(alignment: .leading, spacing: 6) {
                        KeyboardShortcuts.Recorder("Hold to dictate:", name: .dictate)
                        Text(
                            "Push-to-talk: recording starts on key-down and transcribes on release."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("Anthropic API Key") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            Keychain.hasStoredKey
                                ? "A key is stored in the Keychain."
                                : "No key in the Keychain. ANTHROPIC_API_KEY is used as a fallback."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        HStack {
                            SecureField("sk-ant-…", text: $apiKeyField)
                                .frame(maxWidth: 320)
                            Button("Save") {
                                apiKeyStatus =
                                    Keychain.save(apiKeyField)
                                    ? "Saved to Keychain." : "Keychain write failed."
                                apiKeyField = ""
                            }
                            .disabled(apiKeyField.isEmpty)
                            Button("Remove") {
                                Keychain.delete()
                                apiKeyStatus = "Removed."
                            }
                        }
                        if !apiKeyStatus.isEmpty {
                            Text(apiKeyStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Config") {
                    VStack(alignment: .leading, spacing: 6) {
                        labelled("File", ConfigStore.url.path)
                        labelled("Whisper model", state.config.whisperModel)
                        labelled("Rewrite model", state.config.model)
                        labelled(
                            "API endpoint",
                            state.activeEndpoint.base.absoluteString
                                + (state.activeEndpoint.isDefault ? "" : "  (overridden)"))
                        labelled("Hotkey mode", state.config.hotkeyMode.rawValue)
                        labelled("Modes", state.config.modes.map(\.name).joined(separator: ", "))
                        labelled(
                            "LLM pass allowed for",
                            state.config.llmOptInBundleIds.isEmpty
                                ? "nothing yet — every app gets the raw transcript"
                                : state.config.llmOptInBundleIds.joined(separator: ", "))
                        labelled(
                            "Field edits allowed for",
                            state.config.editOptInBundleIds.isEmpty
                                ? "nothing — dictation only ever appends"
                                : state.config.editOptInBundleIds.joined(separator: ", "))
                        labelled(
                            "Screen context sent for",
                            state.config.contextOptInBundleIds.isEmpty
                                ? "nothing"
                                : state.config.contextOptInBundleIds.joined(separator: ", "))
                        labelled(
                            "Overlay / sounds",
                            "\(state.config.showOverlay ? "overlay on" : "overlay off") · "
                                + (state.config.soundFeedback ? "sounds on" : "sounds off"))
                        if let error = state.configError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        Button("Reload") { state.reloadConfig() }
                    }
                    .padding(6)
                }

                if let context = state.lastContext {
                    GroupBox("Last context probe") {
                        Text(context.debugSummary)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                }
            }
            .padding(20)
            .frame(width: 560)
        }
        .onAppear(perform: refresh)
        .onReceive(poll) { _ in refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("VoiceMode").font(.title2).bold()
            Text(
                "Audio is transcribed on-device. The rewrite pass sends the transcript — and, for apps you opt in, the surrounding on-screen text — to the Anthropic API."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(_ permission: Permission) -> some View {
        let ok = granted[permission] ?? false
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).bold()
                Text(permission.why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok {
                Button("Grant") { request(permission) }
                Button("Settings") { Permissions.openSettings(for: permission) }
            }
        }
    }

    private func labelled(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(name).font(.caption).foregroundStyle(.secondary).frame(
                width: 150, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Spacer()
        }
    }

    private func request(_ permission: Permission) {
        switch permission {
        case .accessibility:
            Permissions.promptAccessibility()
        case .microphone:
            Task {
                _ = await Permissions.requestMicrophone(); refresh()
            }
        case .inputMonitoring:
            Permissions.requestInputMonitoring()
        }
    }

    private func refresh() {
        for permission in Permission.allCases {
            granted[permission] = Permissions.isGranted(permission)
        }
    }
}
