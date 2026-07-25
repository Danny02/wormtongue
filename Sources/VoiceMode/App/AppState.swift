import AppKit
import ApplicationServices
import Combine
import Foundation
import KeyboardShortcuts
import VoiceModeCore

struct Dictation: Identifiable {
    let id = UUID()
    let date = Date()
    var modeName: String
    var raw: String
    var result: String
    var contextSent: Bool
    var destination: RewriteDestination
    var intent: EditIntent
    var action: InsertionAction
    var method: InsertionMethod
    var timings: String
    var context: FieldContext
    /// The field's contents before a destructive action, so it can be put back.
    var previousFieldValue: String?
    /// Held so "re-insert" and "re-run" can target the same field.
    var focusedElement: AXUIElement?

    var appName: String? { context.appName }
    var llmUsed: Bool { destination != .none }
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
        /// `contextSent` drives the visible indicator required by §7.
        case rewriting(contextSent: Bool)
        case inserting
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
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
    @Published private(set) var activeDestination: RewriteDestination = .none
    /// Drives the "Revert last edit" affordance.
    @Published private(set) var revertable: Dictation?
    @Published private(set) var config: Config = .fallback
    @Published private(set) var activeEndpoint: APIEndpoint = .anthropic

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let contextProbe = ContextProbe()
    private let inserter = TextInserter()
    private let anthropic = AnthropicClient()
    private let localRewriter = LocalRewriter()
    private let overlay = OverlayController()

    /// Rebuilt only when the config changes — it precompiles regexes and builds
    /// lookup sets, which has no business happening inside the latency budget.
    private(set) var resolver = ModeResolver(config: .fallback)

    private var recordingTarget: ContextProbe.Target?
    /// Started on key-down so the AX traversal overlaps the recording instead of
    /// sitting in the post-release critical path.
    private var probeTask: Task<ProbeResult?, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var didBootstrap = false
    private let historyLimit = 25

    private func rewriter(for destination: RewriteDestination) -> any Rewriter {
        destination == .local ? localRewriter : anthropic
    }

