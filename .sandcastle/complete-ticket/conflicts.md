# TASK

A rebase of `{{BRANCH}}` onto `{{BASE_BRANCH}}` stopped on conflicts. Resolve
them and finish the rebase.

Use `/resolving-merge-conflicts`.

# HOW

Run `git status` to see which files conflict. For each one, understand what
both sides were trying to do before you resolve it — the base branch has moved
since this work started, and the other side's change is as intentional as
yours.

Never resolve by taking one side wholesale unless you have read both and know
that is correct. Never delete a conflicting test to make the conflict go away.

Run `swift build` and `swift test` after resolving, before continuing.

# DONE

`git rebase --continue` until the rebase is finished and `git status` reports
no rebase in progress.

Do not `git rebase --abort`. If the conflicts genuinely cannot be resolved,
stop and say so — the workflow will abort and hand it to a human.
