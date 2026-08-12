import Combine
import KeyboardShortcuts
import SwiftUI
import WormtongueCore

/// First-run checklist. Getting permissions wrong is the #1 way this app looks
/// broken, so every one of them gets a live status dot and a deep link.
struct SetupView: View {
    @EnvironmentObject private var state: AppState
    @State private var granted: [Permission: Bool] = [:]
    @State private var apiKeyField = ""
    @State private var apiKeyStatus = ""
    @State private var checking = false
    @State private var healthResult = ""

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
                        staleGrantHint
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
                        HStack {
                            Button("Check connection") {
                                checking = true
                                healthResult = ""
                                Task {
                                    let result = await state.checkHealth()
                                    healthResult =
                                        result == nil ? "OK — endpoint and key work." : result!
                                    checking = false
                                }
                            }
                            .disabled(checking)
                            if checking {
                                ProgressView().controlSize(.small)
                            }
                        }
                        if !healthResult.isEmpty {
                            Text(healthResult)
                                .font(.caption)
                                .foregroundStyle(healthResult.hasPrefix("OK") ? .green : .orange)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Config") {
                    VStack(alignment: .leading, spacing: 6) {
                        labelled("File", ConfigStore.url.path)
                        labelled("Whisper model", state.config.whisperModel)
                        HStack(alignment: .firstTextBaseline) {
                            Text("Rewrite model").font(.caption).foregroundStyle(.secondary)
                                .frame(width: 150, alignment: .leading)
                            TextField("model id", text: modelField)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: 200)
                            Button("Set") { state.setModel(modelField.wrappedValue) }
                                .controlSize(.small)
                        }
                        labelled(
                            "API endpoint",
                            state.activeEndpoint.base.absoluteString
                                + (state.activeEndpoint.isDefault ? "" : "  (overridden)"))
                        labelled("Hotkey mode", state.config.hotkeyMode.rawValue)
                        labelled("Modes", state.config.modes.map(\.name).joined(separator: ", "))
                        labelled(
                            "Rewrite pass",
                            "every app except the denied list")
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

                GroupBox("Bundle IDs") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            "Running apps and their bundle ids, for the opt-in lists in the config file."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ForEach(runningApps, id: \.bundleId) { app in
                            HStack {
                                Text(app.name)
                                    .font(.caption)
                                    .frame(width: 150, alignment: .leading)
                                Text(app.bundleId)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Spacer()
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(app.bundleId, forType: .string)
                                }
                                .controlSize(.small)
                            }
                        }
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
            Text("Wormtongue").font(.title2).bold()
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
                // Says why "Grant" did nothing, which is otherwise unknowable.
                if permission == .microphone, !ok {
                    Text("Status: \(Permissions.microphoneStatus.label)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if !ok {
                Button("Grant") { request(permission) }
                Button("Settings") { Permissions.openSettings(for: permission) }
            }
        }
    }

    /// Shown only while something is missing. The Accessibility list keying on the
    /// signature is the single most confusing thing about running an ad-hoc build:
    /// the switch is on, the app is untrusted, and nothing on screen explains it.
    @ViewBuilder
    private var staleGrantHint: some View {
        if Permission.allCases.contains(where: { granted[$0] == false }) {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "Switched on in System Settings but still grey here? The grant is bound to "
                        + "the app's signature, and every rebuild re-signs this bundle. Remove the "
                        + "old Wormtongue entry from the list, then add this exact bundle back:"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Text(Permissions.runningBundleURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)

                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            Permissions.runningBundleURL
                        ])
                    }
                    Button("Copy path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            Permissions.runningBundleURL.path, forType: .string)
                    }
                }
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

    /// Bind the config's model into an editable field.
    private var modelField: Binding<String> {
        Binding(
            get: { state.config.model },
            set: { _ in }
        )
    }

    private var runningApps: [(name: String, bundleId: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier else { return nil }
                return (app.localizedName ?? id, id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func refresh() {
        for permission in Permission.allCases {
            granted[permission] = Permissions.isGranted(permission)
        }
    }
}
