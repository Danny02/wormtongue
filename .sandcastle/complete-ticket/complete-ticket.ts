import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import * as path from "node:path";
import * as sandcastle from "@ai-hero/sandcastle";
import { noSandbox } from "@ai-hero/sandcastle/sandboxes/no-sandbox";
import { createDashboard, type Step } from "../dashboard/dashboard.ts";

const TICKET = required("TICKET");
const BASE = process.env.BASE_BRANCH ?? "main";
const IMPL_MODEL =
  process.env.IMPL_MODEL ?? "openrouter/deepseek/deepseek-v4-flash-0731";
const REVIEW_MODEL = process.env.REVIEW_MODEL ?? "claude-bridge/claude-opus-5";
const MAX_RETRIES = Number(process.env.MAX_RETRIES ?? "2");
const DRY_RUN = process.env.DRY_RUN === "1";

// Isolated pi config. Without this the worker inherits ~/.pi/agent: the global
// AGENTS.md orchestration policy, every MCP server, and ask_user_question —
// which has no answerer here and would hang until sandcastle's idle timeout.
const PI_HOME = path.resolve(import.meta.dirname, "..", "pi-home");
const LOG_DIR = path.resolve(import.meta.dirname, "..", "logs");
const HERE = import.meta.dirname;

const ticket = JSON.parse(
  gh(["issue", "view", TICKET, "--json", "number,title,url,labels"]),
) as { number: number; title: string; url: string; labels: { name: string }[] };

const ticketContext = gh(["issue", "view", TICKET, "--comments"]);
const branch = `ticket-${ticket.number}`;
const commitType = ticket.labels.some((l) => l.name === "bug") ? "fix" : "feat";

// The dashboard: this workflow defines a copy of its structure with building
// blocks — that definition IS the dashboard graph, known before anything
// runs. Flow control stays below, imperative; the run just reports into the
// blocks. If the server cannot bind, the blocks degrade to no-ops (logging
// still writes files and tails stdout), so nothing here is conditional.
const dash = await createDashboard({
  title: `complete #${ticket.number}`,
  issue: { number: ticket.number, title: ticket.title, url: ticket.url },
  logDir: LOG_DIR,
  open: true,
});
const dBaseline = dash.command("baseline gate", { icon: "✓", sub: `./Scripts/check.sh on origin/${BASE}` });
const dLoop = dash.retryLoop("implement · gate · review", { max: MAX_RETRIES + 1 });
const dImpl = dLoop.ai("implement", { icon: "✦", sub: IMPL_MODEL });
const dRebase = dLoop.command("rebase", { icon: "⇄", sub: `onto origin/${BASE}` });
const dConflicts = dLoop.ai("resolve conflicts", { icon: "⚡", optional: true });
const dCheck = dLoop.command("check.sh", { icon: "✓" });
const dReview = dLoop.ai("review", { icon: "★", sub: REVIEW_MODEL });
const dVerify = dash.ai("verify steps", { icon: "☰", sub: "only when a PR needs them", optional: true });
const dRoute = dash.command("route to main", { icon: "⤳", sub: "squash-merge · or open PR" });

// Not git() — that one runs in the worktree, which does not exist yet.
execFileSync("git", ["fetch", "origin", BASE], { stdio: "inherit" });

console.log(`#${ticket.number} ${ticket.title}`);
console.log(`  ${branch} off origin/${BASE}, up to ${MAX_RETRIES} retries`);
if (DRY_RUN) console.log("  DRY_RUN: nothing will be pushed");

const wt = await sandcastle.createWorktree({
  branchStrategy: { type: "branch", branch, baseBranch: `origin/${BASE}` },
});
const cwd = wt.worktreePath;

