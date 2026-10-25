# Hard rules (non-negotiable)

> **These rules are product constraints, not settings.** Each rule below is enforced in code and proven by a test in CI.
> A build that fails any of these tests does not ship. No user setting, flag or environment variable can turn a rule off
> for subscription logins. Users can make limits stricter, never looser than the ceiling.

Source: the plan Page "Multi-AI Terminal Harness: Assessment & Build Plan" (section "Hard rules"), Oct 23, 2026.
Ceiling numbers are starting values to tune against real usage during the build. They can be lowered in a release, but
users can never raise them.

---

## 1. No round-the-clock automation on subscriptions

**Design constraint.** Subscription logins run only while the user is present. No unattended, scheduled or overnight mode
for subscription logins; that mode exists only for API keys with a spend cap.

**How the code enforces it.** Hard ceilings per subscription provider, compiled in: **2 concurrent sessions, 30 automated
prompts per hour, 40 turns per task, 8 hours of automated run time per day.** Workers pause after the current task if the
user has been idle 30 minutes or the app is in the background. The scheduler has no cron or timer API for subscription
providers.

**Test that proves it.** Unit tests try to exceed each ceiling and to schedule a subscription run; both must be refused. A
24-hour simulated-clock test shows subscription activity stops at the daily ceiling and on user idle.

## 2. One account per provider, no limit-dodging

**Design constraint.** Exactly one signed-in account per provider per machine. Caps belong to the provider on this machine,
not to an account or session, so logging out, switching accounts or opening a new session never resets them. Failover
only moves work to a different provider.

