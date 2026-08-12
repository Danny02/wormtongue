import AppKit
import ApplicationServices
import Combine
import Foundation
import KeyboardShortcuts
import WormtongueCore

struct Dictation: Identifiable {
    let id = UUID()
    let date = Date()
    var modeName: String
    var raw: String
    var result: String
    var contextSent: Bool
    var llmUsed: Bool
    var intent: EditIntent
    var action: InsertionAction
    var method: InsertionMethod
    var timings: String
    var context: FieldContext
    /// Everything the rewrite pass was given and produced. Nil on the raw path,
    /// where there was no call — which is itself the answer to "why unchanged?".
    var model: String?
    var endpoint: String?
    var systemPrompt: String?
    var userMessage: String?
    var thinking: String?
    /// The field's contents before a destructive action, so it can be put back.
    var previousFieldValue: String?
    /// Held so "re-insert" and "re-run" can target the same field.
    var focusedElement: AXUIElement?

    var appName: String? { context.appName }
    /// Revertable when we overwrote something and know what it was.
    var canRevert: Bool { action.isDestructive && previousFieldValue != nil }
}

@MainActor
final class AppState: ObservableObject {
    /// Singleton so the hotkey handlers and the menu bar scene share one instance
    /// without threading the object through an AppDelegate.
    static let shared = AppState()

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        /// Only reached when the AX probe is still running at release. It starts on
        /// key-down, so normally it has long finished and this never shows.
        case readingContext
        /// `contextSent` drives the visible indicator required by §7.
        case rewriting(contextSent: Bool)
        case inserting
        case done
        case failed(String)
    }

    /// Model preparation is deliberately *not* a `Phase`: it runs at launch,
    /// outside any dictation, and pressing the hotkey while it happens must still
    /// start a recording rather than be swallowed.
    enum ModelStage: Equatable {
        case downloading
        case loading

        var label: String {
            switch self {
            case .downloading: return "Downloading Whisper model…"
            case .loading: return "Loading Whisper model…"
            }
        }

        var detail: String {
            switch self {
            case .downloading: return "first run for this model · about 1.5 GB for large-v3"
            case .loading: return "compiling for this Mac · one-off after a download"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// Non-nil while the model is being fetched or compiled.
    @Published private(set) var modelStage: ModelStage?
    @Published private(set) var history: [Dictation] = []
    @Published private(set) var lastContext: FieldContext?
    @Published private(set) var configError: String?
    @Published private(set) var modelReady = false
    /// 0…1, polled from the recorder rather than pushed from the audio thread.
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var recordedSeconds: TimeInterval = 0
    @Published private(set) var targetAppName: String?
    @Published private(set) var activeModeName: String?
    @Published private(set) var lastResultPreview: String?
    @Published private(set) var activeIntent: EditIntent = .compose
    /// Drives the "Revert last edit" affordance.
    @Published private(set) var revertable: Dictation?
    @Published private(set) var config: Config = .fallback
    @Published private(set) var activeEndpoint: APIEndpoint = .anthropic

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let contextProbe = ContextProbe()
    private let inserter = TextInserter()
    private let anthropic = AnthropicClient()
    private let claude = ClaudeSubscriptionClient()
    private let openAI = OpenAICompatibleClient()

    /// The pipeline's view of the rewrite provider: the interface, never a concrete
    /// adapter. The keyed Anthropic, OpenAI-compatible, and Claude-subscription
    /// adapters exist in this build; any other active provider throws an honest
    /// `ProviderError.adapterUnavailable` rather than faking a success.
    private func activeLLMProvider() throws -> any LLMProvider {
        switch config.provider {
        case .anthropicKeyed: return anthropic
        case .openAICompatible: return openAI
        case .claudeSubscription: return claude
        case .codexSubscription:
            throw ProviderError.adapterUnavailable(config.provider)
        }
    }
    private let overlay = OverlayController()

    /// Rebuilt only when the config changes — it precompiles regexes and builds
    /// lookup sets, which has no business happening inside the latency budget.
    private(set) var resolver = ModeResolver(config: .fallback)

    private var recordingTarget: ContextProbe.Target?
    /// Started on key-down so the AX traversal overlaps the recording instead of
    /// sitting in the post-release critical path.
    private var probeTask: Task<ProbeResult?, Never>?
    /// Whether that task has already returned, so the pipeline only announces
    /// "reading the app's text" when it is actually waiting on it.
    private var probeFinished = false
    private var pipelineTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var didBootstrap = false
    private let historyLimit = 25

    var failureMessage: String? {
        if case let .failed(message) = phase { return message }
        return nil
    }

    var statusSymbol: String {
        switch phase {
        case .idle:
            return Permissions.isGranted(.accessibility) ? "mic" : "exclamationmark.triangle"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .readingContext: return "text.viewfinder"
        case let .rewriting(contextSent): return contextSent ? "paperplane.fill" : "wand.and.stars"
        case .inserting, .done: return "text.cursor"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var statusText: String {
        switch phase {
        case .idle:
            if let modelStage { return modelStage.label }
            return modelReady ? "Ready" : "Preparing Whisper model…"
        case .recording: return "Recording…"
        // The transcribe call blocks on the same actor as the model load, so an
        // unfinished prewarm shows up here rather than as its own phase.
        case .transcribing:
            if let modelStage { return modelStage.label }
            return "Transcribing…"
        case .readingContext: return "Reading the app's text…"
        case let .rewriting(contextSent):
            return contextSent
                ? "Rewriting — sending screen context" : "Rewriting — transcript only"
        case .inserting: return "Inserting…"
        case .done: return "Inserted"
        case let .failed(message): return "Error: \(message)"
        }
    }

    // MARK: - Lifecycle

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        reloadConfig()
        Hotkey.installDefaultIfUnset()
        overlay.attach(self)

        // Push-to-talk: record on key-down, transcribe on key-up.
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in
            self?.hotkeyPressed()
        }
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in
            self?.hotkeyReleased()
        }

        Task { await prewarmModel() }
    }

    /// Verifies the active provider's readiness. For the keyed providers this is a
    /// real one-token call against the endpoint; for the subscription CLIs it is the
    /// local diagnostics (install + login) plus an honest note that the adapter is
    /// not wired yet.
    @MainActor
    func checkHealth() async -> ProviderStatus {
        var result = ProviderDiagnostics.status(
            provider: config.provider, settings: config.activeProviderSettings)
        switch config.provider {
        case .anthropicKeyed:
            if let reason = await anthropic.healthCheck() {
                result.headline = reason
                result.symbol = "exclamationmark.triangle"
            } else {
                result.headline = "Ready — endpoint and key verified"
                result.symbol = "checkmark.circle"
            }
        case .openAICompatible:
            if let reason = await openAI.healthCheck(model: config.resolvedModel(for: nil)) {
                result.headline = reason
                result.symbol = "exclamationmark.triangle"
            } else {
                result.headline = "Ready — endpoint and key verified"
                result.symbol = "checkmark.circle"
            }
        case .claudeSubscription, .codexSubscription:
            break
        }
        return result
    }

    /// Persists the global provider selection and reloads.
    @MainActor
    func setProvider(_ kind: ProviderKind) {
        guard config.provider != kind else { return }
        ConfigStore.write { $0.provider = kind }
        reloadConfig()
    }

    /// Persists a mutation of one provider's settings and reloads.
    @MainActor
    func updateProviderSettings(_ kind: ProviderKind, _ edit: (inout ProviderSettings) -> Void) {
        ConfigStore.write { config in
            var settings = config.providers[kind] ?? ProviderSettings()
            edit(&settings)
            config.providers[kind] = settings
        }
        reloadConfig()
    }

    /// Persists a new rewrite model id and reloads.
    @MainActor
    func setModel(_ model: String) {
        guard !model.isEmpty else { return }
        ConfigStore.write { $0.model = model }
        reloadConfig()
    }

    func reloadConfig() {
        let (loaded, error) = ConfigStore.load()
        config = loaded
        resolver = ModeResolver(config: loaded)
        Feedback.enabled = loaded.soundFeedback

        var problems: [String] = []
        if let error { problems.append(error) }

        // The active keyed provider's endpoint is parsed once here and drives the
        // matching client below. A base URL that fails to parse falls back and is
        // reported. Subscription providers have no HTTP endpoint.
        let activeBase = loaded.activeProviderBaseURL
        let parsedEndpoint = activeBase.flatMap(APIEndpoint.init(base:))
        let endpoint = parsedEndpoint ?? .anthropic
        if let activeBase, parsedEndpoint == nil, loaded.provider.isKeyed {
            problems.append(
                "The \(loaded.provider.displayName) base URL is not a usable http(s) URL, using \(APIEndpoint.anthropic.base.absoluteString) — \(activeBase)"
            )
        }
        let headers = loaded.apiHeaders
        switch loaded.provider {
        case .anthropicKeyed:
            Task { [anthropic] in
                await anthropic.configure(endpoint: endpoint, headers: headers)
            }
        case .openAICompatible:
            let preset = loaded.providers[.openAICompatible]?.preset ?? .custom
            // Resolve the openai host separately from the Anthropic `endpoint`:
            // an unset custom URL must leave the client with no host, not fall back
            // to Anthropic's. `activeProviderBaseURL` resolves preset host or the
            // custom URL, and is nil when neither is set.
            let openAIBase = loaded.activeProviderBaseURL.flatMap(URL.init(string:))
            Task { [openAI] in
                await openAI.configure(endpoint: openAIBase, preset: preset)
            }
        case .claudeSubscription, .codexSubscription:
            break
        }
        activeEndpoint = endpoint
        let badPatterns = resolver.invalidTitlePatterns
        if !badPatterns.isEmpty {
            problems.append("Unusable window title regex — \(badPatterns.joined(separator: "; "))")
        }
        configError = problems.isEmpty ? nil : problems.joined(separator: "\n")
        if let configError { log.error("config: \(configError, privacy: .public)") }
    }

    func prewarmModel() async {
        // A first download is minutes long and otherwise looks like a hang, so it
        // gets the overlay too, not just the menu.
        modelStage =
            await transcriber.isDownloaded(model: config.whisperModel) ? .loading : .downloading
        if modelStage == .downloading, case .idle = phase { showOverlayIfEnabled() }
        defer {
            modelStage = nil
            if case .idle = phase { overlay.hide() }
        }
        do {
            try await transcriber.prewarm(model: config.whisperModel)
            modelReady = true
        } catch {
            modelReady = false
            fail("Whisper model: \(error.localizedDescription)")
        }
    }

    // MARK: - Push-to-talk

    func hotkeyPressed() {
        switch phase {
        case .idle, .done, .failed:
            startRecording()
        case .recording:
            // Hold: this is key repeat, ignore it. Toggle: this is the stop press.
            if config.hotkeyMode == .toggle { finishRecording() }
        case .transcribing, .readingContext, .rewriting, .inserting:
            // Another press while we are working means "never mind".
            cancel()
        }
    }

    func hotkeyReleased() {
        // In toggle mode the release that follows the start press must not stop it.
        guard config.hotkeyMode == .hold, case .recording = phase else { return }
        finishRecording()
    }

    private func startRecording() {
        // Never record into a password field.
        if Permissions.secureInputEnabled {
            log.notice("dictation blocked: secure input is enabled")
            fail("A password field has the keyboard — dictation is disabled.")
            return
        }
        // Capture the target now, while the user's app is still frontmost.
        guard let target = ContextProbe.frontmostTarget() else {
            fail("Could not identify the frontmost app.")
            return
        }
        recordingTarget = target
        targetAppName = target.appName

        do {
            try recorder.start()
        } catch {
            recordingTarget = nil
            fail(error.localizedDescription)
            return
        }

        phase = .recording
        recordedSeconds = 0
        inputLevel = 0
        lastResultPreview = nil
        activeModeName = nil
        activeIntent = .compose
        showOverlayIfEnabled()
        Feedback.recordingStarted()
        startLevelPolling()

        let policy = resolver.policy(for: target.bundleId)

        // The AX traversal is IPC-bound and takes 100–700ms. Starting it here
        // rather than on release takes it off the critical path entirely: focus
        // cannot change while the user is holding the key.
        let contextCharCap = config.contextCharCap
        let fieldCharCap = config.fieldCharCap
        probeFinished = false
        probeTask = Task { [contextProbe] in
            guard !policy.denied else {
                self.probeFinished = true
                return nil
            }
            let result = await contextProbe.probe(
                target, contextCharCap: contextCharCap, fieldCharCap: fieldCharCap)
            self.probeFinished = true
            return result
        }

        // Same idea for the transport warm-up: Anthropic opens its TLS handshake,
        // the Claude subscription spawns/primes its CLI — both before the
        // transcript is ready, hiding startup behind the speech.
        if policy.llmAllowed {
            switch config.provider {
            case .anthropicKeyed:
                Task { [anthropic] in await anthropic.warmConnection() }
            case .claudeSubscription:
                Task { [claude] in await claude.warm() }
            case .openAICompatible, .codexSubscription:
                break
            }
        }
    }

    private func finishRecording() {
        stopLevelPolling()
        let samples = recorder.stop()
        guard let target = recordingTarget else {
            phase = .idle
            overlay.hide()
            return
        }
        recordingTarget = nil

        // A tap with no speech in it. Don't spin up Whisper.
        guard samples.count > Int(AudioRecorder.targetSampleRate * 0.2) else {
            log.debug("discarded \(samples.count) samples: too short")
            probeTask?.cancel()
            probeTask = nil
            phase = .idle
            overlay.hide()
            return
        }

        pipelineTask = Task { await runPipeline(samples: samples, target: target) }
    }

    func cancel() {
        pipelineTask?.cancel()
        pipelineTask = nil
        probeTask?.cancel()
        probeTask = nil
        if recorder.isRecording {
            recorder.cancel()
            stopLevelPolling()
        }
        recordingTarget = nil
        phase = .idle
        overlay.hide()
        Feedback.cancelled()
        log.notice("dictation cancelled")
    }

    // MARK: - Pipeline

    private func runPipeline(samples: [Float], target: ContextProbe.Target) async {
        var watch = Stopwatch()
        let policy = resolver.policy(for: target.bundleId)
        phase = .transcribing

        let transcript: String
        do {
            transcript = try await transcriber.transcribe(
                samples, model: config.whisperModel, language: config.whisperLanguage)
            watch.lap("transcribe")
        } catch {
            probeTask?.cancel()
            probeTask = nil
            guard !Task.isCancelled else { return }
            fail("Transcription: \(error.localizedDescription)")
            return
        }

        // Almost certainly already finished — it has been running since key-down.
        // Only say so when it has not, otherwise the label flickers past.
        var probed: ProbeResult?
        if let probeTask {
            if !probeFinished { phase = .readingContext }
            probed = await probeTask.value
        }
        probeTask = nil
        guard !Task.isCancelled else { return }

        let context =
            probed?.context ?? FieldContext(bundleId: target.bundleId, appName: target.appName)
        let element = probed?.focusedElement
        lastContext = context
        if probed != nil {
            watch.note("probe", seconds: context.elapsed)
            log.info("probe:\n\(context.debugSummary, privacy: .private)")
        }

        guard !transcript.isEmpty else {
            phase = .idle
            overlay.hide()
            return
        }

        // Focus moved to a password field between key-down and key-up.
        if context.isSecureField {
            log.notice("dictation discarded: focused element is a secure text field")
            phase = .idle
            overlay.hide()
            return
        }

        let mode = resolver.mode(bundleId: target.bundleId, windowTitle: context.windowTitle)
        activeModeName = mode.name

        // What the dictation is *for*, given what is already in the field.
        let intent = EditIntent.resolve(context: context, fieldAllowed: policy.fieldAllowed)
        activeIntent = intent

        // Hard-denied app: raw transcript, nothing leaves the machine.
        guard policy.llmAllowed else {
            phase = .inserting
            // With a selection live, a plain insert replaces it — the same thing
            // typing would do, so it needs no special handling.
            let method = inserter.insert(transcript, into: element)
            watch.lap("insert")
            finish(
                Dictation(
                    modeName: "denied (raw)",
                    raw: transcript, result: transcript,
                    contextSent: false, llmUsed: false,
                    intent: intent,
                    action: context.hasSelection ? .replaceSelection : .insert,
                    method: method,
                    timings: watch.summary, context: context,
                    previousFieldValue: context.fieldValue, focusedElement: element))
            return
        }

        // Optional mitigation from §7: get something on screen immediately, then
        // replace it when the LLM returns.
        var rawInserted = 0
        if config.insertRawFirst && intent == .compose {
            phase = .inserting
            _ = inserter.insert(transcript, into: element)
            rawInserted = transcript.count
            watch.lap("insert-raw")
        }

        phase = .rewriting(contextSent: policy.contextAllowed)
        let prompt = makePrompt(
            mode: mode, transcript: transcript, context: context, policy: policy,
            intent: intent)
        let result: LLMResult
        do {
            let provider = try activeLLMProvider()
            result = try await LLMPipeline.run(provider: provider, prompt: prompt)
            watch.lap("llm")
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            if let apiError = error as? AnthropicError, apiError == .cancelled { return }
            if let apiError = error as? OpenAICompatibleError, apiError == .cancelled { return }

            log.error("llm: \(error.localizedDescription, privacy: .public)")
            // Fall back to the raw transcript rather than dropping the utterance.
            if rawInserted == 0 {
                phase = .inserting
                let method = inserter.insert(transcript, into: element)
                watch.lap("insert-fallback")
                record(
                    Dictation(
                        modeName: "\(mode.name) (llm failed)",
                        raw: transcript, result: transcript,
                        contextSent: policy.contextAllowed, llmUsed: false,
                        intent: intent, action: .insert, method: method,
                        timings: watch.summary, context: context,
                        previousFieldValue: context.fieldValue, focusedElement: element))
            }
            fail(error.localizedDescription)
            return
        }

        guard !Task.isCancelled else { return }
        phase = .inserting

        let decision = result.decision
        let action = apply(intent: intent, decision: decision)
        let method: InsertionMethod
        switch action {
        case .replaceAll:
            method = inserter.replaceAll(with: decision.text, in: element)
        case .replaceSelection:
            // Paste and AX both replace a live selection, so the ordinary insert
            // path already does the right thing here.
            method = inserter.insert(decision.text, into: element)
        case .insert:
            method =
                rawInserted > 0
                ? inserter.replaceTrailing(
                    characterCount: rawInserted, with: decision.text, into: element)
                : inserter.insert(decision.text, into: element)
        }
        watch.lap("insert")

        finish(
            Dictation(
                modeName: mode.name, raw: transcript, result: decision.text,
                contextSent: policy.contextAllowed, llmUsed: true,
                intent: intent, action: action, method: method,
                timings: watch.summary, context: context,
                model: prompt.model, endpoint: activeEndpoint.base.absoluteString,
                systemPrompt: prompt.system, userMessage: prompt.user,
                thinking: result.thinking,
                previousFieldValue: context.fieldValue, focusedElement: element))
    }

    /// Builds the seam's prompt from the resolved mode, the privacy policy, and
    /// the transcript. Shared by the main pipeline and the history re-run, which
    /// differ only in which context and transcript they feed it.
    private func makePrompt(
        mode: Mode, transcript: String, context: FieldContext, policy: Policy, intent: EditIntent
    ) -> LLMPrompt {
        LLMPrompt(
            model: config.resolvedModel(for: mode),
            system: resolver.systemPrompt(for: mode, intent: intent),
            user: resolver.userMessage(
                transcript: transcript, context: context, policy: policy, intent: intent),
            maxTokens: config.maxTokens,
            intent: intent
        )
    }

    /// Reconciles what the model asked for with what the field state permits.
    ///
    /// The model only ever proposes `insert` or `replace_all`, and `replace_all` is
    /// refused unless we actually hold the field's full previous contents — without
    /// them the edit could not be undone.
    private func apply(intent: EditIntent, decision: EditDecision) -> InsertionAction {
        switch intent {
        case .compose:
            return .insert
        case .replaceSelection:
            return .replaceSelection
        case .revise:
            guard decision.action == .replaceAll else { return .insert }
            return .replaceAll
        }
    }

    /// Appends to history and logs. Says nothing about whether the dictation
    /// succeeded — the LLM-failure path records a fallback insert and then fails.
    private func record(_ dictation: Dictation) {
        history.insert(dictation, at: 0)
        if history.count > historyLimit { history.removeLast(history.count - historyLimit) }
        lastResultPreview = dictation.result
        // Only offer to undo something we can actually put back.
        revertable = dictation.canRevert && !dictation.method.failed ? dictation : nil
        log.info(
            """
            \(dictation.modeName, privacy: .public) via \(dictation.method.rawValue, privacy: .public) \
            | \(dictation.timings, privacy: .public)
            """)
    }

    private func finish(_ dictation: Dictation) {
        record(dictation)
        pipelineTask = nil
        if dictation.method.failed {
            fail(
                dictation.method == .notPermitted
                    // The text is in History, so say that rather than just "denied".
                    ? "Nothing was inserted: Accessibility is not granted to this build. "
                        + "Re-add Wormtongue in System Settings → Privacy & Security → Accessibility. "
                        + "The text is in History."
                    : "Insertion was blocked — a secure field took focus.")
            return
        }
        phase = .done
        Feedback.inserted()
        overlay.hide(after: 1.4)
        // Clear the transient "done" state so the menu bar returns to Ready.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let self else { return }
            if case .done = self.phase { self.phase = .idle }
        }
    }

    private func fail(_ message: String) {
        pipelineTask = nil
        phase = .failed(message)
        Feedback.failed()
        showOverlayIfEnabled()
        overlay.hide(after: 3.5)
    }

    // MARK: - Overlay and metering

    private func showOverlayIfEnabled() {
        guard config.showOverlay else { return }
        overlay.show()
    }

    /// Polls the recorder at 20 Hz. The alternative — publishing from the audio
    /// render thread — would put SwiftUI invalidation on a realtime thread and
    /// update far more often than any display can show.
    private func startLevelPolling() {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.recorder.isRecording else { return }
                self.inputLevel = self.recorder.level
                self.recordedSeconds = self.recorder.duration
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopLevelPolling() {
        levelTask?.cancel()
        levelTask = nil
        inputLevel = 0
    }

    // MARK: - History actions (M4)

    /// Puts back what a whole-field rewrite or selection replacement overwrote.
    ///
    /// A voice command that silently destroys a draft is not acceptable, so every
    /// destructive action captures the field's previous contents first and this
    /// restores them wholesale — which works for both kinds of overwrite.
    func revert(_ dictation: Dictation) {
        guard let previous = dictation.previousFieldValue else { return }
        let method = inserter.replaceAll(with: previous, in: dictation.focusedElement)
        log.notice(
            "reverted \(dictation.action.rawValue, privacy: .public) via \(method.rawValue, privacy: .public)"
        )
        revertable = nil
        if method.failed {
            fail(
                method == .notPermitted
                    ? "Could not revert — Accessibility is not granted to this build."
                    : "Could not revert — a secure field took focus.")
        } else {
            phase = .done
            lastResultPreview = "Reverted"
            Feedback.inserted()
            showOverlayIfEnabled()
            overlay.hide(after: 1.4)
        }
    }

    func revertLast() {
        if let revertable { revert(revertable) }
    }

    func reinsert(_ dictation: Dictation) {
        _ = inserter.insert(dictation.result, into: dictation.focusedElement)
    }

    func rerun(_ dictation: Dictation, as mode: Mode) {
        pipelineTask?.cancel()
        pipelineTask = Task {
            activeModeName = mode.name
            phase = .rewriting(contextSent: dictation.contextSent)
            showOverlayIfEnabled()
            do {
                // Re-runs always compose: the field has moved on since, so the
                // original draft is no longer a safe thing to rewrite.
                let policy = resolver.policy(for: dictation.context.bundleId)
                let prompt = makePrompt(
                    mode: mode, transcript: dictation.raw, context: dictation.context,
                    policy: policy, intent: .compose)
                let result = try await LLMPipeline.run(
                    provider: try activeLLMProvider(), prompt: prompt)
                guard !Task.isCancelled else { return }
                phase = .inserting
                let method = inserter.insert(
                    result.decision.text, into: dictation.focusedElement)
                finish(
                    Dictation(
                        modeName: "\(mode.name) (re-run)", raw: dictation.raw,
                        result: result.decision.text,
                        contextSent: dictation.contextSent, llmUsed: true,
                        intent: .compose, action: .insert, method: method,
                        timings: "re-run", context: dictation.context,
                        model: prompt.model, endpoint: activeEndpoint.base.absoluteString,
                        systemPrompt: prompt.system, userMessage: prompt.user,
                        thinking: result.thinking,
                        previousFieldValue: nil,
                        focusedElement: dictation.focusedElement))
            } catch {
                guard !Task.isCancelled else { return }
                fail(error.localizedDescription)
            }
        }
    }

    func dismissError() {
        if case .failed = phase {
            phase = .idle
            overlay.hide()
        }
    }
}
