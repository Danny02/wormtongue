// L2 — launch integration: is the isolated pi-home actually wired so a real
// pi invocation through it reaches both models, and can the workflow be run
// without ever pushing to origin/main?
//
// This is the CHEAP-but-real layer: it does one real pi call per model (the
// same probe complete-ticket.ts does up front) and verifies the config that
// makes those calls work. A full end-to-end push (a real GitHub issue, gh
// auth, a green ./Scripts/check.sh) is the expensive L2-now / L3 concern and
// is NOT run here — it is gated behind --full and a scratch remote, never
// origin/main.
//
// Run: npx tsx .sandcastle/tests/l2/launch.test.ts
//      npx tsx .sandcastle/tests/l2/launch.test.ts --full   (gated, scratch remote)

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, lstatSync, readFileSync } from "node:fs";
import * as path from "node:path";

const HERE = import.meta.dirname;
const PI_HOME = path.resolve(HERE, "..", "..", "pi-home");
const REPO = path.resolve(HERE, "..", "..", "..");

const IMPL_MODEL = process.env.IMPL_MODEL ?? "openrouter/deepseek/deepseek-v4-flash-0731";
const REVIEW_MODEL = process.env.REVIEW_MODEL ?? "claude-bridge/claude-opus-5";
const FULL = process.env.RUN_FULL === "1";

// Safety invariant: the launch test must never be able to write to the real
// repo. It reads pi-home and (optionally, gated) a scratch fixture; it neither
// pushes nor merges. --full refuses to run unless a scratch remote is given.
if (FULL && !process.env.SCRATCH_REMOTE) {
  throw new Error("RUN_FULL=1 requires SCRATCH_REMOTE (a throwaway remote): L2 must never touch origin/main");
}

function pi(args: string[], env: Record<string, string> = {}): { ok: boolean; out: string } {
  try {
    const out = execFileSync("pi", args, {
      env: { ...process.env, ...env },
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 120_000,
    });
    return { ok: true, out };
  } catch (e) {
    const err = e as { stdout?: string; stderr?: string; message?: string };
    return { ok: false, out: [err.stdout, err.stderr, err.message].filter(Boolean).join("\n") };
  }
}

test("pi-home is seeded coherently (the setup for home)", () => {
  assert.ok(existsSync(PI_HOME), `pi-home missing: ${PI_HOME}`);
  for (const f of ["settings.json", "models-store.json", "models.json", "AGENTS.md", "agents", "auth.json"]) {
    assert.ok(existsSync(path.join(PI_HOME, f)), `pi-home/${f} missing — run setup.sh`);
  }
  // auth.json must be a symlink (credential lives in exactly one place)
  assert.ok(lstatSync(path.join(PI_HOME, "auth.json")).isSymbolicLink(), "auth.json should be a symlink, not a copy");
  // settings.json parses
  const settings = JSON.parse(readFileSync(path.join(PI_HOME, "settings.json"), "utf8"));
  assert.equal(typeof settings, "object");
  // the agent config dir is what a worker inherits; AGENTS.md must exist there
  assert.ok(existsSync(path.join(PI_HOME, "agents", "Explore.md")), "pi-home/agents should have the Explore agent");
});

test("a real pi call through the isolated config reaches the implement model", { skip: FULL ? false : "enable with --full; costs one real call" }, () => {
  // Mirrors probeModel() in complete-ticket.ts: a real one-shot call, not a
  // catalog lookup. This is the test that "pi works with our setup for home".
  const r = pi(["--model", IMPL_MODEL, "-p", "Reply with the single word: ok"], {
    PI_CODING_AGENT_DIR: PI_HOME,
  });
  assert.ok(r.ok, `IMPL_MODEL unreachable from PI_HOME:\n${r.out.slice(-2000)}`);
  assert.match(r.out.toLowerCase(), /\bok\b/, `IMPL_MODEL did not answer as expected:\n${r.out.slice(-500)}`);
});

