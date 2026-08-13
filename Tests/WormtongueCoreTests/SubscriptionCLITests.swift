import Foundation
import Testing

@testable import WormtongueCore

/// Transport-level tests for the subscription-CLI adapters. Instead of a real
/// `claude` (which needs a login and makes paid calls), a fake `claude`
/// executable is written to a temp bin dir and put first on the injected PATH.
/// The fake records its argv and reports whether keyed env leaked, then emits the
/// JSON a real `claude -p` would. This verifies the spawned args, the parsed
/// output, and — critically — that `ANTHROPIC_API_KEY` never spills into the
/// subscription run.
@Suite("Subscription CLI spawn/parse")
struct SubscriptionCLITests {

    /// Writes a fake `claude` and returns an environment that puts its bin dir
    /// first on PATH plus the path of the capture file the fake writes its args to.
    private func makeFakeClaude(
        stdout: String
    ) throws -> (env: [String: String], capturePath: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wormtongue-fake-claude-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let capture = dir.appendingPathComponent("captured.txt")

        // `out` is a dedicated fd so the recorded args never contaminate stdout.
        let body = [
            "#!/bin/sh",
            "{",
            "  echo \"###ARGS###\"",
            "  i=0",
            "  for a in \"$@\"; do i=$((i+1)); echo \"ARG[$i]=$a\"; done",
            "  echo \"###ENV###\"",
            "  if [ -n \"${ANTHROPIC_API_KEY:-}\" ]; then echo \"HAS_KEY=yes\"; else echo \"HAS_KEY=no\"; fi",
            "  if [ -n \"${ANTHROPIC_AUTH_TOKEN:-}\" ]; then echo \"HAS_TOKEN=yes\"; else echo \"HAS_TOKEN=no\"; fi",
            "  echo \"###PWD###\"",
            "  pwd",
            "} > \"$FAKE_CAPTURE_FILE\"",
            "cat <<'FAKE_EOF'",
            stdout,
            "FAKE_EOF",
        ].joined(separator: "\n")
        let scriptURL = bin.appendingPathComponent("claude")
        try Data(body.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        var env: [String: String] = [:]
        env["PATH"] =
            bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        env["FAKE_CAPTURE_FILE"] = capture.path
        return (env, capture.path)
    }

    @Test(
        "A fake claude verifies the spawned args, parses the output, and strips ANTHROPIC_API_KEY")
    func fakeClaudeSpawnsAndParses() async throws {
        let jsonResult = #"{"type":"result","result":"The finished rewrite.","session_id":"s1"}"#
        let (env, capturePath) = try makeFakeClaude(stdout: jsonResult)
        // A keyed Anthropic credential that must NOT reach the subscription run.
        var envWithKey = env
        envWithKey["ANTHROPIC_API_KEY"] = "sk-ant-secret"

        let prompt = LLMPrompt(
            model: "claude-sonnet-4-5", system: "Clean up filler words.",
            user: "This  is  messy wording.", maxTokens: 512, intent: .compose)

        let completion = try await SubscriptionCLI.complete(
            variant: ClaudeSubscriptionCLI.variant, prompt: prompt, environment: envWithKey)

        // The parsed output.
        #expect(completion.text == "The finished rewrite.")

        let captured = try String(contentsOfFile: capturePath, encoding: .utf8)
        // The keyed value was stripped before spawning the CLI.
        #expect(captured.contains("HAS_KEY=no"))
        #expect(captured.contains("HAS_TOKEN=no"))
        // The headless one-shot args: print mode, prompt, model, system, one shot,
        // JSON output, and the toolset disabled so no tool can run.
        #expect(captured.contains("ARG[1]=-p"))
        #expect(captured.contains("This  is  messy wording."))
        #expect(captured.contains("--model"))
        #expect(captured.contains("claude-sonnet-4-5"))
        #expect(captured.contains("--system-prompt"))
        #expect(captured.contains("Clean up filler words."))
        #expect(captured.contains("--max-turns"))
        #expect(captured.contains("--output-format"))
        #expect(captured.contains("json"))
        #expect(captured.contains("--tools"))
        #expect(!captured.contains("bypassPermissions"))
        #expect(!captured.contains("--permission-mode"))
        #expect(!captured.contains("sk-ant-secret"))
    }

    @Test("A missing CLI reports it is not installed")
    func notInstalled() async {
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wormtongue-empty-bin-\(UUID().uuidString)")
        let env = ["PATH": emptyDir.path]
        let prompt = LLMPrompt(
            model: "m", system: "s", user: "u", maxTokens: 16, intent: .compose)
        do {
            _ = try await SubscriptionCLI.complete(
                variant: ClaudeSubscriptionCLI.variant, prompt: prompt, environment: env)
            Issue.record("expected notInstalled error")
        } catch let error as SubscriptionCLIError {
            #expect(error == .notInstalled("claude"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("A non-zero exit surfaces the stderr")
    func nonZeroExit() async throws {
        let script = "#!/bin/sh\necho 'boom' >&2\nexit 7\n"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wormtongue-fail-bin-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let scriptURL = bin.appendingPathComponent("claude")
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let env = ["PATH": bin.path]

        let prompt = LLMPrompt(model: "m", system: "s", user: "u", maxTokens: 16, intent: .compose)
        do {
            _ = try await SubscriptionCLI.complete(
                variant: ClaudeSubscriptionCLI.variant, prompt: prompt, environment: env)
            Issue.record("expected nonZeroExit error")
        } catch let error as SubscriptionCLIError {
            guard case let .nonZeroExit(exec, code, stderr) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(exec == "claude")
            #expect(code == 7)
            #expect(stderr.contains("boom"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Prime spawns the cheap auth-status args and tolerates failure")
    func primeSpawnsAuthStatus() async throws {
        let (env, capturePath) = try makeFakeClaude(
            stdout: #"{"type":"result","result":"not signed in"}"#)
        await SubscriptionCLI.prime(variant: ClaudeSubscriptionCLI.variant, environment: env)
        let captured = try String(contentsOfFile: capturePath, encoding: .utf8)
        #expect(captured.contains("auth"))
        #expect(captured.contains("status"))
    }

    @Test("The child claude is confined to a throwaway temporary working directory")
    func childWorkDirConfined() async throws {
        let (env, capturePath) = try makeFakeClaude(stdout: #"{"type":"result","result":"ok"}"#)
        let prompt = LLMPrompt(
            model: "m", system: "s", user: "u", maxTokens: 16, intent: .compose)
        _ = try await SubscriptionCLI.complete(
            variant: ClaudeSubscriptionCLI.variant, prompt: prompt, environment: env)
        let captured = try String(contentsOfFile: capturePath, encoding: .utf8)
        // The PWD line is the first capture line that does not start with ###.
        let childCwd = captured.split(separator: "\n")
            .filter { !$0.hasPrefix("###") && $0.hasPrefix("/") }
            .first.map(String.init)
        #expect(childCwd != nil)
        // `pwd` reports the symlink-resolved path (/private/var/…), so normalise
        // both sides the same way before comparing against the temp root.
        func normalised(_ p: String) -> String {
            p.hasPrefix("/private/var/") ? String(p.dropFirst("/private".count)) : p
        }
        let tempRoot = FileManager.default.temporaryDirectory.path
        let hostCwd = FileManager.default.currentDirectoryPath
        #expect(normalised(childCwd!).hasPrefix(tempRoot))
        #expect(childCwd!.contains("wormtongue-subscription-"))
        #expect(normalised(childCwd!) != normalised(hostCwd))
        // And the throwaway directory is removed once the process exits.
        #expect(FileManager.default.fileExists(atPath: childCwd!) == false)
    }

    @Test("Claude JSON parsing skips thinking but keeps the text blocks")
    func parseSkipsThinking() throws {
        // Real `claude --output-format json` emits one JSON object per line, so the
        // assistant block must sit on a single line for the line-based parser.
        let data = Data(
            ("""
            {"type":"assistant","message":{"content":[{"type":"thinking","thinking":"I should just rewrite this."},{"type":"text","text":"Cleaned up."}]}}
            """
            .trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n"
                + #"{"type":"result","result":"Cleaned up.","session_id":"s"}"#).utf8)
        let completion = try SubscriptionCLI.parseClaudeJSON(data)
        #expect(completion.text == "Cleaned up.")
        #expect(completion.thinking == "I should just rewrite this.")
    }

    @Test("Claude JSON with no text response fails rather than guessing")
    func parseEmptyFails() {
        let data = Data(#"{"type":"result","result":"","session_id":"s"}"#.utf8)
        #expect(throws: SubscriptionCLIError.self) {
            _ = try SubscriptionCLI.parseClaudeJSON(data)
        }
    }

    // MARK: - Codex (ticket #6)

    /// Writes a fake `codex` and returns an environment that puts its bin dir first
    /// on PATH plus the path of the capture file the fake writes its args to.
    private func makeFakeCodex(
        stdout: String
    ) throws -> (env: [String: String], capturePath: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wormtongue-fake-codex-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let capture = dir.appendingPathComponent("captured.txt")

        let body = [
            "#!/bin/sh",
            "{",
            "  echo \"###ARGS###\"",
            "  i=0",
            "  for a in \"$@\"; do i=$((i+1)); echo \"ARG[$i]=$a\"; done",
            "  echo \"###ENV###\"",
            "  if [ -n \"${OPENAI_API_KEY:-}\" ]; then echo \"HAS_API_KEY=yes\"; else echo \"HAS_API_KEY=no\"; fi",
            "  if [ -n \"${OPENAI_ACCESS_TOKEN:-}\" ]; then echo \"HAS_ACCESS_TOKEN=yes\"; else echo \"HAS_ACCESS_TOKEN=no\"; fi",
            "  if [ -n \"${OPENAI_BASE_URL:-}\" ]; then echo \"HAS_BASE_URL=yes\"; else echo \"HAS_BASE_URL=no\"; fi",
            "  if [ -n \"${OPENAI_MODEL:-}\" ]; then echo \"HAS_MODEL=yes\"; else echo \"HAS_MODEL=no\"; fi",
            "} > \"$FAKE_CAPTURE_FILE\"",
            "cat <<'FAKE_EOF'",
            stdout,
            "FAKE_EOF",
        ].joined(separator: "\n")
        let scriptURL = bin.appendingPathComponent("codex")
        try Data(body.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        var env: [String: String] = [:]
        env["PATH"] =
            bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        env["FAKE_CAPTURE_FILE"] = capture.path
        return (env, capture.path)
    }

    @Test("A fake codex verifies the spawned exec args, parses the JSONL, and strips keyed env")
    func fakeCodexSpawnsAndParses() async throws {
        // A real `codex exec --json` stream: thread/turn bookkeeping, tool
        // chatter, then the final agent_message carrying the answer.
        let stream = [
            #"{"type":"thread.started","thread_id":"t1"}"#,
            #"{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"ls"}}"#,
            #"{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"The finished rewrite."}}"#,
            #"{"type":"turn.completed","usage":{"output_tokens":12}}"#,
        ].joined(separator: "\n")
        let (env, capturePath) = try makeFakeCodex(stdout: stream)
        // Keyed OpenAI credentials and endpoint/model overrides that MUST NOT reach
        // the subscription run.
        var envWithKey = env
        envWithKey["OPENAI_API_KEY"] = "sk-openai-secret"
        envWithKey["OPENAI_ACCESS_TOKEN"] = "access-token-secret"
        envWithKey["OPENAI_BASE_URL"] = "https://gateway.example.com/v1"
        envWithKey["OPENAI_MODEL"] = "some-rival-model"

        let prompt = LLMPrompt(
            model: "gpt-5-codex", system: "Clean up filler words.",
            user: "This  is  messy wording.", maxTokens: 512, intent: .compose)

        let completion = try await SubscriptionCLI.complete(
            variant: CodexSubscriptionCLI.variant, prompt: prompt, environment: envWithKey)

        // The parsed final answer.
        #expect(completion.text == "The finished rewrite.")
        #expect(completion.thinking == nil)

        let captured = try String(contentsOfFile: capturePath, encoding: .utf8)
        for flag in ["HAS_API_KEY", "HAS_ACCESS_TOKEN", "HAS_BASE_URL", "HAS_MODEL"] {
            #expect(captured.contains("\(flag)=no"), "\(flag) leaked: \(captured)")
        }
        // The headless one-shot: exec subcommand, prompt (system prepended), model,
        // read-only sandbox, no git check, JSONL output.
        #expect(captured.contains("ARG[1]=exec"))
        #expect(captured.contains("Clean up filler words."))
        #expect(captured.contains("This  is  messy wording."))
        #expect(captured.contains("-m"))
        #expect(captured.contains("gpt-5-codex"))
        #expect(captured.contains("--sandbox"))
        #expect(captured.contains("read-only"))
        #expect(captured.contains("--skip-git-repo-check"))
        #expect(captured.contains("--json"))
        #expect(!captured.contains("sk-openai-secret"))
        #expect(!captured.contains("access-token-secret"))
        #expect(!captured.contains("gateway.example.com"))
        #expect(!captured.contains("some-rival-model"))
    }

    @Test("Codex prime spawns the cheap login-status args")
    func codexPrimeSpawnsLoginStatus() async throws {
        let (env, capturePath) = try makeFakeCodex(stdout: "")
        await SubscriptionCLI.prime(variant: CodexSubscriptionCLI.variant, environment: env)
        let captured = try String(contentsOfFile: capturePath, encoding: .utf8)
        #expect(captured.contains("login"))
        #expect(captured.contains("status"))
    }

    @Test("Codex JSONL parsing keeps the last agent_message and skips chatter")
    func parseCodexJsonl() throws {
        let data = Data(
            [
                #"{"type":"thread.started","thread_id":"t1"}"#,
                #"{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"ls"}}"#,
                #"{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"Draft answer."}}"#,
                #"{"type":"item.completed","item":{"id":"i3","type":"agent_message_commentary","text":"Still thinking…"}}"#,
                #"{"type":"item.completed","item":{"id":"i4","type":"agent_message","text":"The finished rewrite."}}"#,
            ].joined(separator: "\n").utf8)
        let completion = try SubscriptionCLI.parseCodexJSONL(data)
        #expect(completion.text == "The finished rewrite.")
    }

    @Test("Codex JSONL with a failed turn surfaces the reason rather than guessing")
    func parseCodexTurnFailed() {
        let data = Data(
            [
                #"{"type":"turn.started"}"#,
                #"{"type":"error","message":"Model metadata missing"}"#,
                #"{"type":"turn.failed","error":{"message":"The model is not supported with a ChatGPT account"}}"#,
            ].joined(separator: "\n").utf8)
        #expect(throws: SubscriptionCLIError.self) {
            _ = try SubscriptionCLI.parseCodexJSONL(data)
        }
    }

    @Test("Codex JSONL with no agent message fails rather than guessing")
    func parseCodexEmptyFails() {
        let data = Data(#"{"type":"thread.started","thread_id":"t"}"#.utf8)
        #expect(throws: SubscriptionCLIError.self) {
            _ = try SubscriptionCLI.parseCodexJSONL(data)
        }
    }

    @Test("Codex JSONL surfaces a terminal top-level error event as the reason")
    func parseCodexTopLevelError() {
        let data = Data(
            [
                #"{"type":"thread.started","thread_id":"t"}"#,
                #"{"type":"error","message":"The model is not supported with a ChatGPT account"}"#,
            ].joined(separator: "\n").utf8)
        #expect(throws: SubscriptionCLIError.self) {
            _ = try SubscriptionCLI.parseCodexJSONL(data)
        }
    }

    @Test("Codex JSONL ignores a transient error notice when a real answer arrives")
    func parseCodexTransientErrorDoesNotVetoAnswer() throws {
        let data = Data(
            [
                #"{"type":"error","message":"reconnect throttled, retried"}"#,
                #"{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"The finished rewrite."}}"#,
            ].joined(separator: "\n").utf8)
        let completion = try SubscriptionCLI.parseCodexJSONL(data)
        #expect(completion.text == "The finished rewrite.")
    }
}
