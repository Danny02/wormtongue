import Combine
import SwiftUI
import WormtongueCore

/// What the Setup status/health panel shows for the active provider.
///
/// Computed by `ProviderDiagnostics` — which touches the Keychain and the disk to
/// look at CLIs, never the network — and re-checked live for the keyed Anthropic
/// provider via a real request.
struct ProviderStatus: Equatable {
    /// One-line headline, e.g. "Ready — key verified" or "claude not installed".
    var headline: String
    /// SF Symbol name for the status icon.
    var symbol: String
    /// Longer explanation / the reason behind the headline.
    var detail: String?
    /// Vendor sign-in docs for subscription providers.
    var actionURL: URL?

    init(headline: String, symbol: String, detail: String?, actionURL: URL?) {
        self.headline = headline
        self.symbol = symbol
        self.detail = detail
        self.actionURL = actionURL
    }
}

/// Local health/readiness of the active provider.
///
/// The rule is to report honestly: a provider whose adapter does not ship yet (or
/// whose CLI is absent or not logged in) shows exactly that, never a fake OK. All
/// work here is local (Keychain, PATH, credential files) — the only thing that
/// touches a real request is AppState's live Anthropic health check.
enum ProviderDiagnostics {

    static func status(provider: ProviderKind, settings: ProviderSettings) -> ProviderStatus {
        switch provider {
        case .anthropicKeyed: return anthropic(settings: settings)
        case .openAICompatible: return openAICompatible(settings: settings)
        case .claudeSubscription, .codexSubscription: return subscription(provider: provider)
        }
    }

    private static func anthropic(settings: ProviderSettings) -> ProviderStatus {
        let hasKey = Keychain.hasStoredKey(kind: .anthropicKeyed)
        var detail = [
            hasKey
                ? "API key stored in the Keychain."
                : "No API key in the Keychain — ANTHROPIC_API_KEY is read as a fallback."
        ]
        if let base = settings.baseURL { detail.append("Endpoint: \(base)") }
        detail.append("Use Check to verify the key against the endpoint.")
        return ProviderStatus(
            headline: hasKey ? "Configured — verify with Check" : "Needs an API key",
            symbol: hasKey ? "key.fill" : "exclamationmark.triangle",
            detail: detail.joined(separator: "\n"),
            actionURL: nil)
    }

    private static func openAICompatible(settings: ProviderSettings) -> ProviderStatus {
        let hasKey = Keychain.hasStoredKey(kind: .openAICompatible)
        let base = settings.baseURL ?? settings.preset?.baseURL
        let headline: String
        switch (hasKey, base != nil) {
        case (false, false):
            headline = "Needs an API key and a base URL"
        case (true, false):
            headline = "Needs a preset or base URL"
        case (false, true):
            headline = "Needs an API key"
        case (true, true):
            headline = "Configured — adapter not wired yet"
        }
        var detail = [
            hasKey ? "API key stored in the Keychain." : "No API key in the Keychain.",
            base.map { "Endpoint: \($0)" } ?? "No base URL set.",
        ]
        if !ProviderKind.openAICompatible.adapterAvailable {
            detail.append(
                "The OpenAI-compatible adapter ships in a later build; dictation is not available with this provider yet."
            )
        }
        return ProviderStatus(
            headline: headline,
            symbol: headline.hasPrefix("Configured")
                ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle",
            detail: detail.joined(separator: "\n"),
            actionURL: nil)
    }

