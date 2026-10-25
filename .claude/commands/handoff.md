---
description: Write HANDOFF.md for the current worktree in the AGENTS.md format
---
Write HANDOFF.md in the current worktree root using the format in AGENTS.md: Summary, Files changed, Tests run (with the
actual command output result of `make check-fast`), Hard rules touched (rule numbers + proving tests), Open risks /
questions, Confidence. Run `make check-fast` first; if it fails, report that instead of writing the handoff.
