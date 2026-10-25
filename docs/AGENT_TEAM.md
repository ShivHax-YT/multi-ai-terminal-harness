# Agent team: Opus lead with cheaper helpers

Source: Researcher's build-setup Page, section "Opus lead with cheaper helpers" (Oct 2026). Short version: **1 Opus
lead, 2-3 Sonnet implementers, Haiku only for read-only and mechanical jobs, 1 GPT checker at merge time.** A big Haiku
swarm writing code is the wrong shape for Swift/Rust/PTY work: rework eats the savings, every subagent starts from an
empty context, and more parallel writers mean more merge conflicts. Rough estimate: about half the usage of an
all-Opus setup (illustrative API-price math; Anthropic doesn't publish per-model Max weighting).

| Role (file) | Model, effort | How many | Writes code? | When |
|---|---|---|---|---|
| Lead (main session) | Opus, high; xhigh in plan mode | 1 | Shared-file integration commits only | Always |
| architect | Opus, xhigh | 0-1 | No, docs/ only | Big designs (keeps the lead's context clean) |
| implementer | Sonnet, high; Opus per call for Swift/PTY/concurrency | 2-3 parallel, max 1 on Opus | Yes, own worktree | Each brief |
| scout | Haiku, medium | up to 4 parallel | No | Fact-finding before a brief |
| test-runner | Haiku, low | 1 per finished branch | No | After each implementer |
| compliance-auditor | Sonnet, high | 1 per relevant branch | No | Branches touching adapters/spawning/scheduling/files/network/UI copy |
| reviewer | Opus, high | 1 per branch | No | Before merge |
| GPT checker | Codex on your ChatGPT login (`/xreview` or codex-plugin-cc) | 1 per branch | No | Last gate before merge |
| docs | Haiku, medium | 1 | Markdown only | After merge |

Peak load: lead + 3 writers + 4 read-only scouts. Typical: 4-5 agents. On Max 5x start with 2 writers. All Claude
subagents share the same 5-hour and weekly limits; parallel bursts cause 429/529 errors. When Claude limits run low,
one brief can go to Codex (`/codex:rescue --background` with codex-plugin-cc) so it runs on the ChatGPT plan.

## How the settings enforce this (`.claude/settings.json`)

| Setting | Why | Verified in Claude Code docs (Oct 2026) |
|---|---|---|
| `"model": "opus"` | Lead runs on Opus | yes (settings) |
| `permissions.deny`: `Agent(fork)`, `Agent(Explore)`, `Agent(general-purpose)` | These run on the session model (Opus) and would silently burn Opus usage. `/subtask` still forks on purpose | yes (`Agent(Explore)` and `Agent(fork)` examples in sub-agents/permissions docs; `general-purpose` is the built-in name) |
| `env.CLAUDE_CODE_SUBAGENT_MODEL=sonnet` | Default for any subagent without its own `model` | yes (env-vars). Per-call model and frontmatter take precedence since v2.1.251 |
| `env.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=6` | Caps parallel bursts (default 20) | yes (env-vars) |
| `env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` | Helpers can't spawn helpers (default 3) | yes (env-vars) |
| `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0` | Agent teams stay **off** (experimental, ~7x tokens). Off is also the default; the explicit 0 documents intent | yes: docs say "set to 1 to enable", disabled by default. That "0" is read as off is assumed, not stated |
| `worktree.baseRef: "head"` | Helper worktrees branch from your checked-out branch, not main | yes (worktrees doc; accepts only its documented values, not branch names) |
| `hooks.SubagentStop` -> `log-subagent.sh` | One JSON line per finished helper in `.claude/subagents.jsonl` | yes (`agent_type`/`agent_id` in hook input) |

`/usage` shows the subagent share of your plan limits; `/tasks` shows which model each running subagent is on.

## Adding an agent

Copy `.claude/agents/_TEMPLATE.agent.md.example` to `.claude/agents/<name>.md`. Rules: read-only roles get
`disallowedTools: Edit, Write, NotebookEdit`; Haiku roles never get code-writing tools; anything that writes code uses
`isolation: worktree`. Add the role to the table above and to CLAUDE.md.

## Other delegation options considered (from the research)

- No official `/delegate` ships with Claude Code. The kit's own `.claude/skills/delegate/SKILL.md` is built on native
  subagents. Third-party candidates (TuYv/claude-delegate, worksfornow delegate.md, chimera-defi/delegate-skill) are
  too new or too narrow to depend on.
- Agent teams: off (see above).
- claude-code-router / routing helpers to GLM or Kimi: possible later, but routed requests use provider API keys and
  non-Claude tool use is weaker. Not in the kit.
- Codex as an MCP server: no longer offered by OpenAI; use `codex exec` or codex-plugin-cc.