    private static func subscription(provider: ProviderKind) -> ProviderStatus {
        let command = provider == .claudeSubscription ? "claude" : "codex"
        let installed = findExecutable(command) != nil
        let loggedIn = installed && detectLogin(command: command)
        var detail = [
            installed
                ? "`\(command)` is installed on your PATH."
                : "`\(command)` is not on your PATH."
        ]
        if installed {
            detail.append(
                loggedIn
                    ? "A sign-in credential was detected for the `\(command)` CLI."
                    : "No sign-in credential was detected for the `\(command)` CLI.")
        } else {
            detail.append(
                "Install and sign in per the vendor docs; Wormtongue never stores a subscription token."
            )
        }
        if !provider.adapterAvailable {
            detail.append(
                "The \(provider.displayName) adapter ships in a later build; dictation is not available with this provider yet."
            )
        }
        let headline: String
        if installed && loggedIn {
            headline = "`\(command)` installed and signed in"
        } else if installed {
            headline = "`\(command)` installed — no sign-in detected"
        } else {
            headline = "`\(command)` not installed"
        }
        return ProviderStatus(
            headline: headline,
            symbol: installed && loggedIn ? "checkmark.circle" : "exclamationmark.triangle",
            detail: detail.joined(separator: "\n"),
            actionURL: provider.signInDocsURL)
    }

    /// Finds `command` on the PATH, returning its path or nil.
    static func findExecutable(_ command: String) -> String? {
        guard let pathValue = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(command).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Best-effort sign-in detection for a subscription CLI, from the credential
    /// files each keeps in the user's home. Honest about what it checks: a real
    /// credential *validation* request belongs to the provider's adapter (later
    /// tickets), so absence of a file is reported, never assumed.
    static func detectLogin(command: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch command {
        case "claude":
            // Claude Code keeps its OAuth credentials under ~/.claude/.credentials.json,
            // or its account state in ~/.claude.json (key "oauthAccount"). We cite those
            // specific files, never the mere presence of a ~/.claude directory — running
            // the CLI once creates that even when signed out.
            if FileManager.default.fileExists(atPath: "\(home)/.claude/.credentials.json") {
                return true
            }
            if let data = try? String(contentsOfFile: "\(home)/.claude.json", encoding: .utf8),
                data.contains("oauthAccount")
            {
                return true
            }
            return false
        case "codex":
            return FileManager.default.fileExists(atPath: "\(home)/.codex/auth.json")
        default:
            return false
        }
    }
}

/// The provider picker, per-provider settings, and status/health panel. Replaces
/// the old single "Anthropic API Key" box in Setup: selection is persisted, the
/// active provider's settings are edited here, and the status panel says the
/// truth about readiness.
struct ProviderSection: View {
    @EnvironmentObject private var state: AppState

    @State private var status: ProviderStatus?
    @State private var checking = false

    // Editable mirrors of the active provider's settings, reseeded whenever the
    // provider (or a reload) changes. Persisted via AppState on Set/Save.
    @State private var baseURLField = ""
    @State private var modelField = ""
    @State private var keyField = ""
    @State private var preset: OpenAICompatPreset = .custom
    @State private var keyMessage = ""

