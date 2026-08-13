// Testable core of the complete-ticket workflow.
//
// complete-ticket.ts is a side-effecting script: creating an import of it runs
// gh, the dashboard server, git, and model probes. Nothing could be unit-tested.
// The pure logic — template filling, structured-output parsing, routing
// decisions — lives here and is imported by both the workflow and the tests.
// Side effects (git, gh, check.sh, box.run, the agent provider) stay in
// complete-ticket.ts and are injected at its seams.

/** Render `{{KEY}}` in a template. Throws on keys not in `args` (unknown or
 *  typo'd) rather than leaving a dead placeholder in a live prompt. */
export function fill(template: string, args: Record<string, string>): string {
  return template.replace(/\{\{(\w+)\}\}/g, (whole, key: string) => {
    if (!(key in args)) throw new Error(`prompt references unknown {{${key}}}`);
    return args[key]!;
  });
}

/** Every `{{KEY}}` referenced by a template, in order. */
export function referencedKeys(template: string): string[] {
  return [...template.matchAll(/\{\{(\w+)\}\}/g)].map((m) => m[1]!);
}

/** Whether the template still contains an unsubstituted `{{…}}` after filling.
 *  `fill` already throws on unknown keys, but sandcastle's own substitution
 *  (used for implement/review/conflicts/verify-steps, which do NOT go through
 *  `fill`) may leave a dead placeholder instead of throwing. This is the check
 *  that catches that. */
export function hasSurvivingPlaceholder(text: string): boolean {
  return /\{\{\w+\}\}/.test(text);
}

export interface ReviewVerdict {
  verdict: "approve" | "reject" | "unknown";
  objections: string[];
  raw: string | null;
}

/** Extract and parse the `<review>…</review>` JSON block from a reviewer's
 *  output. Mirrors reviewPass() in complete-ticket.ts exactly. */
export function parseReviewOutput(stdout: string): ReviewVerdict {
  const match = /<review>([\s\S]*?)<\/review>/.exec(stdout);
  if (!match) {
    return { verdict: "unknown", objections: [], raw: null };
  }
  try {
    const parsed = JSON.parse(match[1]!) as { verdict: string; objections?: string[] };
    if (parsed.verdict !== "approve" && parsed.verdict !== "reject") {
      return { verdict: "unknown", objections: parsed.objections ?? [], raw: match[1]! };
    }
    return {
      verdict: parsed.verdict,
      objections: parsed.objections ?? [],
      raw: match[1]!,
    };
  } catch {
    return { verdict: "unknown", objections: [], raw: match[1]! };
  }
}

/** Extract the `<verify>…</verify>` block written by verify-steps.md. */
export function parseVerifyOutput(stdout: string): string | null {
  return /<verify>([\s\S]*?)<\/verify>/.exec(stdout)?.[1]?.trim() ?? null;
}

/** The routing decision: auto-merge (nothing the gate can't observe changed)
 *  vs. open a PR (files the gate compiles but never runs changed).
 *  Mirrors the inline logic in complete-ticket.ts. */
export function needsHumanReview(
  changedFiles: string[],
  unobservedPrefix: string = "Sources/Wormtongue/",
): boolean {
  return changedFiles.some((f) => f.startsWith(unobservedPrefix));
}

/** The prompt files this workflow drives. Shared by the workflow (for their
 *  paths) and the L0 tests (for key/pattern sanity). */
export const PROMPT_FILES = [
  "implement.md",
  "review.md",
  "conflicts.md",
  "fix.md",
  "verify-steps.md",
] as const;

/** The keys promptArgs() always provides, in one place so the workflow and the
 *  tests cannot drift. */
export const BASE_KEYS = [
  "TICKET_NUMBER",
  "TICKET_TITLE",
  "TICKET_CONTEXT",
  "BRANCH",
  "BASE_BRANCH",
] as const;

/** The canonical {{KEY}} contract: which keys each prompt may use, and where
 *  they come from. `base` = promptArgs() (TICKET_NUMBER, TICKET_TITLE,
 *  TICKET_CONTEXT, BRANCH, BASE_BRANCH); `extra` = keys injected for that
 *  specific prompt beyond the base (DIFF_RANGE on review, FEEDBACK on fix,
 *  FILES on verify-steps).
 *
 *  L0 asserts: every {{KEY}} in a prompt belongs to its allowed set, every
 *  allowed key is actually referenced (a dead contract key is a smell), and
 *  the workflow's promptArgs() covers every base/extra key. */
export const PROMPT_KEYS: Record<
  (typeof PROMPT_FILES)[number],
  { base: string[]; extra: string[] }
> = {
  "implement.md": { base: [...BASE_KEYS], extra: [] },
  "review.md": { base: [...BASE_KEYS], extra: ["DIFF_RANGE"] },
  "conflicts.md": { base: [...BASE_KEYS], extra: [] },
  "fix.md": { base: [...BASE_KEYS], extra: ["FEEDBACK"] },
  "verify-steps.md": { base: [...BASE_KEYS], extra: ["FILES"] },
};
