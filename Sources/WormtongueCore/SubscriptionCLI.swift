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
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(executable).path
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
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
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
        let thinking = thinkings.isEmpty
            ? nil
            : thinkings.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return LLMCompletion(text: joined, thinking: thinking)
    }
}

/// The Claude subscription CLI variant. Kept in Core so the exact spawned args,
/// the env sanitisation, and the output parser are unit-tested against a fake
/// `claude` on PATH — the app's adapter is a thin shell over this.
public enum ClaudeSubscriptionCLI {
    /// Headless one-shot that reuses the user's own OAuth login.
    ///
    /// `-p` runs print mode and exits; the model, system prompt, one-shot cap, JSON
    /// output, and bypassed permission prompts are all explicit so a rewrite never
    /// stalls on an interactive prompt. `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN`
    /// are stripped because the CLI honours them over its OAuth token — Wormtongue
    /// must not leak a keyed Anthropic credential into a subscription run.
    public static let variant = SubscriptionCLIVariant(
        executable: "claude",
        argBuilder: { prompt in
            [
                "-p", prompt.user,
                "--model", prompt.model,
                "--system-prompt", prompt.system,
                "--max-turns", "1",
                "--output-format", "json",
                "--permission-mode", "bypassPermissions",
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
