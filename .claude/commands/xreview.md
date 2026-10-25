---
description: Cross-vendor second opinion on the current branch from Codex (read-only)
argument-hint: [base-branch]
disable-model-invocation: true
allowed-tools: Bash(codex exec *), Bash(git diff *), Bash(git rev-parse *)
---
Get a second opinion from a different vendor (hard rule: the author never grades its own work).

1. Base branch: use "$ARGUMENTS" if given, otherwise main.
2. Run Codex read-only from the repo root (it uses my own Codex login and my ~/.codex/config.toml model settings):

   codex exec --sandbox read-only "You are reviewing a branch of the Multi-AI Terminal Harness. Run: git diff <BASE>...HEAD. Read docs/HARD_RULES.md, the matching docs/tasks/T-*.md brief and HANDOFF.md. List correctness, concurrency, process-cleanup, missing-test and hard-rule findings, each with file:line and severity (bug / risk / nit). Do not modify files."

   Replace <BASE> with the base branch. If `codex` is not installed or not signed in, tell me and stop; never try to
   read or copy Codex credentials.
3. Summarize Codex's findings in a table, say which you agree with and why, and fix only items marked bug after I confirm.
