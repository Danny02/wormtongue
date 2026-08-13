---
name: sandcastle-workflows
description: Build or change a sandcastle workflow that dispatches headless pi agents — orchestration in TypeScript, prompts in files, verification owned by the workflow. Use when adding a workflow under .sandcastle/, changing how a worker is configured or isolated, or debugging one that hangs, loses its session, or lets the agent grade its own work.
---

# Sandcastle workflows

A workflow is a TypeScript program that creates a git worktree, dispatches one
or more headless agents into it, and decides what happens to the result. The
agents write code. The workflow decides whether that code is real.

Reference implementation: `.sandcastle/complete-ticket/`.

## The one rule everything else follows from

**Anything that must happen, or must not happen, belongs in code — not in a
prompt.** A prompt is a request. An agent under pressure will report success it
did not achieve, skip a step it found tedious, and answer "does this need human
review?" with whatever unblocks it fastest.

So the workflow, never the agent, owns:

- the verdict on whether tests pass
- the git history beyond the agent's own branch
- routing decisions (auto-merge vs human review)
- issue state, labels, and closing trailers
- retry counts and when to give up

The agent owns judgement that cannot be computed: what the cause of a bug is,
how to express a fix, what a human should click to verify it.

## Shape

```
.sandcastle/
  <workflow-name>/
    <workflow-name>.ts     orchestration
    implement.md           one prompt file per agent role
    fix.md
    review.md
  pi-home/                 isolated pi config for the workers
  skills/                  optional: skills copied for the workers
```

`package.json` is `private` and marked as not part of the main build. Scripts
run through `tsx --env-file-if-exists=.sandcastle/.env`.

Prompts are files with `{{PLACEHOLDER}}` substitution via `promptArgs`, not
template literals in the orchestrator. They are the part a human edits most.

## Verification: feedback versus verdict

Do not forbid the agent from running tests. It needs its own tight loop or it
writes code blind. What must not happen is the agent's claim *counting*.

- The agent runs `swift test` (or equivalent) as often as it likes. Feedback.
- The workflow runs the full check script itself. Verdict.

Say this explicitly in the prompt: *"Your green does not count."* It stops the
agent trying to shortcut to done, without crippling its loop.

**Rebase before verifying.** Testing pre-rebase code proves things about code
that will never exist on the base branch. Fetch, rebase, then run the gate. A
rebase is a no-op when the base has not moved, so it is free in the common case.

This replaces CI for a local workflow, and beats it when the project cannot be
built on a hosted runner — a macOS-only target compiles on the developer's
machine and nowhere else.

## Choosing between wt.run() and a sandbox

`createWorktree()` gives a `Worktree`. Its `run()` returns `WorktreeRunResult`,
which has **no `resume()`**.

For a retry loop, create a long-lived sandbox instead:

```ts
const wt = await sandcastle.createWorktree({ branchStrategy: { ... } });
const box = await wt.createSandbox({ sandbox: noSandbox() });
const run = await box.run({ agent, promptFile, promptArgs });
const retried = await run.resume(promptText, { promptArgs });
```

`SandboxRunResult.resume` closes over *that result's* session id, so review or
conflict-resolver runs in between do not hijack it. `resume` takes a prompt
**string**, not a file — read the file yourself; `promptArgs` still substitutes.

`resume` is optional in the type. It is absent when the provider captured no
session, which in practice means `sessionStorage` and the agent's config dir
disagree. Throw a clear error rather than silently starting fresh.

`noSandbox()` runs everything on the host. Use it when the project cannot build
in a container — a macOS app target, a platform-specific toolchain. It is a
real option, not a fallback.

## Configuring a headless pi worker

### Isolate the config directory

The variable goes on the **sandbox**, the session path on the **agent**:

```ts
const box = await wt.createSandbox({
  sandbox: noSandbox({ env: { PI_CODING_AGENT_DIR: PI_HOME } }),
});

sandcastle.pi(model, {
  sessionStorage: { hostSessionsDir: path.join(PI_HOME, "sessions") },
})
```

`PI_CODING_AGENT_DIR` relocates `auth.json`, `settings.json`, `AGENTS.md`,
`models.json`, `extensions/`, `mcp.json`, and `sessions/`. Without it the worker
inherits the user's global config — including an orchestration policy telling it
to delegate, and every MCP server.

**Do not put it in the agent provider's `env` if you use a sandbox.** Both
`createSandbox` paths hardcode `agentProviderEnv: {}`, because the sandbox is
started before the agent is chosen, so the provider's `env` is dropped without
a warning. Only the one-shot `run()` and `wt.run()` paths honour it. Verify with
a free `box.exec('echo $VAR')` probe rather than trusting it.

