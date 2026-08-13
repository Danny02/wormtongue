#!/usr/bin/env bash
# Sandcastle workflow test runner.
#
# Layers:
#   fast   (default)  L0 + L1 — no AI, no network, runs in seconds.
#   launch             L2 — real pi binary + pi-home coherence, probes both
#                      models once each. Needs credentials. No push possible.
#   full               L2 --full — runs the workflow itself against a scratch
#                      remote (SCRATCH_REMOTE) with a synthetic issue. Costs
#                      real tokens. NEVER run without a scratch remote.
#   fidelity           L3 — runs the actual review.md against real models on a
#                      synthetic ticket, asserts parseable <review> JSON.
#                      Expensive; gates changes to review.md.
#
# The DRY_RUN contract: every test run that could reach squashMerge() runs
# with DRY_RUN=1 forced. A test that unset it would push to origin/main.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

layer="${1:-fast}"
export DRY_RUN=1

case "$layer" in
  fast)
    npx tsx --test .sandcastle/tests/l0/*.ts .sandcastle/tests/l1/*.ts
    ;;
  launch)
    npx tsx --test .sandcastle/tests/l2/*.ts
    ;;
  full)
    [ -n "${SCRATCH_REMOTE:-}" ] || { echo "SCRATCH_REMOTE is required for 'full' (a throwaway remote). Never test against origin/main." >&2; exit 2; }
    echo "full run against ${SCRATCH_REMOTE} — this costs real tokens"
    RUN_FULL=1 npx tsx --test .sandcastle/tests/l2/*.ts
    ;;
  fidelity)
    # Runs the actual review.md against a real model on a synthetic ticket in a
    # local scratch repo. Costs real tokens; only ever run explicitly. No
    # remote involved — the scratch repo is throwaway, nothing is pushed.
    npx tsx --test .sandcastle/tests/l3/*.ts
    ;;
  *)
    echo "usage: $0 [fast|launch|full|fidelity]" >&2
    exit 1
    ;;
esac