    var body: some View {
        GroupBox("Provider") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Active provider", selection: providerBinding) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Text(state.config.provider.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                settings(for: state.config.provider)

                Divider()

                statusPanel
            }
            .padding(6)
        }
        .onAppear(perform: reseed)
        .onChange(of: state.config.provider) {
            reseed()
            status = nil
            keyMessage = ""
        }
    }

    // MARK: - Per-provider settings

    @ViewBuilder
    private func settings(for provider: ProviderKind) -> some View {
        switch provider {
        case .anthropicKeyed:
            keyedSettings(keyLabel: "Anthropic API Key", placeholder: "sk-ant-…")
        case .openAICompatible:
            VStack(alignment: .leading, spacing: 8) {
                Picker("Host", selection: $preset) {
                    ForEach(OpenAICompatPreset.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: preset) {
                    state.updateProviderSettings(.openAICompatible) { settings in
                        settings.preset = preset
                    }
                    reseed()
                }

                if preset == .custom {
                    baseURLRow(for: .openAICompatible)
                } else if let host = preset.baseURL {
                    readOnly("Base URL", host)
                }
                modelRow(for: .openAICompatible)
                keyRow(label: "API Key", placeholder: "sk-…", kind: .openAICompatible)
            }
        case .claudeSubscription, .codexSubscription:
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Uses your existing `\(provider == .claudeSubscription ? "claude" : "codex")` CLI login — nothing secret is stored here."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                modelRow(for: provider)
                if let url = provider.signInDocsURL {
                    Link("Sign-in / install docs", destination: url)
                        .font(.caption)
                } else {
                    EmptyView()
                }
            }
        }
    }

    private func keyedSettings(keyLabel: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            baseURLRow(for: .anthropicKeyed)
            modelRow(for: .anthropicKeyed)
            keyRow(label: keyLabel, placeholder: placeholder, kind: .anthropicKeyed)
        }
    }

    private func baseURLRow(for provider: ProviderKind) -> some View {
        row("Base URL") {
            TextField("https://…", text: $baseURLField)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: 300)
        } trailing: {
            Button("Set") {
                state.updateProviderSettings(provider) { settings in
                    settings.baseURL =
                        baseURLField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil : baseURLField.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                reseed()
            }
            .controlSize(.small)
        }
    }

    private func modelRow(for provider: ProviderKind) -> some View {
        row("Model") {
            TextField("model id or vendor/model", text: $modelField)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: 300)
        } trailing: {
            Button("Set") {
                state.updateProviderSettings(provider) { settings in
                    settings.model =
                        modelField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil : modelField.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                reseed()
            }
            .controlSize(.small)
        }
    }

    private func keyRow(label: String, placeholder: String, kind: ProviderKind) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            SecureField(placeholder, text: $keyField)
                .frame(maxWidth: 220)
            Button("Save") {
                let saved = Keychain.save(keyField, kind: kind)
                keyMessage =
                    saved
                    ? "Saved to Keychain." : "Keychain write failed."
                keyField = ""
                status = nil
            }
            .disabled(keyField.isEmpty)
            .controlSize(.small)
            Button("Remove") {
                Keychain.delete(kind: kind)
                keyMessage = "Removed."
                status = nil
            }
            .controlSize(.small)
            if !keyMessage.isEmpty {
                Text(keyMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func readOnly(_ name: String, _ value: String) -> some View {
        row(name) {
            Text(value).font(.system(.caption, design: .monospaced))
        } trailing: {
            EmptyView()
        }
    }

    private func row<Content: View, Trailing: View>(
        _ name: String, @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(.caption).foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            content()
            trailing()
        }
    }

    // MARK: - Status / health panel

    @ViewBuilder
    private var statusPanel: some View {
        let current =
            status
            ?? ProviderDiagnostics.status(
                provider: state.config.provider,
                settings: state.config.activeProviderSettings)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: current.symbol)
                    .foregroundStyle(
                        state.config.provider.adapterAvailable ? .green : .orange)
                Text(current.headline).font(.caption).bold()
                Spacer()
                Button(checking ? "Checking…" : "Check") {
                    checking = true
                    Task {
                        status = await state.checkHealth()
                        checking = false
                    }
                }
                .disabled(checking)
                .controlSize(.small)
            }
            if let detail = current.detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text("Effective model:").font(.caption2).foregroundStyle(.secondary)
                Text(state.config.resolvedModel(for: nil))
                    .font(.system(.caption2, design: .monospaced))
            }
            if let url = current.actionURL {
                Link("Open \(state.config.provider.displayName) sign-in docs", destination: url)
                    .font(.caption)
            }
        }
    }

    // MARK: - Reseeding

    private func reseed() {
        let settings = state.config.activeProviderSettings
        baseURLField = settings.baseURL ?? ""
        modelField = settings.model ?? ""
        preset = settings.preset ?? .custom
        if state.config.provider != .openAICompatible && modelField.isEmpty {
            // For subscription / anthropic providers, surface the effective default.
            modelField = state.config.resolvedModel(for: nil)
        }
    }

    private var providerBinding: Binding<ProviderKind> {
        Binding(
            get: { state.config.provider },
            set: { newValue in
                state.setProvider(newValue)
                reseed()
                status = nil
            })
    }
}