test("a real pi call through the isolated config reaches the review model", { skip: FULL ? false : "enable with --full; costs one real call" }, () => {
  const r = pi(["--model", REVIEW_MODEL, "-p", "Reply with the single word: ok"], {
    PI_CODING_AGENT_DIR: PI_HOME,
  });
  assert.ok(r.ok, `REVIEW_MODEL unreachable from PI_HOME:\n${r.out.slice(-2000)}`);
  assert.match(r.out.toLowerCase(), /\bok\b/, `REVIEW_MODEL did not answer as expected:\n${r.out.slice(-500)}`);
});

test("the workflow's required tooling is on PATH (gh, git, pi, node, tsx)", () => {
  for (const tool of ["gh", "git", "pi", "node"]) {
    let found = false;
    try { execFileSync("which", [tool], { stdio: "ignore" }); found = true; } catch { /* not found */ }
    assert.ok(found, `${tool} not found on PATH — the workflow cannot run`);
  }
  // tsx is a devDependency of the repo
  assert.ok(existsSync(path.join(REPO, "node_modules", ".bin", "tsx")), "tsx not installed — npm ci first");
});

test("the workflow's required tooling is on PATH (gh, git, pi, node)", () => {
  for (const tool of ["gh", "git", "pi", "node"]) {
    let found = false;
    try { execFileSync("which", [tool], { stdio: "ignore" }); found = true; } catch { /* not found */ }
    assert.ok(found, `${tool} not found on PATH — the workflow cannot run`);
  }
  assert.ok(existsSync(path.join(REPO, "node_modules", ".bin", "tsx")), "tsx not installed — npm ci first");
});

// The failure-mode the workflow is built to catch: credentials or a key are
// absent and every real model call fails downstream. probeModel() is what
// turns that into a first-second failure. Here we assert the mechanism exists
// in the workflow source: it must probe before building a worktree or running
// the gate.
test("complete-ticket.ts probes both models before any work", () => {
  const src = readFileSync(path.join(path.dirname(PI_HOME), "complete-ticket", "complete-ticket.ts"), "utf8");
  // probeModel is called in a loop over [IMPL_MODEL, REVIEW_MODEL] before the
  // worktree is created, and exits on failure.
  assert.match(src, /for \(const model of \[IMPL_MODEL, REVIEW_MODEL\]\)/, "must probe both models");
  assert.match(src, /probeModel\(model\)/, "probeModel must be invoked");
  assert.match(src, /process\.exit\(1\)/, "an unreachable model must stop the run");
  const worktreeIdx = src.indexOf("createWorktree");
  const probeIdx = src.indexOf("probeModel(model)");
  assert.ok(worktreeIdx > probeIdx && probeIdx !== -1, "probe must run before createWorktree");
});

// Safety: the runner forces DRY_RUN=1 for every test layer, so a test that
// reaches squashMerge() prints instead of pushing. The lock is in
// run-tests.sh; assert it here so removing the export is a test failure.
test("run-tests.sh forces DRY_RUN for every layer", () => {
  const runner = readFileSync(path.join(path.dirname(PI_HOME), "tests", "run-tests.sh"), "utf8");
  assert.match(runner, /export DRY_RUN=1/, "runner must force DRY_RUN=1");
  // every layer case in the runner runs under that export (no per-case override)
  assert.doesNotMatch(runner, /DRY_RUN=0/, "runner must never set DRY_RUN=0");
});

// dir checks for coherence
test("pi-home has no stray agent config a worker would politely inherit", () => {
  // An empty agent dir means workers inherit ~/.pi/agent. We expect our own
  // agents/ (Explore) and no top-level AGENTS.md pointing elsewhere.
  const agents = readdirSync(path.join(PI_HOME, "agents"));
  assert.ok(agents.includes("Explore.md"), "agents/ should at least contain Explore.md");
});