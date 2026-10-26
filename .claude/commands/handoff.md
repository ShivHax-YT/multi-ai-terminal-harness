---
description: Write docs/handoffs/T-###.md for the current worktree in the AGENTS.md format
---
Write docs/handoffs/T-###.md (the task id of this worktree) in the current worktree, not a root HANDOFF.md, using the format in AGENTS.md: Summary, Files changed, Tests run (with the
actual command output result of `make check-fast`), Hard rules touched (rule numbers + proving tests), Open risks /
questions, Confidence. Run `make check-fast` first; if it fails, report that instead of writing the handoff.
