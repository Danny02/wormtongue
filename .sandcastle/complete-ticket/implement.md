# TASK

Implement ticket #{{TICKET_NUMBER}}: {{TICKET_TITLE}}

You are in a fresh git worktree on branch `{{BRANCH}}`, created from
`{{BASE_BRANCH}}`. You have seen no prior conversation — everything you need is
below, in your instructions, or in the repo.

## The ticket

{{TICKET_CONTEXT}}

If the ticket names a parent spec, read it with `gh issue view <n> --comments`
so your implementation fits the larger plan.

# HOW

The ticket describes a symptom, not a cause. Reproduce it before you change
anything — use `/diagnosing-bugs`.

You are starting cold in a codebase you have not seen. Orienting yourself is
the part of this job that quietly eats a context window, so hand it to
`Explore` rather than doing it by hand: one question, one answer with
`file:line` evidence, none of the search output in your own history. Read
directly only the files you already know you need.

Once you know the cause, work at the seams of the change with `/tdd`: one
failing test, make it pass, repeat until every acceptance criterion is met,
then refactor. Run `swift build` and `swift test` as often as you like.

Prefer putting the logic in `Sources/WormtongueCore` where a test can observe
it, leaving only thin wiring in the app target. A fix that lives entirely in
the app target is a fix nothing can prove.

Write commit messages with `/writing-git-commits`.

# SCOPE

Only this ticket's acceptance criteria. No drive-by refactors, no new
dependencies, no work belonging to a sibling ticket. If you find an unrelated
problem, leave it and note it in the commit body.

# DONE

Run `./Scripts/check.sh` once before you stop, and fix what it reports.

Your green does not count. When you stop, the workflow rebases your branch onto
the latest `{{BASE_BRANCH}}`, runs `./Scripts/check.sh` itself, and has a
reviewer read your diff. Those results are the ones that decide. Running the
check yourself only saves you from being handed back an obvious failure.

Stop when every acceptance criterion is met and your work is committed to
`{{BRANCH}}`.
