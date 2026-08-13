import Foundation

/// One subscription CLI's per-executable behaviour, parameterised so the shared
/// spawn/parse logic below drives `claude` now and `codex` (ticket #6) later with
/// no changes to the runner. Each executable only contributes *its own* grammar:
/// argument building, environment sanitisation, and output parsing.
public struct SubscriptionCLIVariant: Sendable {
    /// The executable name to look up on PATH, e.g. "claude".
    public let executable: String
    /// Builds the headless one-shot invocation for a completion.
    public let argBuilder: @Sendable (LLMPrompt) -> [String]
    /// Removes keyed env values that must not leak precedence into a subscription
    /// run. For claude this strips `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN`,
    /// which the CLI honours *over* its OAuth token — sending a keyed credential
    /// instead of the user's own login.
    public let envSanitizer: @Sendable ([String: String]) -> [String: String]
    /// Turns captured stdout into a completion. Per-executable, because `claude -p
    /// --output-format json` and `codex exec --json` do not share a shape.
    public let outputParser: @Sendable (Data) throws -> LLMCompletion
    /// Headless args that prime/start the CLI cheaply on key-down (e.g. `auth
    /// status`), which boots its runtime and refreshes auth without a paid call.
    public let primeArguments: [String]

    public init(
        executable: String,
        argBuilder: @escaping @Sendable (LLMPrompt) -> [String],
        envSanitizer: @escaping @Sendable ([String: String]) -> [String: String],
        outputParser: @escaping @Sendable (Data) throws -> LLMCompletion,
        primeArguments: [String]
    ) {
        self.executable = executable
        self.argBuilder = argBuilder
        self.envSanitizer = envSanitizer
        self.outputParser = outputParser
        self.primeArguments = primeArguments
    }
}

/// Failures from spawning or reading a subscription CLI. Each carries enough to
/// say clearly which CLI failed and why, so the status panel / dictation failure
/// can be honest rather than a generic "network error".
public enum SubscriptionCLIError: Error, LocalizedError, Equatable, Sendable {
    case notInstalled(String)
    case launchFailed(String, String)
    case nonZeroExit(String, Int32, String)
    case emptyOutput(String)
    case unparseable(String, String)

    public var errorDescription: String? {
        switch self {
        case let .notInstalled(exec):
            return "`\(exec)` is not on your PATH — install and sign in per the vendor docs."
        case let .launchFailed(exec, reason):
            return "Failed to launch `\(exec)`: \(reason)"
        case let .nonZeroExit(exec, code, stderr):
            return "`\(exec)` exited \(code)\(stderr.isEmpty ? "" : ": \(stderr)")"
        case let .emptyOutput(exec):
            return "`\(exec)` returned no output."
        case let .unparseable(exec, reason):
            return "Could not read `\(exec)` output: \(reason)"
        }
    }
}

/// Shared spawn/capture/parse logic for the subscription CLIs.
///
/// A headless one-shot is a single subprocess that runs to completion, so the
/// runner is deliberately small: resolve the executable on PATH, sanitise the
/// environment, spawn with the given args, capture stdout/stderr, and hand the
/// stdout to the variant's parser. Everything executable-specific stays in the
/// variant; everything else is shared so ticket #6's `codex` reuses it unchanged.
public enum SubscriptionCLI {