**`sessionStorage.hostSessionsDir` must name that same directory.** Omit it and
it defaults to `~/.pi/agent/sessions` while pi writes to the isolated home. The
symptom is a crash on the first retry: `resumeSession "..." not found under`.
Derive both from one constant so they cannot drift.

### Seed the model catalogue

A fresh config dir exposes only `amazon-bedrock`. The catalogue lives in
`models-store.json` and does not self-populate on a restricted network. Copy it
from the user's real config in a `setup.sh`, along with `models.json`. Symlink
`auth.json` rather than copying it, so credentials live in exactly one place.
Git-ignore all three.

### Skills leak past the isolation

`PI_CODING_AGENT_DIR` does **not** cover skills. `~/.agents/skills` is a
user-level resource pi loads unconditionally, so every global skill reaches the
worker.

Two options, both valid:

- **Accept it.** Skills marked `disable-model-invocation: true` never enter the
  worker's list, which excludes most orchestrator-style skills. Simplest.
- **Pin an explicit set.** `--no-skills --skill <abs-path>` bypasses discovery
  *and* the project-trust gate. `PiOptions` has no flag escape hatch, so wrap
  the provider — `AgentProvider` is a plain object, so spread it and override
  `buildPrintCommand` to append to `built.command`.

Project-local skills (`.pi/skills`, `.agents/skills`) are trust-gated and
silently never load headless, because sandcastle does not pass `--approve`.
Do not put worker skills there expecting them to load.

### Choose extensions by whether they can block

Exclude anything that waits for a human. `ask_user_question` and friends hang
until sandcastle's 600 s idle timeout and then fail the run.

Also exclude: TUI-facing extensions (meaningless under `--mode json`), memory
and experience extensions (throwaway workers should not write durable state),
MCP adapters (they drag unrelated servers into the run), and OS sandboxing
extensions (sandcastle already owns isolation).

Include providers you need for a second model tier — a provider extension
contributes zero tools but is the only way to reach its models.

### Enforce the prohibitions

Prose rules like "never push" are unenforceable while the agent has `bash`.
`@aliou/pi-guardrails` makes them real, and is headless-safe when configured
with no prompting states:

```json
{
  "features": { "permissionGate": true, "policies": true, "pathAccess": false },
  "permissionGate": {
    "requireConfirmation": false,
    "autoDenyPatterns": [
      { "pattern": "git push", "description": "The workflow owns pushing." }
    ]
  }
}
```

`requireConfirmation: false` downgrades built-in dangerous patterns to warnings
instead of prompts. `autoDenyPatterns` blocks without prompting — the agent gets
the `description` as the refusal reason, so write it as an instruction.

Config lives at `<agentDir>/extensions/guardrails.json` (flat file, unlike most
extensions which use `extensions/<name>/config.json`).

`pathAccess: "block"` enforces "stay in the repository" but can also block a
toolchain read outside the worktree. Enable it only after a run is known good.

### resume() takes a prompt, not a prompt file

`resume(prompt, options)` accepts an inline string, and sandcastle substitutes
`{{KEY}}` **only** for `promptFile`. Passing `promptArgs` next to an inline
prompt is a hard `PromptError`, thrown when the retry fires — typically minutes
into a run, after the first gate failure. Keep prompts in files and interpolate
yourself:

```ts
const prompt = fill(readFileSync(path.join(HERE, "fix.md"), "utf8"), args);
return previous.resume(prompt, { name, logging: logging(name) });
```

Make `fill` throw on an unknown `{{KEY}}` so a renamed placeholder fails loudly
instead of reaching the agent as literal braces.

### Watch a run while it happens

`Sandbox.run()` honours only `{ type: "file" }`. `{ type: "stdout" }` typechecks
and then falls through to a silent display, so a long run prints nothing at all
and looks like an agent that never started. Use the file mode and stream from
the callback:

```ts
logging: {
  type: "file",
  path: logPath,
  onAgentStreamEvent: (e) => {
    if (e.type === "text") process.stdout.write(e.message);
    if (e.type === "toolCall") process.stdout.write(`\n  · ${e.name} ${e.formattedArgs}\n`);
  },
}
```

Afterwards the pi session JSONL is the fuller record:
`pi --export <session.jsonl> run.html` renders a readable page.

### Report spend per model, not in total

A two-tier workflow's whole economic argument is that the expensive model runs
rarely. A single total hides whether that is true. Aggregate
`result.iterations[].usage` per model and print it on exit — register it with
`process.on("exit", ...)` so a parked or crashed run still reports what it
spent getting there, which is exactly the run you want the number for.

Do not trust cost figures from a subscription-backed provider. A metered
provider reports real per-token cost in the session JSONL; a subscription one
reports `0`. Token counts are comparable across both, currency is not.

