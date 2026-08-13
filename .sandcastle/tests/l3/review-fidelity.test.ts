// L3 — real-model fidelity gate for review.md.
//
// The one path that only a real model can exercise: does the reviewer, given
// the actual review.md prompt and a real diff, emit a parseable <review> JSON
// block that the workflow's parser survives? Mocked output cannot answer this.
//
// Cost: one review-model call (REVIEW_MODEL) per run. This is why it is a
// separate layer: it is the gate that must run before ANY change to review.md
// lands, and not on every commit.
//
// Setup: builds a throwaway git repo in a temp dir with a synthetic ticket
// context and a real (tiny) diff, fills review.md with the workflow's exact
// promptArgs, runs the real pi binary with PI_CODING_AGENT_DIR=pi-home in that
// repo, and asserts the output parses with parseReviewOutput().
//
// Run: npm run test:fidelity   (or: npx tsx .sandcastle/tests/l3/review-fidelity.test.ts)

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { parseReviewOutput, fill, PROMPT_KEYS } from "../../complete-ticket/core.ts";

const HERE = import.meta.dirname;
const PI_HOME = path.resolve(HERE, "..", "..", "pi-home");
const PROMPTS_DIR = path.resolve(HERE, "..", "..", "complete-ticket");

const REVIEW_MODEL = process.env.REVIEW_MODEL ?? "claude-bridge/claude-opus-5";
const IMPL_MODEL = process.env.IMPL_MODEL ?? "openrouter/deepseek/deepseek-v4-flash-0731";
const MAX_RETRIES = 2;

function run(cmd: string, args: string[], opts: { cwd: string; env?: Record<string, string> }) {
  return execFileSync(cmd, args, {
    cwd: opts.cwd,
    env: { ...process.env, ...(opts.env ?? {}) },
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 300_000,
  });
}

/** Build a scratch repo with a synthetic ticket diff; returns its path. */
function makeScratchRepo(): string {
  const dir = mkdtempSync(path.join(tmpdir(), "sandcastle-l3-"));
  const git = (args: string[]) => run("git", args, { cwd: dir });
  git(["init", "-q", "-b", "main"]);
  git(["config", "user.email", "l3@test"]);
  git(["config", "user.name", "L3 Test"]);
  // base state: a file that check.sh would pass (this is a stand-in — the L3
  // gate tests the review prompt's fidelity, not the gate itself)
  writeFileSync(path.join(dir, "README.md"), "# synthetic\n");
  git(["add", "."]);
  git(["commit", "-qm", "base"]);
  git(["branch", "-M", "main"]);
  // a branch with a plausible change
  git(["checkout", "-qb", "ticket-999"]);
  writeFileSync(path.join(dir, "README.md"), "# synthetic\n\nchange from ticket 999\n");
  git(["add", "."]);
  git(["commit", "-qm", "feat: synthetic change for review fidelity"]);
  return dir;
}

test("review.md against a real model emits parseable <review> JSON", { skip: process.env.SKIP_L3 ? "SKIP_L3 set" : false }, () => {
  const repo = makeScratchRepo();
  try {
    const prompt = fill(readFileSync(path.join(PROMPTS_DIR, "review.md"), "utf8"), {
      BRANCH: "ticket-999",
      TICKET_NUMBER: "999",
      TICKET_TITLE: "Synthetic fidelity ticket",
      TICKET_CONTEXT:
        "Synthetic ticket for L3 fidelity testing. The acceptance criterion: " +
        "the reviewer emits the exact <review> block. This ticket changes " +
        "README.md. There is no real bug; the point is prompt fidelity, so an " +
        "approve or a reject with a real objection is both correct.",
      BASE_BRANCH: "origin/main",
      DIFF_RANGE: "origin/main...HEAD",
    });

    // wire an origin so `git diff origin/main...HEAD` in the prompt works
    run("git", ["remote", "add", "origin", repo], { cwd: repo });
    run("git", ["update-ref", "refs/remotes/origin/main", "main"], { cwd: repo });

    const out = run("pi", ["--model", REVIEW_MODEL, "-p", prompt], {
      cwd: repo,
      env: { PI_CODING_AGENT_DIR: PI_HOME },
    });

    const verdict = parseReviewOutput(out);
    assert.notEqual(
      verdict.verdict,
      "unknown",
      `review model did not produce a parseable verdict. Raw output tail:\n\n${out.slice(-2000)}\n\n` +
        `This is a review.md fidelity failure — fix the prompt or the model before merging review.md changes.`,
    );
    if (verdict.verdict === "reject") {
      assert.ok(verdict.objections.length > 0, "reject verdict must carry objections");
    }
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});

// The workflow's own probe — asserted at L1 from source; here we re-assert the
// pair of models is reachable through pi-home as a preflight so a failing L3
// run is attributable (config) and not misread as a prompt problem.
test("preflight: both models reachable through pi-home", { skip: process.env.SKIP_L3 ? "SKIP_L3 set" : false }, () => {
  const repo = makeScratchRepo();
  try {
    for (const model of [IMPL_MODEL, REVIEW_MODEL]) {
      const out = run("pi", ["--model", model, "-p", "Reply with the single word: ok"], {
        cwd: repo,
        env: { PI_CODING_AGENT_DIR: PI_HOME },
      });
      assert.match(out.toLowerCase(), /\bok\b/, `${model} unreachable from pi-home:\n${out.slice(-1500)}`);
    }
  } finally {
    rmSync(repo, { recursive: true, force: true });
  }
});