    /// Whether this build has the on-device pass compiled in.
    var localPassAvailable: Bool {
        #if VOICEMODE_LOCAL_PASS
        return true
        #else
        return false
        #endif
    }

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
        case let .rewriting(contextSent): return contextSent ? "paperplane.fill" : "wand.and.stars"
        case .inserting, .done: return "text.cursor"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var statusText: String {
        switch phase {
        case .idle: return modelReady ? "Ready" : "Loading Whisper model…"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
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

    func reloadConfig() {
        let (loaded, error) = ConfigStore.load()
        config = loaded
        resolver = ModeResolver(config: loaded)
        Feedback.enabled = loaded.soundFeedback

        var problems: [String] = []
        if let error { problems.append(error) }

        // A bad base URL falls back rather than bricking the rewrite pass.
        let endpoint = loaded.endpoint ?? .anthropic
        if loaded.endpoint == nil {
            problems.append(
                "api_base_url is not a usable http(s) URL, using \(APIEndpoint.anthropic.base.absoluteString) — \(loaded.apiBaseURL)"
            )
        }
        let headers = loaded.apiHeaders
        Task { [anthropic] in await anthropic.configure(endpoint: endpoint, headers: headers) }
        activeEndpoint = endpoint
        let badPatterns = resolver.invalidTitlePatterns
        if !badPatterns.isEmpty {
            problems.append("Unusable window title regex — \(badPatterns.joined(separator: "; "))")
        }
        let inert = resolver.inertOptIns
        if !inert.isEmpty {
            problems.append(
                "Listed for edits or context but with no rewrite pass to use it, so inert — "
                    + inert.joined(separator: ", "))
        }
        let both = resolver.localOverridesCloud
        if !both.isEmpty {
            problems.append(
                "Listed for both passes; the on-device pass wins — " + both.joined(separator: ", "))
        }
        #if !VOICEMODE_LOCAL_PASS
        if !loaded.localOptInBundleIds.isEmpty {
            problems.append(
                "local_opt_in_bundle_ids is set but this build has no on-device pass; rebuild with --local-pass"
            )
        }
        #endif
        configError = problems.isEmpty ? nil : problems.joined(separator: "\n")
        if let configError { log.error("config: \(configError, privacy: .public)") }
    }

    func prewarmModel() async {
        // The on-device model, if any app asks for it, is a multi-GB download —
        // start it at launch rather than on the first dictation.
        if !config.localOptInBundleIds.isEmpty {
            let localModel = config.localModel
            Task { [localRewriter] in await localRewriter.prewarm(model: localModel) }
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
        case .transcribing, .rewriting, .inserting:
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
        probeTask = Task { [contextProbe] in
            guard !policy.denied else { return nil }
            return await contextProbe.probe(
                target, contextCharCap: contextCharCap, fieldCharCap: fieldCharCap)
        }

        // Same idea for whichever pass this app uses.
        if policy.rewriteAllowed {
            let target = rewriter(for: policy.destination)
            let modelName = policy.destination == .local ? config.localModel : config.model
            Task { await target.prewarm(model: modelName) }
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
            transcript = try await transcriber.transcribe(samples, model: config.whisperModel)
            watch.lap("transcribe")
        } catch {
            probeTask?.cancel()
            probeTask = nil
            guard !Task.isCancelled else { return }
            fail("Transcription: \(error.localizedDescription)")
            return
        }

        // Almost certainly already finished — it has been running since key-down.
        var probed: ProbeResult?
        if let probeTask { probed = await probeTask.value }
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

        // Denied, or the app never opted in: raw transcript, nothing leaves the machine.
        guard policy.rewriteAllowed else {
            phase = .inserting
            // With a selection live, a plain insert replaces it — the same thing
            // typing would do, so it needs no special handling.
            let method = inserter.insert(transcript, into: element)
            watch.lap("insert")
            finish(
                Dictation(
                    modeName: policy.denied ? "denied (raw)" : "not opted in (raw)",
                    raw: transcript, result: transcript,
                    contextSent: false, destination: .none,
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

        activeDestination = policy.destination
        // The indicator reflects what actually leaves the machine, so an on-device
        // rewrite never claims to be sending anything.
        phase = .rewriting(contextSent: policy.contextLeavesMachine)
        let local = policy.destination == .local
        let decision: EditDecision
        do {
            decision = try await rewriter(for: policy.destination).edit(
                model: local ? config.localModel : (mode.model ?? config.model),
                system: resolver.systemPrompt(
                    for: mode, intent: intent, structuredOutput: !local),
                user: resolver.userMessage(
                    transcript: transcript, context: context, policy: policy, intent: intent),
                maxTokens: config.maxTokens,
                intent: intent
            )
            watch.lap(local ? "local" : "llm")
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            if let apiError = error as? AnthropicError, apiError == .cancelled { return }

            log.error("llm: \(error.localizedDescription, privacy: .public)")
            // Fall back to the raw transcript rather than dropping the utterance.
            if rawInserted == 0 {
                phase = .inserting
                let method = inserter.insert(transcript, into: element)
                watch.lap("insert-fallback")
                record(
                    Dictation(
                        modeName: "\(mode.name) (\(local ? "on-device" : "API") failed)",
                        raw: transcript, result: transcript,
                        contextSent: policy.contextLeavesMachine, destination: .none,
                        intent: intent, action: .insert, method: method,
                        timings: watch.summary, context: context,
                        previousFieldValue: context.fieldValue, focusedElement: element))
            }
            fail(error.localizedDescription)
            return
        }

        guard !Task.isCancelled else { return }
        phase = .inserting

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
                contextSent: policy.contextLeavesMachine, destination: policy.destination,
                intent: intent, action: action, method: method,
                timings: watch.summary, context: context,
                previousFieldValue: context.fieldValue, focusedElement: element))
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
        revertable = dictation.canRevert && dictation.method != .aborted ? dictation : nil
        log.info(
            """
            \(dictation.modeName, privacy: .public) via \(dictation.method.rawValue, privacy: .public) \
            | \(dictation.timings, privacy: .public)
            """)
    }

    private func finish(_ dictation: Dictation) {
        record(dictation)
        pipelineTask = nil
        if dictation.method == .aborted {
            fail("Insertion was blocked — a secure field took focus.")
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
        if method == .aborted {
            fail("Could not revert — a secure field took focus.")
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
                let local = policy.destination == .local
                activeDestination = policy.destination
                let decision = try await rewriter(for: policy.destination).edit(
                    model: local ? config.localModel : (mode.model ?? config.model),
                    system: resolver.systemPrompt(
                        for: mode, intent: .compose, structuredOutput: !local),
                    user: resolver.userMessage(
                        transcript: dictation.raw, context: dictation.context, policy: policy,
                        intent: .compose),
                    maxTokens: config.maxTokens,
                    intent: .compose
                )
                guard !Task.isCancelled else { return }
                phase = .inserting
                let method = inserter.insert(decision.text, into: dictation.focusedElement)
                finish(
                    Dictation(
                        modeName: "\(mode.name) (re-run)", raw: dictation.raw,
                        result: decision.text,
                        contextSent: dictation.contextSent, destination: policy.destination,
                        intent: .compose, action: .insert, method: method,
                        timings: "re-run", context: dictation.context,
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
