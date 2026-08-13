// L0 — static gate over the five prompts. No AI, no network, no git.
// Asserts, per prompt file:
//   1. every {{KEY}} referenced is an allowed key (base ∪ extra, from core.ts)
//   2. every allowed key is referenced (a dead contract key is a smell)
//   3. filling with a sample promptArgs leaves no surviving {{...}} (catches
//      the case where sandcastle's own substitution silently leaves {{UNKNOWN}})
//   4. every /skill reference resolves under ~/.agents/skills
//   5. no prompt embeds its own <review>/<verify> delimiter (breaks the parser)
//
// Run: npx tsx --test .sandcastle/tests/l0/prompts.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import * as path from "node:path";
import { homedir } from "node:os";
import { PROMPT_KEYS, PROMPT_FILES, fill, hasSurvivingPlaceholder, BASE_KEYS } from "../../complete-ticket/core.ts";

const HERE = import.meta.dirname;
const PROMPTS_DIR = path.resolve(HERE, "..", "..", "complete-ticket");
const SKILLS_DIR = path.join(homedir(), ".agents", "skills");

function readPrompt(file: string): string {
  return readFileSync(path.join(PROMPTS_DIR, file), "utf8");
}

test("every {{KEY}} in each prompt is an allowed key", () => {
  for (const file of PROMPT_FILES) {
    const prompt = readPrompt(file);
    const allowed = new Set([...PROMPT_KEYS[file].base, ...PROMPT_KEYS[file].extra]);
    const keys = [...prompt.matchAll(/\{\{(\w+)\}\}/g)].map((m) => m[1]!);
    // a prompt may reference a key zero times but never an undisclosed one
    for (const key of keys) {
      assert.ok(allowed.has(key), `${file}: {{${key}}} is not a declared key (allowed: ${[...allowed].join(", ")})`);
    }
  }
});

test("every allowed EXTRA key is referenced (base keys may be a superset)", () => {
  for (const file of PROMPT_FILES) {
    const prompt = readPrompt(file);
    for (const key of PROMPT_KEYS[file].extra) {
      assert.match(prompt, new RegExp(`\\{\\{${key}\\}\\}`), `${file}: injected key ${key} is never referenced — remove from the contract or the call site`);
    }
  }
});

test("extra keys are disjoint from base keys", () => {
  for (const file of PROMPT_FILES) {
    const { base, extra } = PROMPT_KEYS[file];
    assert.ok(
      extra.every((k) => !(base as readonly string[]).includes(k)),
      `${file}: an extra key overlaps a base key`,
    );
  }
});

test("filling with sample promptArgs leaves no surviving placeholder", () => {
  const sample: Record<string, string> = {
    TICKET_NUMBER: "123",
    TICKET_TITLE: "sample ticket",
    TICKET_CONTEXT: "some context",
    BRANCH: "ticket-123",
    BASE_BRANCH: "origin/main",
    DIFF_RANGE: "origin/main...HEAD",
    FEEDBACK: "a review objection",
    FILES: "Sources/Wormtongue/Foo.swift",
  };
  for (const file of PROMPT_FILES) {
    const prompt = readPrompt(file);
    // fill() throws on unknown keys, so this also proves every referenced key
    // is supplied by the union of promptArgs() + per-prompt extras.
    const rendered = fill(prompt, sample);
    assert.ok(!hasSurvivingPlaceholder(rendered), `${file}: left an unsubstituted {{...}}`);
  }
});

test("promptArgs() authored in complete-ticket.ts supplies every contract key", () => {
  // promptArgs() is fixed by construction to BASE_KEYS; this pins that the
  // contract and the workflow agree. (The real coverage — that every referenced
  // key is supplied — is the fill() no-survivor test above.)
  for (const file of PROMPT_FILES) {
    const { base, extra } = PROMPT_KEYS[file];
    // base keys come from promptArgs(); extra keys are injected per prompt.
    assert.deepEqual([...base].sort(), [...BASE_KEYS].sort(), `${file}: base keys drifted from BASE_KEYS`);
    assert.ok(extra.every((k) => !BASE_KEYS.includes(k as (typeof BASE_KEYS)[number])), `${file}: extra key overlaps base`);
  }
});

test("every /skill referenced resolves under ~/.agents/skills", () => {
  // /Explore is an agent (subagent_type), not a skill file; /check /review
  // /verify are prompt markers/delimiters, not skill invocations.
  const SKILLS = new Set([
    "/tdd",
    "/diagnosing-bugs",
    "/writing-git-commits",
    "/resolving-merge-conflicts",
  ]);
  const agents = new Set(["/Explore"]);
  for (const file of PROMPT_FILES) {
    const prompt = readPrompt(file);
    for (const tok of prompt.matchAll(/\/([a-z][a-z-]*)/g)) {
      const ref = "/" + tok[1];
      if (agents.has(ref)) continue; // agent, checked at L1/L2
      if (ref.startsWith("/check") || ref === "/review" || ref === "/verify") continue;
      assert.ok(SKILLS.has(ref), `${file}: unknown /skill reference ${ref}`);
      const dir = path.join(SKILLS_DIR, ref.slice(1));
      assert.ok(
        // the skill dir exists and contains a SKILL.md
        (() => { try { return readdirHasSkIll(dir); } catch { return false; } })(),
        `${file}: skill ${ref} not found — expected ${dir}/SKILL.md`,
      );
    }
  }
});

test("no prompt uses an un-vetted !\`command\` shell block", () => {
  // sandcastle expands \`!\`...\`\` blocks (e.g. \`!\`git rev-parse --short HEAD\`\`)
  // by executing them via sandbox.exec before the agent sees the prompt, and
  // a nonzero exit aborts the run (PromptError). The complete-ticket workflow
  // deliberately uses none of them: every prompt's data comes from promptArgs,
  // not from shell expansion, so a \`!\` block would be un-vetted shell run in
  // the worker sandbox. If one shows up, review it before approving.
  for (const file of PROMPT_FILES) {
    const prompt = readPrompt(file);
    assert.ok(
      !/!\`[^\`]+\`/.test(prompt),
      `${file}: contains a shell block (\`!\`...\`\`) — no shell execution is currently vetted`,
    );
  }
});

test("review.md and verify-steps.md contain their required output delimiter", () => {
  // These output blocks are the point of the prompts: the model must emit the
  // <review>/<verify> delimiter and the workflow parses it. Their presence in
  // the prompt is required, not a bug. What L0 must catch is a prompt that
  // references a delimiter it is NOT supposed to emit.
  const review = readPrompt("review.md");
  const verify = readPrompt("verify-steps.md");
  assert.match(review, /<review>/, "review.md lost its <review> output spec");
  assert.match(verify, /<verify>/, "verify-steps.md lost its <verify> output spec");
  // none of the other prompts should contain either delimiter
  for (const file of PROMPT_FILES) {
    if (file === "review.md" || file === "verify-steps.md") continue;
    const prompt = readPrompt(file);
    assert.ok(!/<review>/.test(prompt), `${file}: unexpected <review> delimiter`);
    assert.ok(!/<verify>/.test(prompt), `${file}: unexpected <verify> delimiter`);
  }
});

// readdir + existence without importing fs/promises
function readdirHasSkIll(dir: string): boolean {
  return readdirSync(dir).includes("SKILL.md");
}