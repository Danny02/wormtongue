# Sandcastle workflow test strategy

Testing for `.sandcastle/complete-ticket/complete-ticket.ts` and the five prompts
it drives (`implement.md`, `review.md`, `conflicts.md`, `fix.md`, `verify-steps.md`).

## The four layers

The workflow's seven "testable things" split into four disjoint layers. Each has
its own cost, CI-runnability, and failure semantics. A thing never crosses layers.

| Layer | What it covers | Cost | Runs on |
|---|---|---|---|
| **L0** | Static gate over the prompts | zero (no AI, no network) | every change |
| **L1** | Logic unit tests with stub provider | zero tokens | every change |
| **L2** | Launch integration: real pi-home + DRY_RUN fixture | 1 probe call / model | CI / before release |
| **L3** | Real-model fidelity: does a real model survive `<review>`? | real tokens | prompt change to `review.md`; manual |

## Decisions (locked in the grill)

1. **Refactor-for-testability first.** `complete-ticket.ts` is one module with
   module-level `fill`, `git`, `gh`, `reviewPass`, `promptArgs` closures and a
   hard-coded `sandcastle.pi()` call. Nothing below L0 is testable until the pure
   logic is extracted into an importable module (`core.ts`) and the side effects
   (git, gh, check.sh, dashboard, agent provider) are injectable.
   The `AgentProvider` interface in `@ai-hero/sandcastle` is injectable —
   verified in `node_modules/@ai-hero/sandcastle/dist/index.d.ts:135` — so a
   stub provider is feasible only after that seam exists.
2. **All three "command" kinds, three different tests.**
   - Workflow-process commands (`git fetch/merge/rebase/push`, `gh …`,
     `./Scripts/check.sh`, `pi --model … -p`) → L1 fixture tests.
   - Agent-run commands inside prompts (`swift build`, `swift test`,
     `./Scripts/check.sh`) → not unit-testable; covered by L3 indirectly.
   - `/skill` references in prompts (`/tdd`, `/diagnosing-bugs`,
     `/writing-git-commits`, `/resolving-merge-conflicts`, `/Explore`) →
     L0 statically asserts the skill file exists under `~/.agents/skills`, which
     is the directory `pi-home/AGENTS.md` promises the worker can read.
3. **Every real-run test is DRY_RUN + scratch remote + synthetic issue.** A real
   run ends in `squashMerge()` → `git push origin HEAD:main` or a real PR.
   Any unauthorised L2/L3 run is a merge-to-production script. All L2/L3 insured
   against writing to `origin/main` via `DRY_RUN=1` and a throwaway remote.
4. **L3 gates `review.md`.** `reviewPass` parses `/<review>([\s\S]*?)<\/review>/`
   then `JSON.parse`. Only real-model output can break that path. Any change to
   `review.md` requires an L3 run before merge.
5. **Two templating engines, tested separately.** Sandcastle's own `{{KEY}}`
   substitution (implement/review/conflicts/verify-steps) and the hand-rolled
   `fill()` (fix.md, because `resume()` takes an inline prompt and sandcastle does
   not substitute inline prompts). `fill()` throws on unknown keys; what sandcastle
   does with `{{UNKNOWN}}` in a `promptFile` is unknown and must be asserted by the
   L1 stub capturing the delivered prompt.
6. **"Verify by hand" is a feature, not a test gap.** `verify-steps.md` and the
   PR-body extraction (`/<verify>…<\/verify>/`) are tested at L1 with fixtures;
   the actual steps are only as good as the model and belong to L3.

## Runnable

The runner is the single entry and forces `DRY_RUN=1` for every layer — a
test that reaches `squashMerge()` prints instead of pushing.

```sh
npm test                 # L0 + L1: fast, no AI, no network (default layer)
npm run test:launch      # L2: real pi binary + pi-home coherence, probes both
                         #     models once each. Needs credentials. No push.
npm run test:full        # L2 --full: runs the workflow against a scratch
                         #     remote. Requires SCRATCH_REMOTE env; refuses to
                         #     run without it. Costs real tokens.
npm run test:fidelity    # L3: runs the actual review.md against a real model
                         #     on a synthetic ticket in a tmp repo, asserts
                         #     parseable <review> JSON. Gates review.md changes.
```

The `full` layer refuses to start without `SCRATCH_REMOTE` (exit 2). The
`fidelity` layer needs no remote — it builds its own throwaway repo in `tmpdir`.

## Structure

```
tests/
  README.md               <- this file
  run-tests.sh            <- single entry; forces DRY_RUN; layers fast|launch|full|fidelity
  l0/prompts.test.ts      <- static gate (8 tests): keys, extras, fill no-survivor,
                             /skill resolution, no !`shell` blocks, delimiters
  l1/core.test.ts         <- logic unit tests (16 tests): fill, review/verify parsers,
                             routing, sandcastle substitution invariants, stub shape
  l2/launch.test.ts       <- launch integration (6 tests): pi-home seeding, tooling on
                             PATH, probe-before-work, DRY_RUN lock; +2 real-call tests
                             gated behind --full with SCRATCH_REMOTE
  l3/review-fidelity.test.ts <- real-model fidelity (2 tests, one REVIEW_MODEL call +
                             one preflight call per run); builds its own tmp repo
  fixtures/               <- (intended) canned agent output; today fixtures are inline
```

## Current status (built 2026)

- `npm test` (fast): 24 pass, 0 fail.
- `npm run test:launch`: 6 pass, 0 fail (model probes skipped unless `RUN_FULL=1`).
- `npm run test:fidelity`: 2 pass, 0 fail (ran against real models via pi-home).
- `npm run typecheck`: clean (tsx + tsc).
- The workflow itself is unchanged in behavior: `complete-ticket.ts` now imports
  `fill`/`parseReviewOutput`/`parseVerifyOutput` from `core.ts` instead of
  defining them inline; `reviewPass` still rejects with the same two messages.
- Known limitation: `!\`command\` ` shell-block expansion (sandcastle preprocessor)
  is exercised by zero prompts today, so L0 asserts none appear — the expansion
  itself is sandcastle-internal and not in its public API to unit-test.