// Demo driver: simulates a complete-ticket run against the dashboard library
// so the frontend can be exercised without dispatching real agents.
// Run: npx tsx .sandcastle/dashboard/demo.ts   (serves on :4180, Ctrl-C to stop)
import { createDashboard } from "./dashboard.ts";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const dash = await createDashboard({
  title: "complete #12 (demo)",
  issue: {
    number: 12,
    title: "Dictionary entries cannot say what a term is misheard as",
    url: "https://github.com/Danny02/wormtongue/issues/12",
  },
  port: 4180,
  open: false,
  keepAliveMs: 10 * 60_000,
});

const dBaseline = dash.command("baseline gate", { icon: "✓", sub: "./Scripts/check.sh on origin/main" });
const dLoop = dash.retryLoop("implement · gate · review", { max: 3 });
const dImpl = dLoop.ai("implement", { icon: "✦", sub: "deepseek-v4-flash" });
const dRebase = dLoop.command("rebase", { icon: "⇄", sub: "onto origin/main" });
const dConflicts = dLoop.ai("resolve conflicts", { icon: "⚡", optional: true });
const dCheck = dLoop.command("check.sh", { icon: "✓" });
const dReview = dLoop.ai("review", { icon: "★", sub: "claude-opus" });
const dVerify = dash.ai("verify steps", { icon: "☰", sub: "only when a PR needs them", optional: true });
const dRoute = dash.command("route to main", { icon: "⤳", sub: "squash-merge · or open PR" });

console.log(`demo dashboard on ${dash.url}`);

// A real pi JSONL protocol line, as sandcastle forwards them in `raw` events.
// The lib must swallow it, surface the thinking, and harvest the USD.
const piTurnEnd = (thinking: string, tokens: number, usd: number) =>
  JSON.stringify({
    type: "turn_end",
    message: {
      role: "assistant",
      content: [{ type: "thinking", thinking }],
      model: "deepseek/deepseek-v4-flash-0731",
      usage: { totalTokens: tokens, cost: { total: usd } },
    },
  });

// Feed raw lines through the ai step's logging callback, like sandcastle does.
const implLog = dImpl.logging("demo-implement");
const reviewLog = dReview.logging("demo-review");

dBaseline.start();
const b = await dBaseline.exec("bash", ["-c", "printf '\\033[1m== WormtongueCore builds \\033[0m\\n'; sleep 0.4; printf '\\033[32mBuild complete.\\033[0m (2.1s)\\n'; printf '\\033[1;32mAll 41 tests passed\\033[0m\\n'; printf '\\033[33mwarning:\\033[0m 1 deprecated API\\n'"]);
dBaseline.ok(b.ok ? "green" : "red");

// attempt 1 — fails the gate
dLoop.attempt();
dImpl.start("fresh session");
implLog.onAgentStreamEvent({ type: "text", message: "I'll start by reading the ticket and the repository structure." });
implLog.onAgentStreamEvent({ type: "raw", line: piTurnEnd("Let me start by understanding the ticket. I need to look at the issue first.", 11043, 0.000861572) });
await sleep(700);
implLog.onAgentStreamEvent({ type: "toolCall", name: "bash", formattedArgs: "gh issue view 12 --comments" });
await sleep(700);
implLog.onAgentStreamEvent({ type: "toolCall", name: "bash", formattedArgs: "swift test --filter ConfigTests" });
implLog.onAgentStreamEvent({ type: "raw", line: piTurnEnd("The tests cover parsing but not the misheard-as field. Writing the failing test first.", 48211, 0.003422) });
implLog.onAgentStreamEvent({ type: "text", message: "Now writing the failing tests first (red), then the parser change." });
await sleep(800);
dImpl.ok("done");
dRebase.start();
const r1 = await dRebase.exec("bash", ["-c", "echo 'Current branch ticket-12 is up to date.'"]);
dRebase.ok(r1.ok ? "ok" : "conflicted");
dConflicts.skip("no conflicts");
dCheck.start();
const c1 = await dCheck.exec("bash", ["-c", "echo 'swift build …'; sleep 0.5; echo 'swift-format lint --strict'; echo 'Sources/WormtongueCore/Config.swift:41: warning: indentation'; echo '4 violations'; exit 1"]);
dCheck.fail("failed", c1.output.split("\n").slice(-3).join("\n"));
await sleep(1000);

// attempt 2 — resumes, lands
dLoop.attempt();
dImpl.start("resuming session");
implLog.onAgentStreamEvent({ type: "raw", line: piTurnEnd("The gate flagged formatting only. Run swift-format over the touched files and re-commit.", 21400, 0.001511) });
implLog.onAgentStreamEvent({ type: "text", message: "The gate flagged formatting. Running swift-format and re-committing." });
await sleep(600);
implLog.onAgentStreamEvent({ type: "toolCall", name: "bash", formattedArgs: "swift-format format -i --recursive Sources Tests" });
await sleep(700);
dImpl.ok("done");
dash.cost("openrouter/deepseek/deepseek-v4-flash-0731", { runs: 2, totalTokens: 231_882 });
dRebase.start();
await dRebase.exec("bash", ["-c", "echo 'Successfully rebased and updated refs/heads/ticket-12.'"]);
dRebase.ok();
dConflicts.skip("no conflicts");
dCheck.start();
const c2 = await dCheck.exec("bash", ["-c", "echo 'swift build …'; sleep 0.5; echo 'All 43 tests passed'; echo 'lint clean'"]);
dCheck.ok(c2.ok ? "green" : "failed");
dReview.start();
reviewLog.onAgentStreamEvent({ type: "text", message: "Reviewing the diff against the ticket's acceptance criteria…" });
await sleep(1100);
dReview.ok("approved");
dash.cost("claude-bridge/claude-opus-5", { runs: 1, totalTokens: 88_410 });

dRoute.start();
dVerify.skip("auto-merged");
await sleep(400);
await dRoute.exec("bash", ["-c", "echo 'To github.com:Danny02/wormtongue.git'; echo '   c0346d0..f11a2e9  HEAD -> main'"]);
dRoute.ok("squash-merged to main");
dash.done({
  headline: "Squash-merged to main — closes #12",
  kind: "merged",
  link: "https://github.com/Danny02/wormtongue/issues/12",
  needsHuman: false,
  facts: [
    { label: "branch", value: "ticket-12" },
    { label: "commits", value: "1" },
    { label: "gate", value: "green — everything it touched is observed" },
  ],
});