// A long-lived sandbox, rather than wt.run(): only SandboxRunResult carries
// resume(), and retrying inside the implementer's own session is worth far
// more than the isolation a container would add — which macOS Swift rules out
// anyway. noSandbox() runs everything on the host.
//
// The agent config dir goes on the *sandbox*, not on the agent. createSandbox
// starts the sandbox before it knows which agent will run in it, so it passes
// `agentProviderEnv: {}` and drops PiOptions.env on the floor. Set it here and
// the worker silently inherits ~/.pi/agent instead: global AGENTS.md, every
// MCP server, and sessions written somewhere resume() will never find them.
const box = await wt.createSandbox({
  sandbox: noSandbox({ env: { PI_CODING_AGENT_DIR: PI_HOME } }),
});

// sandcastle reuses an existing worktree as-is. If an interrupted run left
// commits on the branch, everything below measures that work instead of the
// base branch — and the implementer would resume on top of code it has no
// memory of writing, because its session died with the crash. Refuse rather
// than guess, and leave the work for inspection.
const leftoverCommits = commitsAhead();
if (leftoverCommits > 0 || git(["status", "--porcelain"])) {
  const rel = path.relative(process.cwd(), cwd);
  console.error(
    `\nThe worktree at ${cwd} is not pristine: ${leftoverCommits} commit(s) ` +
      `ahead of origin/${BASE}.\n\nThat is work from an earlier run. Inspect ` +
      `it, then clear it to start clean:\n\n` +
      `  git -C ${rel} log origin/${BASE}..HEAD\n` +
      `  git worktree remove --force ${rel}\n` +
      `  git branch -D ${branch}\n`,
  );
  await dash.fail("worktree not pristine — leftover work from an earlier run");
  process.exit(1);
}

// Prove the gate is green before an agent touches anything. A base branch
// that already fails check.sh sets an impossible task: every attempt is judged
// against a red baseline, the agent is handed failures it did not cause, and
// three rounds burn before the workflow parks a ticket that was never the
// problem.
console.log("\nbaseline: is the gate green before we start?");
dBaseline.start();
const baseline = await gate(dBaseline);
if (!baseline.ok) {
  console.error(
    `\nThe gate already fails on origin/${BASE}, before any agent has run.\n` +
      `Fix the base branch first — nothing an agent does here can go green.\n\n` +
      tail(baseline.output, 40),
  );
  dBaseline.fail("red on origin/" + BASE, tail(baseline.output, 20));
  await dash.fail(`check.sh already fails on origin/${BASE}`);
  await discard();
  process.exit(1);
}
console.log("  baseline green");
dBaseline.ok("green");

// Spend lives above the retry loop on purpose: tracked() is a hoisted
// function and may run while module execution is still inside the loop — a
// `const` declared below it would still be in the temporal dead zone.
const spend = new Map<
  string,
  { runs: number; input: number; output: number; cacheRead: number; cacheWrite: number }
>();

let implRun: sandcastle.SandboxRunResult | undefined;
let feedback: string | undefined;
let landed = false;

