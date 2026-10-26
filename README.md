# Multi-AI Terminal Harness: repo starter kit

Drop-in instructions, rules, agents, hooks and CI for building the harness with Claude Code (Opus lead with cheaper
helpers, Codex as the second-vendor checker). It contains **no app code**: the first real task is choosing the stack.

Not legal advice. The hard rules reduce the risk of breaking provider terms but don't guarantee compliance; have a
lawyer review before any commercial launch.

## What's inside

| Path | Purpose |
|---|---|
| `CLAUDE.md` | Project memory for Claude Code: what we're building, decided approach, stack TODO, workflow, team, worktree rules |
| `AGENTS.md` | Shared rules for every coding agent (Claude, Codex, Grok, Kimi, Gemini), HANDOFF.md format |
| `docs/HARD_RULES.md` | The 12 non-negotiable rules, each with enforcement and test |
| `docs/ARCHITECTURE.md`, `docs/BUILD_PLAN.md` | Components, adapters, failover; Phases 0-5 with "done when" + compliance checks |
| `docs/COMPLIANCE_CHECKLIST.md` | Pre-launch checklist and per-release terms sign-off |
| `docs/AGENT_TEAM.md` | Who runs on which model and why; settings that enforce it |
| `docs/tasks/TEMPLATE.md`, `docs/adr/` | Task-brief template; ADRs (0001-stack.md comes first) |
| `.claude/settings.json` | Opus lead, permissions (credential stores denied), hooks, delegation settings, agent teams off |
| `.claude/hooks/*.sh` | jq-based hooks; exit 2 blocks (credential paths, Keychain, config-home overrides, force push...) |
| `.claude/agents/` | architect, implementer, scout, test-runner, docs, compliance-auditor, reviewer (+ template) |
| `.claude/skills/delegate/SKILL.md` | `/delegate`: Opus lead fans briefs out to helpers, then test, audit, review |
| `.claude/commands/` | `/plan-phase`, `/new-task`, `/compliance-check`, `/xreview` (Codex), `/handoff` |
| `.mcp.json`, `examples/mcp.swift-path.json` | Context7 + GitHub MCP; MobileBuildMCP (ex-XcodeBuildMCP) only for the Swift path |
| `scripts/ci/compliance-scan.sh`, `tests/compliance/selftest.sh`, `compliance/` | Static hard-rule scan and its self-test |
| `Makefile`, `.github/workflows/ci.yml` | `make check-fast` (Stop hook) / `make check` (CI); sample GitHub Actions |

## Prerequisites (macOS)

- Claude Code **v2.1.295 or later** (hooks use `onFailure: "block"`; Haiku 5.5 needs v2.1.293+). `claude --version`.
- `jq` (`brew install jq`). The hooks fail closed if it's missing. Optional: `shellcheck`.
- Git. GNU make 3.81 (the macOS default) works.
- Optional: Codex CLI on your own ChatGPT login for `/xreview`; `CONTEXT7_API_KEY` and `GITHUB_MCP_PAT` env vars for MCP.

## Drop it in

```bash
cd your-repo                       # new or existing git repo
unzip ~/Downloads/harness-starter-kit.zip -d /tmp/kit
rsync -a /tmp/kit/harness-starter-kit/ ./   # merge; check CLAUDE.md/AGENTS.md/.gitignore/Makefile if you already had them
chmod +x .claude/hooks/*.sh scripts/ci/*.sh tests/compliance/*.sh
make check                         # compliance scan + self-test (should print "33 passed, 0 failed")
git add -A && git commit -m "chore: add harness starter kit"
git checkout -b phase-0            # worktree.baseRef is "head": helpers branch from what you have checked out
claude                             # approve the project hooks/MCP servers when asked; run /hooks and /agents to confirm
```

## First prompt to give Claude