**How the code enforces it.** The session manager launches each CLI with its default config home only. Code never sets
alternate config homes (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME`, `KIMI_CODE_HOME`) and has no multi-profile
feature. Usage counters are stored per provider and persist across restarts and account changes. The failover planner
rejects any fallback whose provider is the one that hit its limit.

**Test that proves it.** Lint fails on any reference to those variables (`scripts/ci/compliance-scan.sh`). Tests:
switching accounts mid-day keeps counters; restarting the app keeps counters; a fallback chain listing the same provider
twice is rejected; a limit error never triggers a new session on the same provider.

## 3. Automation never types into the interactive TUI

**Design constraint.** Automated prompts go only through each CLI's documented headless or ACP interface (`claude -p`,
`codex exec`, `grok -p`, `grok agent stdio`, `kimi acp`, `gemini -p`). The live terminal (PTY) is view and human
take-over only. A CLI without a documented headless or ACP mode cannot be automated.

**How the code enforces it.** The PTY module exposes no write API to the scheduler or lead; only keyboard events from the
UI reach it. Adapters must declare a headless or ACP transport or fail to register.

**Test that proves it.** Architecture test: the scheduler and lead modules cannot import the PTY write function
(dependency rule in CI). Adapter registry test rejects an adapter without a headless or ACP transport.

## 4. Never touch CLI credentials

**Design constraint.** No code path in the app reads, copies, syncs, backs up, logs, uploads or shares any CLI's stored
credentials or tokens. Each CLI handles its own login, in its own terminal.

**How the code enforces it.** All app file access goes through one file-access layer with a denylist of CLI home
directories (`~/.claude`, `~/.codex`, `~/.grok`, `~/.kimi-code`, `~/.gemini`) and the macOS Keychain items those CLIs
own. Worktrees, MCP shares, crash reports and logs exclude those paths. Child CLIs get only the environment they need.
(macOS App Sandbox would also sandbox the child CLIs and break them, so enforcement is code, CI and runtime tests, and the
app ships notarized outside the Mac App Store.)

**Test that proves it.** CI static check fails on those path strings or Keychain service names outside the denylist file.
Runtime canary test: fake credential files are planted, a full session is run, and file-access tracing confirms the app
process never opened them.

## 5. Personal subscriptions stay personal

**Design constraint.** One person, their own machine, their own logins. No remote access to sessions, no shared team server
for subscription sessions, no relaying one user's subscription to another person.

**How the code enforces it.** The app binds only to localhost, has no remote-control or multi-seat mode for subscription
providers, and onboarding has the user confirm each login is their own personal account. Any future team features require
every member to sign in with their own account on their own machine.

**Test that proves it.** Network test: no listening port reachable from outside localhost. Test that the team features
(when built) refuse to route a task to another member's subscription session.

## 6. Official, unmodified binaries only

**Design constraint.** The app never bundles, patches, wraps-and-replaces or redistributes a provider CLI. Users install it
themselves, or the app runs the provider's official installer from the provider's official URL after the user confirms.
Versions are verified before use.

**How the code enforces it.** On startup and on version change the app checks the binary: macOS code signature
(`codesign --verify`) where the vendor signs it, the vendor-published checksum or package integrity where one exists, and
that the install path came from the official source. It records the version and refuses automation on a binary that fails
verification, falling back to view-only.

**Test that proves it.** Tests with a tampered copy and an unsigned look-alike binary: both must be refused for
automation. CI check that the app bundle contains no provider binaries.

## 7. Gemini on API key only

**Design constraint.** Gemini CLI is driven only with the user's Gemini API key or Vertex credentials. The app never starts
or offers Google account sign-in for Gemini.

**How the code enforces it.** The Gemini adapter launches only with an API key from the app's own Keychain item and the
CLI's documented API-key auth mode. No key means Gemini is disabled. The adapter has no code path that opens a Google login.

**Test that proves it.** Test: with no API key, Gemini cannot be selected for any role. Test: the adapter's launch
environment always sets the API-key auth mode.

## 8. No logos, no implied partnership

**Design constraint.** Providers appear as plain-text names only. No provider logos, icons, brand colors or wording that
suggests endorsement. The app name contains no provider trademark. The About screen and website state the app is
independent and not affiliated with or endorsed by any provider.

**How the code enforces it.** Provider names come from one strings file; the asset folder has no provider images.

**Test that proves it.** CI check fails on image assets or SVGs matching provider names, and on provider trademarks in the
app name, bundle ID or marketing copy files.

## 9. User approves every plan

**Design constraint.** No worker starts without user approval of that plan. Any change of provider, scope or estimated usage
beyond the approved plan needs new approval. Failover is allowed only to providers listed in the approved plan.

**How the code enforces it.** The scheduler accepts only plans carrying an approval token created by a UI click, tied to the
plan's hash.

**Test that proves it.** Test: an unapproved or edited plan is rejected. Test: failover to a provider not in the approved
plan is blocked.

## 10. Pacing and backoff

**Design constraint.** Automated traffic stays human-paced. No retry storms.

**How the code enforces it.** At least 5 seconds between dispatches per provider. Exponential backoff starting at 60
seconds after any rate-limit error. After 3 limit errors in a row, that provider is paused until its reset time or until
the user resumes it.

**Test that proves it.** Tests drive fake limit errors and assert the backoff timings and the pause.

## 11. Spend caps that can't be removed

**Design constraint.** Every API-key provider has a daily and weekly spend cap that must be set to a number. Subscription
providers show estimated usage against the ceilings in rule 1.

**How the code enforces it.** Onboarding cannot finish without caps. The setting has no unlimited value. At the cap, work
pauses and asks.

**Test that proves it.** Test: config with no cap or an unlimited cap fails validation.

## 12. Terms-change watch and kill switch

**Design constraint.** Every release re-checks each provider's terms. Any adapter can be shut off remotely if a provider's
rules change.

**How the code enforces it.** Release checklist step: re-read each provider's terms pages (listed below) and sign off. A
weekly job snapshots those pages and flags changes. A signed remote config, checked at launch, can disable an adapter or
force it to API-key-only. If the config can't be fetched, the last known config stays in force.

**Test that proves it.** Release is blocked without the terms sign-off. Test: a signed kill-switch config disables the
adapter within one launch; an unsigned config is ignored.

---

## What the app can't control

These rules keep the app inside each provider's published terms as of October 23, 2026. Providers can change their
terms, billing or idea of "ordinary use" at any time, as Anthropic, Google and OpenAI did in 2026. The terms watch and
kill switch keep you fast to react, but **provider rule changes are the risk that remains.**

**This is not legal advice. Have a lawyer review the terms, these rules and your own terms of use before any commercial launch.**

## Terms pages to re-check every release (rule 12)

- Anthropic, Claude Code legal and compliance: https://code.claude.com/docs/en/legal-and-compliance
- Anthropic, logging in / third-party tools: https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account
- Anthropic, Agent SDK and `claude -p` with plans: https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan
- OpenAI, using your ChatGPT plan in other apps: https://help.openai.com/en/articles/20001542-using-your-chatgpt-plan-in-other-apps-and-sites
- OpenAI, Sign in with ChatGPT: https://developers.openai.com/siwc/quickstart
- xAI, Grok Build: https://x.ai/news/grok-build-cli and https://docs.x.ai/build/cli/headless-scripting
- Google, Gemini CLI terms: https://geminicli.com/docs/resources/tos-privacy/
- Kimi, third-party agents: https://www.kimi.com/zh-cn/help/kimi-code/third-party-agents
- Z.ai, GLM Coding Plan usage policy: https://docs.z.ai/devpack/usage-policy