for (let attempt = 1; attempt <= MAX_RETRIES + 1; attempt++) {
  console.log(`\n--- attempt ${attempt}/${MAX_RETRIES + 1} ---`);

  dLoop.attempt();
  dImpl.start(implRun ? "resuming session" : "fresh session");

  implRun = implRun
    ? await resumeImplementer(implRun, attempt)
    : await tracked(
        IMPL_MODEL,
        box.run({
          name: `implement-#${ticket.number}`,
          agent: pi(IMPL_MODEL),
          logging: dImpl.logging(`implement-${ticket.number}`),
          promptFile: path.join(HERE, "implement.md"),
          promptArgs: promptArgs(),
        }),
      );
  dImpl.ok("done");

  if (headBranch() !== branch) {
    throw new Error(
      `Agent left the worktree on '${headBranch()}', expected '${branch}'. ` +
        `Worktree kept at ${cwd}.`,
    );
  }

  if (commitsAhead() === 0) {
    // A clean tree and no commits is not a slip — it means the agent looked at
    // the ticket and concluded there is nothing to change. Retrying only buys
    // the same conclusion at full price.
    if (!git(["status", "--porcelain"])) {
      dImpl.fail("no change made");
      await handOff(
        "The agent made no change",
        "It ran to completion and left the working tree clean, so it decided " +
          "this ticket needs no code change. The issue may already be fixed, " +
          "or scoped wrongly. Its reasoning:\n\n" +
          "```\n" + tail(implRun.stdout) + "\n```",
      );
    }
    feedback =
      "You edited files but never committed them. Commit your work to the " +
      "branch you are on.";
    continue;
  }

  // Rebase before testing: verifying pre-rebase code proves things about code
  // that will never exist on the base branch.
  execFileSync("git", ["fetch", "origin", BASE], { cwd, stdio: "pipe" });
  dRebase.start();
  if (!(await rebase())) {
    console.log("  rebase conflicted, dispatching conflict resolver");
    dRebase.fail("conflicted");
    dConflicts.start();
    await tracked(
      IMPL_MODEL,
      box.run({
        name: `conflicts-#${ticket.number}-${attempt}`,
        agent: pi(IMPL_MODEL),
        logging: dConflicts.logging(`conflicts-${ticket.number}-${attempt}`),
        promptFile: path.join(HERE, "conflicts.md"),
        promptArgs: promptArgs(),
      }),
    );
    if (rebaseInProgress()) {
      git(["rebase", "--abort"]);
      dConflicts.fail("unresolved — rebase aborted");
      feedback = `The rebase onto origin/${BASE} conflicted and was not resolved.`;
      continue;
    }
    dConflicts.ok("resolved");
  } else {
    dRebase.ok();
    dConflicts.skip("no conflicts");
  }

  dCheck.start();
  const check = await gate(dCheck);
  if (!check.ok) {
    console.log("  check.sh FAILED");
    dCheck.fail("failed", tail(check.output, 20));
    feedback =
      `\`./Scripts/check.sh\` fails on your work after rebasing onto ` +
      `origin/${BASE}:\n\n${tail(check.output)}`;
    continue;
  }
  console.log("  check.sh green");
  dCheck.ok("green");

  dReview.start();
  const review = await reviewPass(attempt);
  if (review.verdict !== "approve") {
    console.log(`  review REJECTED (${review.objections.length} objection(s))`);
    dReview.fail(`${review.objections.length} objection(s)`);
    feedback =
      `A reviewer rejected your work:\n\n` +
      review.objections.map((o) => `- ${o}`).join("\n");
    continue;
  }
  console.log("  review approved");
  dReview.ok("approved");

  landed = true;
  break;
}

if (!landed) {
  dLoop.exhausted(`no landing after ${MAX_RETRIES + 1} attempts`);
  await handOff(
    `The agent could not land this ticket after ${MAX_RETRIES + 1} attempts`,
    "Last failure:\n\n```\n" + tail(feedback ?? "unknown") + "\n```",
  );
}

// Routing is code, never the agent's judgement: an implementer asked whether
// its own work needs human testing has every reason to say no.
//
// Ask what the gate cannot observe, not what is outside Core. check.sh runs
// Core through its tests, parses and lints everything, and even parses
// config.example.json via a test — so a change there is proven. The app target
// is the sole exception: it compiles, and then nothing watches it run.
const changed = git(["diff", "--name-only", `origin/${BASE}...HEAD`])
  .split("\n")
  .filter(Boolean);
const unobserved = changed.filter((f) => f.startsWith("Sources/Wormtongue/"));

dRoute.start();
if (unobserved.length === 0) {
  dVerify.skip("auto-merged");
  await squashMerge();
} else {
  await openPullRequest(unobserved);
}