    /// Finds `executable` on the given PATH (default: the process environment).
    public static func path(
        for executable: String,
        in environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let value = environment["PATH"] else { return nil }
        for dir in value.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(executable)
                .path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Runs one completion through the CLI and parses the result.
    public static func complete(
        variant: SubscriptionCLIVariant,
        prompt: LLMPrompt,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> LLMCompletion {
        let output = try await runAndCapture(
            variant: variant, args: variant.argBuilder(prompt), environment: environment)
        guard !output.isEmpty else { throw SubscriptionCLIError.emptyOutput(variant.executable) }
        return try variant.outputParser(output)
    }

    /// Spawns the CLI once so its startup and auth refresh overlap dictation.
    /// Uses the cheap prime args (e.g. `claude auth status`) and discards output;
    /// a failure here is not worth surfacing because the real call will report it.
    public static func prime(
        variant: SubscriptionCLIVariant,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async {
        _ = try? await runAndCapture(
            variant: variant, args: variant.primeArguments, environment: environment)
    }

    private static func runAndCapture(
        variant: SubscriptionCLIVariant,
        args: [String],
        environment: [String: String]
    ) async throws -> Data {
        guard let path = path(for: variant.executable, in: environment) else {
            throw SubscriptionCLIError.notInstalled(variant.executable)
        }
        let sanitized = variant.envSanitizer(environment)
        // Confine the child to an empty throwaway directory so the CLI has no
        // project to discover, no local files to read, and nothing it could
        // plausibly claim a tool permission for. A spawned child inherits the
        // parent's TCC identity, so the workdir keeps every access out of the
        // user's folders. Cleaned up once the process exits.
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wormtongue-subscription-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: workDir, withIntermediateDirectories: true)
        } catch {
            throw SubscriptionCLIError.launchFailed(
                variant.executable, error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: workDir) }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.currentDirectoryURL = workDir
            process.arguments = args
            process.environment = sanitized
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err

            do {
                try process.run()
            } catch {
                continuation.resume(
                    throwing: SubscriptionCLIError.launchFailed(
                        variant.executable, error.localizedDescription))
                return
            }
            // A one-shot completion is bounded by `max_tokens` (a few KB), and the
            // prime check is a short status line, so the pipe cannot fill up before
            // the process exits. Wait for exit, then drain both pipes.
            process.waitUntilExit()
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let stderr =
                String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus != 0 {
                continuation.resume(
                    throwing: SubscriptionCLIError.nonZeroExit(
                        variant.executable, process.terminationStatus, stderr))
                return
            }
            continuation.resume(returning: outData)
        }
    }

    /// Parses `claude -p --output-format json` output (one JSON object per line).
    ///
    /// Collects assistant text blocks and the final `result`, skipping `thinking`
    /// blocks so nothing the model "thought" leaks into an insert. The whole thing
    /// is tolerant: a line that is not JSON is ignored rather than failing the
    /// whole completion.
    public static func parseClaudeJSON(_ data: Data) throws -> LLMCompletion {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SubscriptionCLIError.unparseable("claude", "output was not UTF-8 text")
        }
        var assistantTexts: [String] = []  // fallback; `result` is authoritative
        var finalResult: String?  // the CLI's final answer line, when present
        var thinkings: [String] = []
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any]
            else { continue }
            if let result = object["result"] as? String, (object["type"] as? String) == "result" {
                if !result.isEmpty { finalResult = result }
                continue
            }
            guard
                let message = object["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            else { continue }
            for block in content {
                guard let type = block["type"] as? String else { continue }
                if type == "text", let s = block["text"] as? String, !s.isEmpty {
                    assistantTexts.append(s)
                } else if type == "thinking", let s = block["thinking"] as? String {
                    thinkings.append(s)
                }
            }
        }
        let joined = (finalResult ?? assistantTexts.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else {
            throw SubscriptionCLIError.unparseable("claude", "no text response in output")
        }
        let thinking =
            thinkings.isEmpty
            ? nil
            : thinkings.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return LLMCompletion(text: joined, thinking: thinking)
    }

    /// Parses `codex exec --json` output: a single newline-delimited JSON (JSONL)
    /// stream of events, not one final JSON object.
    ///
    /// The final assistant answer arrives as an `item.completed` event whose
    /// `item.type` is `agent_message` carrying a `text` field. Intermediate
    /// tool/commentary chatter is skipped, and the *last* plain `agent_message`
    /// text wins — that is what the user asked for. Codex exposes no thinking
    /// stream to surface, so `thinking` is always nil.
    ///
    /// If codex reported the turn failed before any full agent message arrived,
    /// the underlying reason is surfaced honestly rather than guessing at text.
    public static func parseCodexJSONL(_ data: Data) throws -> LLMCompletion {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SubscriptionCLIError.unparseable("codex", "output was not UTF-8 text")
        }
        var lastAnswer: String?
        var failureMessage: String?
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any]
            else { continue }
            if object["type"] as? String == "item.completed",
                let item = object["item"] as? [String: Any],
                let itemType = item["type"] as? String,
                itemType == "agent_message",
                let s = item["text"] as? String, !s.isEmpty
            {
                lastAnswer = s
                continue
            }
            // A failed turn carries the underlying reason in `error.message`.
            if (object["type"] as? String) == "turn.failed",
                let failure = object["error"] as? [String: Any],
                let message = failure["message"] as? String, !message.isEmpty
            {
                failureMessage = message
                continue
            }
            // A terminal top-level `error` event also names the reason. It is only
            // a fallback: codex can emit transient error notices that a later turn
            // survives, so it must never veto a real answer that was captured.
            if (object["type"] as? String) == "error",
                let message = object["message"] as? String, !message.isEmpty,
                failureMessage == nil
            {
                failureMessage = message
            }
        }
        guard let answer = lastAnswer?.trimmingCharacters(in: .whitespacesAndNewlines),
            !answer.isEmpty
        else {
            if let failureMessage {
                throw SubscriptionCLIError.unparseable("codex", failureMessage)
            }
            throw SubscriptionCLIError.unparseable("codex", "no agent text in output")
        }
        return LLMCompletion(text: answer, thinking: nil)
    }
}