## Structured output

Never make one agent both do work and emit JSON. Give the judgement to a
separate run whose only job is the verdict:

```ts
const match = /<review>([\s\S]*?)<\/review>/.exec(result.stdout);
```

Treat a missing or unparseable block as a rejection with a stated reason, not as
a crash. A reviewer that failed to answer has not approved anything.

## Failure handling

Bound the retries — two is usually right, since a third attempt rarely converges
and mostly burns tokens. On exhaustion, **park**: leave the branch and worktree
in place, comment the last failure on the issue, and relabel it for a human.
Exit non-zero.

**Run the gate once before dispatching anybody.** If the base branch already
fails it, every attempt is judged against a red baseline: the agent is handed
failures in files it never touched, cannot fix them without straying outside
the ticket, and burns every retry before the workflow parks a ticket that was
never the problem. Check the pristine worktree first and refuse to start. The
build cache is warm for the real run afterwards, so it is close to free.

This failure is worth guarding against precisely because it is invisible: a red
base branch and an incompetent agent produce identical output. Expect to find
one the first time you add the check — a gate nothing runs in CI drifts red
quietly, and the workflow is often the first thing to execute it in months.

**Insist the worktree is pristine before trusting any of that.** sandcastle
reuses an existing worktree as-is, so a crashed run leaves commits that the
baseline would measure instead of the base branch. Worse, the implementer would
resume on top of code it has no memory of writing, because its session died
with the crash. Check `commitsAhead()` and `git status --porcelain` at startup
and refuse, printing the commands to inspect and clear it. Never delete it
automatically — it may hold the only copy of real work.

Assert cheap invariants after every agent run: did it commit anything, is HEAD
still on the expected branch. These catch a confused agent far earlier than a
review does.

**Route on what the gate cannot observe, not on a directory allowlist.** The
natural first cut — "Core and tests are safe, everything else needs a human" —
is wrong in both directions. It sends docs, configs and fixtures to human
review when the gate already proves them, and it says nothing about a file that
is merely compiled. Ask instead which files the gate builds but never executes;
usually that is one target. Everything else is either verified or inert.

**Zero commits is two different outcomes, and they need different handling.**
Check `git status --porcelain`. A dirty tree means the agent edited files and
forgot to commit — retry with that as feedback. A clean tree means it decided
the ticket needs no change, which is a legitimate conclusion: the issue may
already be fixed or wrongly scoped. Retrying buys the same answer at full
price, so hand it to a human instead.

Give the workflow a `DRY_RUN` mode that does everything except push, open pull
requests, and change issue state. The first run of a new workflow should never
be able to touch the base branch.

## Gotchas

- Any label the workflow applies must already exist. `gh issue edit
  --add-label` fails on an unknown label, and it fails during the park path —
  exactly when things are already going wrong. Check with `gh label list`.
- Helpers bound to the worktree path cannot run before the worktree exists.
  The initial `git fetch` needs its own call.
- `git rev-parse --git-path` returns an absolute path inside a worktree.
- A ticket type is derivable from its labels. Read them from `gh issue view
  --json labels` rather than asking the agent what kind of change it made.
- **Tell the worker its shell has no memory.** pi's bash tool spawns a fresh
  process per call with a fixed `cwd` (`core/tools/bash.js`), so `cd` never
  persists — and an agent that does not know this prefixes every single command
  with `cd /absolute/path &&`. One run did it 41 times. One sentence in the
  worker instructions removes it.
- **A reviewer will assert things it never checked.** Given a diff and asked
  whether tests would fail against the unfixed code, it answers confidently
  without running anything. Instruct it to assert only what it observed, and to
  say "I could not verify X" as a legitimate finding — otherwise an invented
  claim is indistinguishable from evidence in the verdict you are trusting.
- **"Delegate wide questions" is too soft to act on.** An implementer told to
  prefer a search subagent will still run 41 greps itself, because no single
  step ever feels wide enough. Give it a countable trigger instead — more than
  two file reads for one question, or a third grep on the same question — and
  name the failure it prevents.
- A gate that shells out to the test runner for several checks reports all of
  them as failures when the runner itself is broken. Read the first failure in
  the output, not the last, before concluding anything about the agent's work.
- Verify environment plumbing with `box.exec('echo $VAR')` before spending a
  single token on an agent run. Sandcastle drops agent env silently in the
  sandbox path, and the symptom appears much later, as a lost session.
- Sessions outlive the worktree. `pi --export <session.jsonl> out.html` renders
  a full transcript, which is the only way to see what a worker actually did
  after its worktree is gone. Find them under the agent dir you isolated to,
  in a directory named after the worktree path.