async function squashMerge(): Promise<void> {
  const subjects = git(["log", "--format=%s", `origin/${BASE}..HEAD`])
    .split("\n")
    .filter(Boolean);
  const message =
    `${commitType}: ${ticket.title}\n\n` +
    `${subjects.map((s) => `- ${s}`).join("\n")}\n\n` +
    `Fixes #${ticket.number}\n`;

  git(["switch", "--detach", `origin/${BASE}`]);
  git(["merge", "--squash", branch]);
  execFileSync("git", ["commit", "-F", "-"], { cwd, input: message });

  if (DRY_RUN) {
    console.log(`\nDRY_RUN: would push this to ${BASE}:\n\n${message}`);
    console.log(`Worktree kept at ${cwd}`);
    dRoute.ok("DRY_RUN");
    dash.done({
      headline: `Dry run — would squash-merge to ${BASE}`,
      kind: "dry-run",
      link: ticket.url,
      facts: [
        { label: "branch", value: branch },
        { label: "commits", value: String(subjects.length) },
        { label: "worktree", value: cwd },
      ],
    });
    return;
  }

  git(["push", "origin", `HEAD:${BASE}`]);
  console.log(`\nMerged to ${BASE}. #${ticket.number} closes automatically.`);
  dRoute.ok(`squash-merged to ${BASE}`);
  await discard();
  dash.done({
    headline: `Squash-merged to ${BASE} — closes #${ticket.number}`,
    kind: "merged",
    link: ticket.url,
    needsHuman: false,
    facts: [
      { label: "branch", value: branch },
      { label: "commits", value: String(subjects.length) },
      { label: "gate", value: "green — everything it touched is observed" },
    ],
  });
}

async function openPullRequest(unobservedFiles: string[]): Promise<void> {
  console.log(
    `\n${unobservedFiles.length} file(s) outside Core/Tests — needs a human`,
  );

  dVerify.start();
  const steps = await tracked(
    IMPL_MODEL,
    box.run({
      name: `verify-steps-#${ticket.number}`,
      agent: pi(IMPL_MODEL),
      logging: dVerify.logging(`verify-steps-${ticket.number}`),
      promptFile: path.join(HERE, "verify-steps.md"),
      promptArgs: { ...promptArgs(), FILES: unobservedFiles.join("\n") },
    }),
  );
  dVerify.ok("steps written");
  const extracted = /<verify>([\s\S]*?)<\/verify>/.exec(steps.stdout)?.[1]?.trim();

  const body =
    `Fixes #${ticket.number}\n\n` +
    `## Verify by hand\n\n${extracted ?? "_The agent produced no steps._"}\n\n` +
    `## Why this is not auto-merged\n\n` +
    `Touches the app target, which \`./Scripts/check.sh\` compiles but never ` +
    `runs, so nothing here is proven by the gate:\n\n` +
    unobservedFiles.map((f) => `- \`${f}\``).join("\n") +
    "\n";

  if (DRY_RUN) {
    console.log(`\nDRY_RUN: would open a PR with:\n\n${body}`);
    console.log(`Worktree kept at ${cwd}`);
    dRoute.ok("DRY_RUN");
    dash.done({
      headline: "Dry run — would open a pull request",
      kind: "dry-run",
      link: ticket.url,
      needsHuman: true,
      facts: [
        { label: "branch", value: branch },
        { label: "needs review", value: `${unobservedFiles.length} file(s) the gate cannot observe` },
        { label: "worktree", value: cwd },
      ],
    });
    return;
  }

  git(["push", "-u", "origin", branch]);
  const url = gh([
    "pr", "create",
    "--base", BASE,
    "--head", branch,
    "--title", `${commitType}: ${ticket.title}`,
    "--body", body,
  ]).trim();
  console.log(`\nPR opened: ${url}`);
  dRoute.ok("PR opened — needs a human");
  await discard();
  dash.done({
    headline: "Pull request opened — needs a human",
    kind: "pr",
    link: url,
    needsHuman: true,
    facts: [
      { label: "branch", value: branch },
      { label: "why not merged", value: `${unobservedFiles.length} file(s) compiled but never run by the gate` },
      ...unobservedFiles.slice(0, 5).map((f) => ({ label: "unobserved", value: f })),
    ],
  });
}

