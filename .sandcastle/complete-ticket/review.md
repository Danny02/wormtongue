# TASK

Review the work on branch `{{BRANCH}}` for ticket #{{TICKET_NUMBER}}.

Read the diff with `git diff {{DIFF_RANGE}}` and the commits with
`git log --oneline {{DIFF_RANGE}}`. Read the surrounding code — a diff that
looks fine in isolation can still be wrong in context.

## The ticket it must satisfy

{{TICKET_CONTEXT}}

# WHAT TO JUDGE

`./Scripts/check.sh` already passes, so do not re-run it and do not report
formatting. Judge the things a script cannot:

- **Does it satisfy the ticket?** Every acceptance criterion, not most.
- **Does it fix the cause?** A symptom patched at the call site is a reject.
- **Do the tests prove it?** A test that would pass against the unfixed code
  proves nothing. Check that the logic sits in `Sources/WormtongueCore` where
  a test can reach it, rather than being buried in the app target.

  If you want to claim a test would fail without the change, prove it. Read the
  test and the pre-change code and show the line that would break, or run the
  test against the old code in a scratch checkout. Otherwise say the tests look
  targeted and leave it there.
- **Is it in scope?** Unrelated refactors, new dependencies, or work belonging
  to another ticket are a reject.

Do not reject over style preferences, naming you would have chosen differently,
or missing work the ticket did not ask for.

# WHAT YOU MAY ASSERT

Only what you have observed. You are reading a diff, not running the program:
you have not seen it execute, and a plausible-sounding claim about behaviour
you did not witness is worse than no claim, because it is indistinguishable
from evidence.

Run whatever read-only commands you need — `git show`, `git diff`, reading
files, grepping for other callers. If a question would need running the code
and you are not going to run it, say what you checked and what you could not,
and judge on the rest. "I could not verify X" is a legitimate review finding.
Inventing X is not.

# OUTPUT

Do not change any files. End your reply with exactly this block:

<review>
{"verdict": "approve", "objections": []}
</review>

Use `"reject"` with one entry per objection, each a specific, actionable
sentence naming the file and what is wrong. If you reject, the objections are
the only thing the implementer will see.
