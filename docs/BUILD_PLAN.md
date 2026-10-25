# Build plan

Durations assume one or two full-time builders and are estimates. Every phase's "done when" includes compliance checks
from `docs/HARD_RULES.md`. A phase is not done until its compliance tests pass in CI.

## Phase 0, weeks 1-2: Spike + compliance skeleton

**Build.** Use Claude Squad and Happy for a few days. In a scratch script (`spike/`): create a worktree, run
`claude -p --output-format stream-json` and `codex exec --json` in it signed in with your own accounts, parse every event
type, catch the rate-limit error shapes, resume a session by ID. Write the adapter interface and the plan and handoff
formats. Record the stack decision (ADR 0001).

**Compliance.** Set up CI with the compliance checks from day one: banned credential paths and config-home variables
(rules 2, 4), no provider binaries or logos in the repo (rules 6, 8). This starter kit already provides
`scripts/ci/compliance-scan.sh` and `tests/compliance/selftest.sh`.

**Done when:** both CLIs finish a scripted task and return parsed results, **and** the compliance CI fails on a planted
violation of each check (`make compliance-selftest`).

## Phase 1, weeks 3-7: MVP (macOS, Claude Code + Codex, lead + 1 worker)

**Build.** App shell: install and login check through each CLI's own status output, binary verification, lead picker,
plan approval screen, one worker in its own worktree, view-only live terminal, diff view, tests, short summary, usage meter.

**Compliance built in:** compiled ceilings, presence check, pacing and backoff (rules 1, 10), approval tokens (rule 9),
headless-only adapters with no PTY write path (rule 3), per-provider counters (rule 2), file-access denylist (rule 4),
kill-switch config (rule 12).

**Done when:** 10 real tasks finish end to end with plan approved, diff reviewed, summary under 200 tokens, **and** all
tests for rules 1-4, 6 and 8-12 pass, including the credential canary test and the 24-hour simulated-clock test.

## Phase 2, weeks 8-11: Roles, parallel workers, merge step

**Build.** Role editor (backend, frontend, researcher, reviewer) mapped to providers. Parallel workers with file ownership,
merge queue with rebase and tests, cross-vendor reviewer, shared MCP notes server. Parallel work is spread across
providers: the ceiling of 2 concurrent sessions per subscription provider still holds, and more parallelism needs a
different provider or an API key.

**Done when:** a 3-worker feature merges with no manual conflict fixing, every merge was user-approved, **and** tests show
the concurrency ceiling holds with 4 workers queued on one subscription provider and that the MCP server and worktrees
never expose CLI home directories.

## Phase 3, weeks 12-15: More providers and failover

**Build.** Add Grok Build (ACP or `-p`), Kimi CLI (ACP), Gemini CLI (API key only), GLM through official Claude Code with
Z.ai's base URL. Optional BYO API keys in Keychain with required spend caps (rule 11). Failover to a different provider
listed in the approved plan. Unattended mode for API-key providers only. Start the weekly terms-snapshot job.

**Done when:** a forced rate limit mid-task finishes on a different provider with no help from you, **and** tests pass for:
Gemini unavailable without an API key (rule 7), failover never picks the same provider or one outside the plan (rules 2,
9), unattended mode refused for every subscription provider (rule 1), and every new adapter verified and headless-only
(rules 3, 6).

## Phase 4, weeks 16-20: Hardening + compliance review

**Build.** Sandbox defaults for workers, read-only researchers, inter-agent messages labeled untrusted, secret scanning on
briefs, nightly tests against new CLI versions, crash recovery and resume, signed and notarized builds, auto-update.

**Done when:** a week of daily use with no lost work, the injection test suite passes, the full compliance suite passes on
the **release** build (not just debug), the kill switch is tested end to end on a release build, and an outside reviewer
has checked the hard rules against each provider's current terms.

## Phase 5, after that: Windows and growth

**Build.** Windows build (ConPTY, Credential Manager, path handling), shareable templates, research and other non-coding
roles. Team features only where each member uses their own login on their own machine (rule 5).

**Done when:** the full compliance suite passes on Windows with Windows credential paths added to the denylist, and team
features pass the no-relay test.

> Ship order matters: get Claude Code and Codex working reliably with one worker before adding parallel workers or a
> third provider. A lead that confidently reports broken work will lose users faster than a missing provider.