async function resumeImplementer(
  previous: sandcastle.SandboxRunResult,
  attempt: number,
): Promise<sandcastle.SandboxRunResult> {
  if (!previous.resume) {
    throw new Error(
      "The agent provider captured no session, so the implementer cannot be " +
        "resumed. Check that PI_CODING_AGENT_DIR and sessionStorage agree.",
    );
  }
  // resume() takes an inline prompt, and sandcastle substitutes {{KEY}} only
  // for promptFile — passing promptArgs alongside an inline prompt is a hard
  // error. Do the substitution here instead.
  const prompt = fill(readFileSync(path.join(HERE, "fix.md"), "utf8"), {
    ...promptArgs(),
    FEEDBACK: feedback ?? "",
  });

  return tracked(
    IMPL_MODEL,
    previous.resume(prompt, {
      name: `fix-#${ticket.number}-${attempt}`,
      logging: dImpl.logging(`fix-${ticket.number}-${attempt}`),
    }),
  );
}

// box.close() tears down the sandbox but leaves the worktree on disk, despite
// documenting otherwise — only wt.close() removes it. Closing just the sandbox
// silently accumulates a worktree and a branch per run, and the next run then
// refuses to start because the directory is already there.
async function discard(): Promise<void> {
  await box.close();
  const result = await wt.close();
  if (result.preservedWorktreePath) {
    console.log(`\nWorktree preserved (uncommitted changes): ${result.preservedWorktreePath}`);
  }
}

// Spend is the one number that decides whether a workflow is worth running,
// and it is invisible while a run is in flight. Report it per model: the two
// tiers differ by orders of magnitude, and a single line of totals hides which
// tier is actually costing anything.
async function tracked(
  model: string,
  run: Promise<sandcastle.SandboxRunResult>,
): Promise<sandcastle.SandboxRunResult> {
  const result = await run;
  const acc = spend.get(model) ?? {
    runs: 0,
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
  };
  acc.runs += 1;
  for (const iteration of result.iterations) {
    const u = iteration.usage;
    if (!u) continue;
    acc.input += u.inputTokens;
    acc.output += u.outputTokens;
    acc.cacheRead += u.cacheReadInputTokens;
    acc.cacheWrite += u.cacheCreationInputTokens;
  }
  spend.set(model, acc);
  dash.cost(model, {
    runs: acc.runs,
    totalTokens: acc.input + acc.output + acc.cacheRead + acc.cacheWrite,
  });
  return result;
}

// On exit, so a parked or crashed run still reports what it spent getting
// there — those are the runs whose cost you most want to see.
process.on("exit", () => {
  if (spend.size === 0) return;
  const n = (v: number) => v.toLocaleString("en-US");
  console.log("\ntokens by model");
  for (const [model, u] of spend) {
    const total = u.input + u.output + u.cacheRead + u.cacheWrite;
    console.log(`  ${model}  — ${u.runs} run(s), ${n(total)} total`);
    console.log(
      `    in ${n(u.input)}  out ${n(u.output)}  ` +
        `cache read ${n(u.cacheRead)}  cache write ${n(u.cacheWrite)}`,
    );
  }
});

function fill(template: string, args: Record<string, string>): string {
  return template.replace(/\{\{(\w+)\}\}/g, (whole, key: string) => {
    if (!(key in args)) throw new Error(`fix.md references unknown {{${key}}}`);
    return args[key]!;
  });
}

