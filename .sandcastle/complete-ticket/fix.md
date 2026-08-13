# TASK

Work on ticket #{{TICKET_NUMBER}} was handed back. Fix it.

You are on branch `{{BRANCH}}` in a git worktree. Commits from the previous
attempt are already there — this is a fresh session, so read the code and
`git log --oneline {{BASE_BRANCH}}..HEAD` to see what was done.

## What was wrong

{{FEEDBACK}}

## The ticket

{{TICKET_CONTEXT}}

# HOW

Fix the cause, not the symptom. If a test fails, understand why before
changing it — a test bent until it passes is worse than a failing one.

If the objection is that you did the wrong thing, revert it rather than
layering a fix on top.

Add to the branch with a new commit, written with `/writing-git-commits`.

# DONE

Run `./Scripts/check.sh` and fix what it reports. The workflow then rebases,
re-runs it, and re-reviews — those results decide, not yours.

Stop when the objection above is resolved and committed to `{{BRANCH}}`.
