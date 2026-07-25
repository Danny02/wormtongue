import AppKit
import ApplicationServices
import Combine
import Foundation
import KeyboardShortcuts

struct Dictation: Identifiable {
    let id = UUID()
    let date = Date()
    var appName: String?
    var bundleId: String?
    var modeName: String
    var raw: String
    var result: String
    var contextSent: Bool
    var llmUsed: Bool
    var method: InsertionMethod
    var timings: String
    /// Held so "re-insert" and "re-run" can target the same field.
    var focusedElement: AXUIElement?
    var probe: ProbeResult?
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
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var history: [Dictation] = []
    @Published private(set) var lastProbe: ProbeResult?
    @Published private(set) var configError: String?
    @Published private(set) var modelReady = false
    @Published var config: Config = .default

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let probe = ContextProbe()
    private let inserter = TextInserter()
    private let anthropic = AnthropicClient()

    private var recordingTarget: ContextProbe.Target?
    private let historyLimit = 25

    var resolver: ModeResolver { ModeResolver(config: config) }

    var statusSymbol: String {
        switch phase {
        case .idle: return Permissions.isGranted(.accessibility) ? "mic" : "exclamationmark.triangle"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case let .rewriting(contextSent): return contextSent ? "paperplane.fill" : "wand.and.stars"
        case .inserting: return "text.cursor"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var statusText: String {
        switch phase {
        case .idle: return "Ready"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case let .rewriting(contextSent):
            return contextSent ? "Rewriting — sending screen context" : "Rewriting — transcript only"
        case .inserting: return "Inserting…"
        case let .failed(message): return "Error: \(message)"
        }
    }

    // MARK: - Lifecycle

    private var didBootstrap = false

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        reloadConfig()
        Hotkey.installDefaultIfUnset()

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
        configError = error
        if let error { log.error("config: \(error, privacy: .public)") }
    }

    func prewarmModel() async {
        do {
            try await transcriber.prewarm(model: config.whisperModel)
            modelReady = true
        } catch {
            modelReady = false
            phase = .failed("Whisper model: \(error.localizedDescription)")
        }
    }

    // MARK: - Push-to-talk

    func hotkeyPressed() {
        guard case .idle = phase else { return }
        guard !recorder.isRecording else { return }

        // Never record into a password field.
        if Permissions.secureInputEnabled {
            log.notice("dictation blocked: secure input is enabled")
            NSSound.beep()
            return
        }
        // Capture the target now, while the user's app is still frontmost.
        recordingTarget = ContextProbe.frontmostTarget()

        do {
            try recorder.start()
            phase = .recording
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func hotkeyReleased() {
        guard case .recording = phase else { return }
        let samples = recorder.stop()
        guard let target = recordingTarget else {
            phase = .idle
            return
        }
        recordingTarget = nil

        // A tap with no speech in it. Don't spin up Whisper.
        guard samples.count > Int(AudioRecorder.targetSampleRate * 0.2) else {
            log.debug("discarded \(samples.count) samples: too short")
            phase = .idle
            return
        }

        Task { await runPipeline(samples: samples, target: target) }
    }

    // MARK: - Pipeline

    private func runPipeline(samples: [Float], target: ContextProbe.Target) async {
        var watch = Stopwatch()
        let policy = resolver.policy(for: target.bundleId)
        phase = .transcribing

        // The probe is IPC-bound and the transcription is compute-bound; they have
        // no dependency on each other, so overlap them.
        let charCap = config.contextCharCap
        async let probed = probeIfAllowed(policy: policy, target: target, charCap: charCap)

        let transcript: String
        do {
            transcript = try await transcriber.transcribe(samples, model: config.whisperModel)
        } catch {
            _ = await probed
            phase = .failed("Transcription: \(error.localizedDescription)")
            return
        }
        let result = await probed
        watch.lap("transcribe+probe")

        lastProbe = result
        if let result {
            log.info("probe:\n\(result.debugSummary, privacy: .private)")
        }

        guard !transcript.isEmpty else {
            phase = .idle
            return
        }

        // Focused a password field between key-down and key-up.
        if result?.isSecureField == true {
            log.notice("dictation discarded: focused element is a secure text field")
            phase = .idle
            return
        }

        let mode = resolver.mode(bundleId: target.bundleId, windowTitle: result?.windowTitle)
        let element = result?.focusedElement

        // Denied, or the app never opted in: raw transcript, nothing leaves the machine.
        guard policy.llmAllowed else {
            phase = .inserting
            let method = inserter.insert(transcript, into: element)
            watch.lap("insert")
            record(Dictation(appName: target.appName, bundleId: target.bundleId,
                             modeName: policy.denied ? "denied (raw)" : "not opted in (raw)",
                             raw: transcript, result: transcript,
                             contextSent: false, llmUsed: false, method: method,
                             timings: watch.summary, focusedElement: element, probe: result))
            phase = .idle
            return
        }

        // Optional mitigation from §7: get something on screen immediately, then
        // replace it when the LLM returns.
        var rawInserted = 0
        if config.insertRawFirst {
            phase = .inserting
            _ = inserter.insert(transcript, into: element)
            rawInserted = transcript.count
            watch.lap("insert-raw")
        }

        phase = .rewriting(contextSent: policy.contextAllowed)
        let system = resolver.systemPrompt(for: mode)
        let user = resolver.userMessage(transcript: transcript,
                                        probe: result,
                                        contextAllowed: policy.contextAllowed)

        let rewritten: String
        do {
            rewritten = try await anthropic.rewrite(
                model: mode.model ?? config.model,
                system: system,
                user: user,
                maxTokens: config.maxTokens
            )
            watch.lap("llm")
        } catch {
            log.error("llm: \(error.localizedDescription, privacy: .public)")
            // Fall back to the raw transcript rather than dropping the utterance.
            if rawInserted == 0 {
                phase = .inserting
                let method = inserter.insert(transcript, into: element)
                record(Dictation(appName: target.appName, bundleId: target.bundleId,
                                 modeName: "\(mode.name) (llm failed)",
                                 raw: transcript, result: transcript,
                                 contextSent: policy.contextAllowed, llmUsed: false, method: method,
                                 timings: watch.summary, focusedElement: element, probe: result))
            }
            phase = .failed(error.localizedDescription)
            return
        }

        phase = .inserting
        let method = rawInserted > 0
            ? inserter.replaceTrailing(characterCount: rawInserted, with: rewritten, into: element)
            : inserter.insert(rewritten, into: element)
        watch.lap("insert")

        record(Dictation(appName: target.appName, bundleId: target.bundleId, modeName: mode.name,
                         raw: transcript, result: rewritten,
                         contextSent: policy.contextAllowed, llmUsed: true, method: method,
                         timings: watch.summary, focusedElement: element, probe: result))
        phase = .idle
    }

    /// A hard-denied app is not probed at all — we do not even read its tree.
    private func probeIfAllowed(policy: Policy, target: ContextProbe.Target,
                                charCap: Int) async -> ProbeResult? {
        guard !policy.denied else { return nil }
        return await probe.probe(target, charCap: charCap)
    }

    private func record(_ dictation: Dictation) {
        history.insert(dictation, at: 0)
        if history.count > historyLimit { history.removeLast(history.count - historyLimit) }
        log.info("""
            \(dictation.modeName, privacy: .public) via \(dictation.method.rawValue, privacy: .public) \
            | \(dictation.timings, privacy: .public)
            """)
    }

    // MARK: - History actions (M4)

    func reinsert(_ dictation: Dictation) {
        _ = inserter.insert(dictation.result, into: dictation.focusedElement)
    }

    func rerun(_ dictation: Dictation, as mode: Mode) {
        Task {
            phase = .rewriting(contextSent: dictation.contextSent)
            do {
                let text = try await anthropic.rewrite(
                    model: mode.model ?? config.model,
                    system: resolver.systemPrompt(for: mode),
                    user: resolver.userMessage(transcript: dictation.raw,
                                               probe: dictation.probe,
                                               contextAllowed: dictation.contextSent),
                    maxTokens: config.maxTokens
                )
                phase = .inserting
                _ = inserter.insert(text, into: dictation.focusedElement)
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func dismissError() {
        if case .failed = phase { phase = .idle }
    }
}
