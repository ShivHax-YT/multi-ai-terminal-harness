---
description: Turn a one-line request into a task brief for approval
argument-hint: <what you want built>
---
Create a task brief for: $ARGUMENTS

Use the architect subagent. Write docs/tasks/T-###.md (next free number) from docs/tasks/TEMPLATE.md with owned files,
testable acceptance criteria, dependencies, and the hard rules it touches with the test that proves each.
Then show me the brief and stop. Implementation starts only after I reply "approved T-###".
