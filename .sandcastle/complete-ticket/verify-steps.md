# TASK

Your work on ticket #{{TICKET_NUMBER}} is finished and approved. It touches
files whose behaviour no test observes, so a human has to check it by hand
before it can be merged.

Write the steps for them.

## Files a test cannot observe

{{FILES}}

## The ticket

{{TICKET_CONTEXT}}

# HOW

Write what someone should do with the running app to see that this ticket is
fixed. Be concrete: which window, which button, which state to get into first.
Assume they know the app but have not read your diff.

Include the failure they would have seen before your change, so they can tell
a real fix from a coincidence.

Keep it to the shortest sequence that proves it. Do not describe your
implementation, and do not list steps that only re-check what `swift test`
already covers.

# OUTPUT

Change nothing. Reply with exactly this block and nothing after it:

<verify>
1. ...
2. ...
</verify>