async function reviewPass(
  attempt: number,
): Promise<{ verdict: string; objections: string[] }> {
  const result = await tracked(
    REVIEW_MODEL,
    box.run({
      name: `review-#${ticket.number}-${attempt}`,
      agent: pi(REVIEW_MODEL),
      logging: dReview.logging(`review-${ticket.number}-${attempt}`),
      promptFile: path.join(HERE, "review.md"),
      promptArgs: { ...promptArgs(), DIFF_RANGE: `origin/${BASE}...HEAD` },
    }),
  );

  const match = /<review>([\s\S]*?)<\/review>/.exec(result.stdout);
  if (!match) {
    return { verdict: "reject", objections: ["The reviewer emitted no verdict."] };
  }
  try {
    const parsed = JSON.parse(match[1]!) as {
      verdict: string;
      objections?: string[];
    };
    return { verdict: parsed.verdict, objections: parsed.objections ?? [] };
  } catch {
    return {
      verdict: "reject",
      objections: ["The reviewer emitted invalid JSON."],
    };
  }
}

function pi(model: string): sandcastle.AgentProvider {
  return sandcastle.pi(model, {
    // Where sandcastle looks for the session it wants to resume. Omit it and
    // it defaults to ~/.pi/agent/sessions, while pi — pointed at PI_HOME by
    // the sandbox env — writes here. The two must name the same directory,
    // which is why both derive from PI_HOME.
    //
    // PI_CODING_AGENT_DIR itself is set on the sandbox, not here: createSandbox
    // discards an agent provider's env.
    sessionStorage: { hostSessionsDir: path.join(PI_HOME, "sessions") },
  });
}

function promptArgs(): Record<string, string> {
  return {
    TICKET_NUMBER: String(ticket.number),
    TICKET_TITLE: ticket.title,
    TICKET_CONTEXT: ticketContext,
    BRANCH: branch,
    BASE_BRANCH: `origin/${BASE}`,
  };
}

async function handOff(title: string, detail: string): Promise<never> {
  console.error(`\n${title}.\nWorktree kept at ${cwd}`);
  await dash.fail({
    headline: title,
    kind: "parked",
    link: ticket.url,
    needsHuman: true,
    facts: [
      { label: "branch", value: branch },
      { label: "worktree", value: cwd },
      { label: "issue", value: "relabelled ready-for-human" },
    ],
  });
  if (!DRY_RUN) {
    gh([
      "issue", "comment", TICKET,
      "--body",
      `**${title}.**\n\n${detail}\n\nBranch \`${branch}\` is left in place.`,
    ]);
    gh([
      "issue", "edit", TICKET,
      "--add-label", "ready-for-human",
      "--remove-label", "ready-for-agent",
    ]);
  } else {
    console.error(`DRY_RUN: would comment on and relabel #${ticket.number}`);
  }
  process.exit(1);
}

// step.exec streams the command's output live into the dashboard (tagged with
// the step) instead of buffering it until exit like execFileSync. The verdict
// stays here: exec reports, the workflow decides.
async function gate(step: Step): Promise<{ ok: boolean; output: string }> {
  console.log("  running ./Scripts/check.sh");
  const r = await step.exec("./Scripts/check.sh", [], { cwd });
  return { ok: r.ok, output: r.output };
}

async function rebase(): Promise<boolean> {
  return (await dRebase.exec("git", ["rebase", `origin/${BASE}`], { cwd })).ok;
}

function rebaseInProgress(): boolean {
  return ["rebase-merge", "rebase-apply"].some((d) =>
    existsSync(path.resolve(cwd, git(["rev-parse", "--git-path", d]))),
  );
}

function commitsAhead(): number {
  return Number(git(["rev-list", "--count", `origin/${BASE}..HEAD`]));
}

function headBranch(): string {
  return git(["rev-parse", "--abbrev-ref", "HEAD"]);
}

function tail(text: string, lines = 60): string {
  return text.split("\n").slice(-lines).join("\n");
}

function git(args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
}

function gh(args: string[]): string {
  return execFileSync("gh", args, { encoding: "utf8" });
}

function required(name: string): string {
  const value = process.env[name];
  if (!value) {
    console.error(`Missing required env var: ${name}`);
    process.exit(1);
  }
  return value;
}
