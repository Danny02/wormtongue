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
        env["PATH"] = bin.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        env["FAKE_CAPTURE_FILE"] = capture.path
        return (env, capture.path)
    }

    @Test("A fake claude verifies the spawned args, parses the output, and strips ANTHROPIC_API_KEY")
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
        // JSON output, bypassed permission prompts.
        #expect(captured.contains("ARG[1]=-p"))
        #expect(captured.contains("This  is  messy wording."))
        #expect(captured.contains("--model"))
        #expect(captured.contains("claude-sonnet-4-5"))
        #expect(captured.contains("--system-prompt"))
        #expect(captured.contains("Clean up filler words."))
        #expect(captured.contains("--max-turns"))
        #expect(captured.contains("--output-format"))
        #expect(captured.contains("json"))
        #expect(captured.contains("--permission-mode"))
        #expect(captured.contains("bypassPermissions"))
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
        let (env, capturePath) = try makeFakeClaude(stdout: #"{"type":"result","result":"not signed in"}"#)
        await SubscriptionCLI.prime(variant: ClaudeSubscriptionCLI.variant, environment: env)
        let captured = try String(contentsOfFile: capturePath, encoding: .utf8)
        #expect(captured.contains("auth"))
        #expect(captured.contains("status"))
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
}