/// The Codex subscription CLI variant.
///
/// Kept in Core so the exact spawned args, the env sanitisation, and the output
/// parser are unit-tested against a fake `codex` on PATH — the app's adapter is
/// a thin shell over this, exactly like `claude` before it.
public enum CodexSubscriptionCLI {
    /// Headless one-shot that reuses the user's own subscription login.
    ///
    /// `codex exec` runs non-interactively and exits; the prompt, model, sandbox,
    /// and JSON output are explicit. `--sandbox read-only` means the rewrite pass
    /// can never let the model run a mutating shell command, and
    /// `--skip-git-repo-check` lets a dictation work in a non-repo field. `--json`
    /// makes stdout a JSONL event stream the parser turns into one answer.
    ///
    /// `codex exec` has no `--system-prompt` flag, so the system prompt is
    /// prepended to the user message rather than dropped or mangled through a `-c`
    /// TOML override. The keyed `OPENAI_API_KEY`/`OPENAI_ACCESS_TOKEN` credentials
    /// and the `OPENAI_BASE_URL`/`OPENAI_MODEL` overrides are stripped because
    /// codex honours them over its stored login — Wormtongue must not leak a keyed
    /// credential or redirect the endpoint on a subscription run.
    public static let variant = SubscriptionCLIVariant(
        executable: "codex",
        argBuilder: { prompt in
            [
                "exec",
                prompt.system.isEmpty
                    ? prompt.user : "\(prompt.system)\n\n\(prompt.user)",
                "-m", prompt.model,
                "--sandbox", "read-only",
                "--skip-git-repo-check",
                "--json",
            ]
        },
        envSanitizer: { env in
            var e = env
            e.removeValue(forKey: "OPENAI_API_KEY")
            e.removeValue(forKey: "OPENAI_ACCESS_TOKEN")
            e.removeValue(forKey: "OPENAI_BASE_URL")
            e.removeValue(forKey: "OPENAI_MODEL")
            return e
        },
        outputParser: { data in try SubscriptionCLI.parseCodexJSONL(data) },
        primeArguments: ["login", "status"]
    )
}

/// The Claude subscription CLI variant. Kept in Core so the exact spawned args,
/// the env sanitisation, and the output parser are unit-tested against a fake
/// `claude` on PATH — the app's adapter is a thin shell over this.
public enum ClaudeSubscriptionCLI {
    /// Headless one-shot that reuses the user's own OAuth login.
    ///
    /// `-p` runs print mode and exits; the model, system prompt, one-shot cap, and
    /// JSON output are explicit so a rewrite never stalls on an interactive
    /// prompt. `--tools ""` disables the CLI's toolset entirely, so the rewrite
    /// gets a language model, not an agent — nothing can read or write files, run
    /// shell commands, or fetch the network, and therefore nothing needs a
    /// permission prompt (hence no `bypassPermissions`). `ANTHROPIC_API_KEY` /
    /// `ANTHROPIC_AUTH_TOKEN` are stripped because the CLI honours them over its
    /// OAuth token — Wormtongue must not leak a keyed Anthropic credential into a
    /// subscription run.
    public static let variant = SubscriptionCLIVariant(
        executable: "claude",
        argBuilder: { prompt in
            [
                "-p", prompt.user,
                "--model", prompt.model,
                "--system-prompt", prompt.system,
                "--max-turns", "1",
                "--output-format", "json",
                "--tools", "",
            ]
        },
        envSanitizer: { env in
            var e = env
            e.removeValue(forKey: "ANTHROPIC_API_KEY")
            e.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
            return e
        },
        outputParser: { data in try SubscriptionCLI.parseClaudeJSON(data) },
        primeArguments: ["auth", "status"]
    )
}
