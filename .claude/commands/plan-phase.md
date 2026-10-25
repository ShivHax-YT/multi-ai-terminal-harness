---
description: Plan a build phase from docs/BUILD_PLAN.md into approved-ready task briefs
argument-hint: [phase-number]
---
Plan Phase $ARGUMENTS of docs/BUILD_PLAN.md.

1. Read docs/HARD_RULES.md, docs/ARCHITECTURE.md, docs/BUILD_PLAN.md and any existing docs/tasks/ and docs/adr/.
2. If CLAUDE.md still contains "TODO (HUMAN MUST CHOOSE" and this phase needs app code, stop and ask me to choose the
   stack first (Tauri 2 vs Swift). Phase 0 may proceed with spike scripts in spike/.
3. Use the architect subagent to break the phase into task briefs (docs/tasks/T-###.md, from docs/tasks/TEMPLATE.md).
   Every compliance item in the phase's "Done when" must map to at least one brief and one named test.
4. Show me a table: task, owned files, model hint, depends on, hard rules + tests, size. Mark which tasks can run in
   parallel (no shared files; at most 2 concurrent Claude worktrees on my subscription).
5. Stop and wait for my approval. Do not start implementation. After I approve, I run /delegate with the task IDs.
