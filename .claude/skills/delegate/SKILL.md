---
name: delegate
description: Fan out approved task briefs to helper subagents (Sonnet implementers in worktrees, Haiku scouts and test runners), then test, audit and review each branch. The Opus lead delegates and judges; it does not implement.
argument-hint: <T-### ...> | <goal>
disable-model-invocation: true
allowed-tools: Read Grep Glob Bash(git worktree *) Bash(git merge-tree *) Bash(git diff *) Bash(git log *) Bash(git status *) Bash(codex exec *)
---
You are the lead (Opus). Delegate; do not implement. Arguments: $ARGUMENTS

Team (all in .claude/agents/): architect (opus), implementer (sonnet; opus per call for hard briefs), scout (haiku),
test-runner (haiku), compliance-auditor (sonnet), reviewer (opus), docs (haiku). Haiku agents never write source code.

1. Briefs. If the arguments are task IDs, read docs/tasks/<id>.md for each and confirm each is marked approved.
   If they are a goal, dispatch the architect subagent to write briefs, show me the list, and wait for "go".
2. Conflict check. Make a table of brief -> owned files. Any overlap, or any brief touching a shared file (Cargo.toml,
   package.json, lockfiles, tauri.conf.json, mod.rs or registry files), runs sequentially. Shared-file changes are made
   by you (the lead) in one integration commit before the fan-out.
   Never run more than 3 implementers at once, and at most 1 of them on opus.
3. Facts (optional). For open questions, dispatch up to 4 scout subagents in parallel, one question each.
4. Dispatch one implementer per brief, in parallel. Pass model=opus only when the brief's model hint is opus (Swift,
   PTY, signals, concurrency). The delegation prompt is the full brief text, the path to AGENTS.md and
   docs/HARD_RULES.md, and "Return branch, worktree path, check result, HANDOFF summary." Pass nothing else from this
   conversation.
5. As each returns, dispatch test-runner with its worktree path. On FAIL, use SendMessage to send the failure report to
   the same implementer. After 2 failed retries, stop and ask me.
6. Gates per branch, in order:
   a. compliance-auditor (always for adapters, spawning, scheduling, file access, networking or UI copy);
   b. reviewer;
   c. a Codex review run in the worktree (my own Codex login and ~/.codex/config.toml model settings):
      cd <worktree> && codex exec --sandbox read-only "Review git diff main...HEAD against the brief in docs/tasks/ and HANDOFF.md. Check docs/HARD_RULES.md too. List bugs and risks with file:line. Do not modify files."
   Any BLOCK goes back to the implementer with the findings.
7. Before reporting, check each passing branch for conflicts: `git merge-tree --write-tree HEAD <branch>`.
   A non-zero exit means conflicts: say which branch must be rebased and re-tested.
8. Report a table: task, model used, branch, checks, compliance verdict, review verdict, Codex verdict, open risks.
   Do not merge. I merge, one branch at a time, running `make check` after each.
9. After I merge, dispatch docs once for all merged tasks.

Rules: never use a fork or the general-purpose or Explore agents here (they are denied in settings and would run on
Opus), never pass your conversation history, never have a haiku agent write source code, and never weaken a hard rule
or compliance check to get a branch through.