```text
Read CLAUDE.md, AGENTS.md, docs/HARD_RULES.md, docs/ARCHITECTURE.md and docs/BUILD_PLAN.md.
Don't write app code yet. Use the architect subagent to:
1) draft docs/adr/0001-stack.md comparing Tauri 2 and native Swift/SwiftUI for this project (PTY + child-process
   handling, notarization outside the App Store, how each enforces the hard rules, my ability to maintain it),
   with a recommendation, and
2) write Phase 0 task briefs in docs/tasks/ (T-001...) using docs/tasks/TEMPLATE.md.
Then stop and show me the ADR summary and the brief list. I'll pick the stack and approve briefs before /delegate.
```

After you approve: `/delegate T-001 T-002` (or `/plan-phase 1` later). You merge; agents never do.

## The team (summary; details in docs/AGENT_TEAM.md)

1 Opus lead (main session) + architect (Opus) for big designs; 2-3 Sonnet implementers in worktrees (Opus per call for
Swift/PTY/concurrency briefs, max 1); Haiku scouts, test-runner and docs, which never write source code; Sonnet
compliance-auditor and Opus reviewer as merge gates; one GPT check per branch. Forks, Explore and general-purpose
agents are denied so work never silently lands on Opus. **Agent teams are off.**

### GPT checker options

- `/xreview` (in this kit): runs `codex exec --sandbox read-only` on the branch diff using your own Codex login and
  `~/.codex/config.toml` model settings.
- **OpenAI's codex-plugin-cc** (official; github.com/openai/codex-plugin-cc): in Claude Code run
  `/plugin marketplace add openai/codex-plugin-cc`, then `/plugin install codex@openai-codex`, then `/codex:setup`.
  Gives `/codex:review --base main`, `/codex:adversarial-review`, and `/codex:rescue` (hand a brief to Codex when
  Claude limits run low). Run it once per branch, not per commit, and leave its automatic review gate off: ChatGPT
  plan message limits are tight. Its README examples name older models; set your model in `~/.codex/config.toml`.

## Verified vs unverified (checked against Claude Code docs, Oct 2026)

Verified in current docs: hook exec form (`command` + `args`), `${CLAUDE_PROJECT_DIR}`, `timeout`, `onFailure`,
exit-2 semantics, `stop_hook_active`, SessionStart stdout as context, `SubagentStop` with `agent_type`; subagent
frontmatter (`model`, `effort`, `isolation: worktree`, `maxTurns`, `disallowedTools`, `color`,
`disable-model-invocation`, `argument-hint`, `allowed-tools`); settings `model`, `effortLevel`, `env`,
`worktree.baseRef: "head"`, `permissions.deny` with `Agent(fork)`/`Agent(Explore)`/`Agent(general-purpose)`,
`disableBypassPermissionsMode`; env vars `CLAUDE_CODE_SUBAGENT_MODEL`, `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`,
`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`; `.mcp.json` `type: "http"` and `${VAR}`.

Not verified / check yourself:
- `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: "0"`: docs say teams are off by default and "set to 1 to enable"; that "0"
  reads as off is assumed. Deleting the line also keeps teams off.
- Effort levels: verified 2026-10-25 in the model-config docs. Opus 5.5, Sonnet 5.5 and Haiku 5.5 support all five levels (low, medium, high, xhigh, max), so no fallback applies. An unsupported level falls back to the highest supported level at or below it.
- The macOS Keychain service name the scan looks for ("Claude Code-credentials") comes from community reports.
- GitHub Actions versions (`actions/checkout@v4`, etc.) weren't re-checked; pin SHAs before release.
- Context7 uses the API-key header from its README (an OAuth endpoint also exists); GitHub MCP needs a PAT in
  `GITHUB_MCP_PAT` (deliberately not named after a variable Claude Code blanks in remote headers).
- MobileBuildMCP (`npx -y mobilebuildmcp@latest mcp`) is the renamed XcodeBuildMCP; package exists on npm, not
  run-tested here.
- Hooks were tested on Linux with sample stdin; run `make compliance-selftest` on your Mac once.
- Model names/scores (Opus/Sonnet/Haiku 5.5, GPT-6.1 Sol) come from the research Page.
