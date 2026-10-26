# T-101 appendix: Harness IPC contract v1 (UI ⇄ backend)

Status: proposed with T-101 (approval revoked 2026-10-26). T-101 implements it exactly: types in `src/lib/ipc/contract.ts`,
Tauri client in `src/lib/ipc/tauri.ts`, stateful mock in `src/lib/ipc/mock/**` + `src/lib/ipc/fixtures/*.json`, Rust
stubs in `src-tauri/src/commands.rs`. Screen briefs consume it and never edit it; if one needs a change, it stops and
reports to the lead.

## Conventions
- Command names, argument keys and payload fields are snake_case (as in docs/spec); Rust uses
  `#[tauri::command(rename_all = "snake_case")]`. TS methods have the command's name and take one args object.
  Times are RFC 3339 UTC strings; money is USD.
- Every command rejects only with `IpcError`. Compliance refusals are `kind: "rule_blocked"` + `rule`; the UI shows
  "Blocked by rule N: <message>".
- Events carry full snapshots; the UI replaces its cached copy (TanStack Query `setQueryData`).
- Model, CLI and worker text in any field is untrusted: render with `UntrustedText`, never as HTML or markdown.
- `Plan`, `Task`, `Approval` mirror `docs/spec/plan.schema.json` as merged from T-005 (the in-flight revision adds
  `format_version`, `lead.auth_mode` and `{provider, auth_mode}` fallbacks; follow the merged schema). `Handoff` is
  the parser output in `docs/spec/handoff.md`.

## Boundaries (ESLint import zones + T-101 grep tests)
| Module | Importable only from | Why |
|---|---|---|
| `@/lib/ipc/pty-input` (`usePtyInput()` → `PtyInputPort.pty_write`) | `src/features/sessions/terminal/**` | rule 3 |
| `@/lib/ipc/approval` (`useApproval()` → `ApprovalPort.approve_plan`) | `src/features/plan/**` | rule 9 |
| `@xterm/*` | `src/features/sessions/terminal/**` | rule 3 |
| `@tauri-apps/api`, `@tauri-apps/api/*` | `src/lib/ipc/**` | one IPC door |
| `@/lib/ipc/mock/*`, `@/lib/ipc/fixtures/*` | `src/lib/ipc/**`, `src/test/**`, `**/*.test.ts(x)` | mock never ships |
| `motion`, `motion/*`, `@/components/motion-primitives/*` | `src/components/motion/**` (+ the primitives) | reduced motion |
| `src/features/<a>/**` | not from `src/features/<b>/**`; `src/app/routes.tsx` may import each feature index | independent briefs |

`IpcClient` (`useIpc()`) has no generic `invoke(name)`; only the port modules and `tauri.ts` call `invoke`.

## Types (TypeScript; `ProviderId` is declared in `src/strings/providers.ts`)
```ts
type ProviderId = "claude" | "codex" | "grok" | "kimi" | "gemini" | "glm";  type AuthMode = "subscription" | "api_key";
interface IpcError { kind: "not_found" | "invalid_input" | "rule_blocked" | "plan_hash_mismatch" | "plan_has_violations"
  | "rate_limited" | "not_implemented" | "internal"; message: string; rule?: number; retry_at?: string }
interface AppInfo { name: string; version: string; identifier: string }
interface SpendCaps { daily_usd: number; weekly_usd: number }   // finite, > 0, <= spend_cap_max, weekly >= daily (rule 11)
type Blocker = "adapter_unavailable" | "not_installed" | "binary_failed" | "binary_unchecked" | "signed_out" | "sign_in_unknown"
  | "personal_use_unconfirmed" | "api_key_missing" | "killswitch_disabled" | "provider_paused";
interface ProviderStatus { provider: ProviderId; adapter_available: boolean;
  auth_modes: AuthMode[];                                   // gemini: ["api_key"] only (rule 7)
  install: { state: "installed" | "not_installed"; version?: string; path?: string; install_hint?: string };
  binary: { state: "verified" | "failed" | "unchecked"; checked_at?: string;                       // rule 6
    checks: { kind: "codesign" | "checksum" | "install_source"; result: "pass" | "fail" | "not_applicable"; detail: string }[] };
  sign_in: { state: "signed_in" | "signed_out" | "unknown"; checked_at?: string };  // CLI's documented status output only (rule 4)
  personal_use_confirmed: boolean;                          // rule 5
  api_key: { present: boolean; caps: SpendCaps | null } | null;   // null = no api_key mode; the key is never returned
  killswitch: "enabled" | "disabled" | "api_key_only";      // rule 12
  usable: { lead: boolean; worker: boolean; blockers: Blocker[] } }  // backend-computed; the UI never overrides it
interface LeadRequest { request_id: string; lead: ProviderId; text: string; created_at: string;
  state: "thinking" | "plan_ready" | "rate_limited" | "error" | "cancelled";
  messages: { at: string; text: string }[]; plan_id?: string; error?: string; retry_at?: string }
interface PlanListItem { plan_id: string; created_at: string; lead: ProviderId; status: PlanView["status"]; task_count: number }
interface PlanView { plan: Plan; plan_hash: string; status: "draft" | "approved" | "superseded" | "running" | "done";
  violations: { rule: number; message: string; task_id?: string }[];   // backend check (mirrors spike/plan/check.jq)
  estimates: { provider: ProviderId; auth_mode: AuthMode; prompts: number; max_task_turns: number }[];
  needs_reapproval: boolean }                                // true when an edit voided an earlier approval
type PlanEdit = { kind: "set_provider"; task_id: string; provider: ProviderId; auth_mode: AuthMode }
  | { kind: "set_fallbacks"; task_id: string; fallback_providers: Task["fallback_providers"] }
  | { kind: "set_acceptance"; task_id: string; acceptance: string[] } | { kind: "remove_task"; task_id: string };
type SessionState = { kind: "spawning" } | { kind: "running" } | { kind: "idle" }   // T-004 state machine
  | { kind: "rate_limited"; retry_at: string; attempt: number; consecutive_limit_errors: number }
  | { kind: "exited"; code?: number; signal?: string } | { kind: "killed" };
type PauseReason = "user" | "user_idle" | "app_background" | "takeover" | "limit_errors" | "ceiling" | "spend_cap" | "killswitch";
interface SessionView { session_id: string; kind: "worker" | "login"; provider: ProviderId; task_id?: string; plan_id?: string;
  title?: string; role?: string; branch?: string; worktree?: string; state: SessionState;
  paused: { reason: PauseReason; until?: string } | null; turns: { current: number; limit: number };
  started_at: string; takeover: boolean }                    // login sessions start with takeover = true (backend sets it)
interface TerminalChunk { session_id: string; seq: number; data_b64: string }   // raw PTY bytes, untrusted
interface ReviewListItem { task_id: string; plan_id: string; title: string; provider: ProviderId; state: "running" | "ready" | "reviewed" | "failed" }
interface ReviewView { task_id: string; plan_id: string; title: string; provider: ProviderId; branch: string; worktree: string;
  owned_files: string[]; diff: { text: string; truncated: boolean };   // unified diff
  test_log: { status: "passed" | "failed" | "not_run"; command: string; exit_code: number | null; output: string; truncated: boolean };
  handoff: { ok: true; data: Handoff } | { ok: false; error: string };
  lead_summary: { text: string; tokens: number; budget: number;
    links: { kind: "diff" | "test_log" | "handoff"; task_id: string; path?: string }[] } | null;
  reviewed: boolean }
interface Meter { current: number; limit: number; ceiling: number }   // limit = the user's stricter value, else the ceiling
interface ProviderUsage { provider: ProviderId; auth_mode: AuthMode; sessions: Meter; prompts_last_hour: Meter;
  max_task_turns: Meter & { task_id?: string }; run_minutes_today: Meter;
  pacing: { next_dispatch_at?: string; backoff?: { retry_at: string; attempt: number };
    consecutive_limit_errors: number; paused: boolean; paused_until?: string };
  tokens_today: { input: number; output: number; is_estimate: boolean };
  spend: { today_usd: number; week_usd: number; caps: SpendCaps; is_estimate: boolean } | null }   // api_key only
interface UsageSnapshot { as_of: string; user_idle_minutes: number; idle_pause_minutes: number; app_in_background: boolean; providers: ProviderUsage[] }
type LimitKey = "concurrent_sessions" | "prompts_per_hour" | "turns_per_task" | "run_minutes_per_day"
  | "idle_pause_minutes" | "min_dispatch_gap_s" | "backoff_base_s" | "pause_after_limit_errors";
interface LimitRule { ceiling: number; stricter: "lower" | "higher"; bound: number; unit: "count" | "per_hour" | "minutes" | "seconds" }
interface LimitsInfo { rules: Record<LimitKey, LimitRule>; spend_cap_max: SpendCaps }
interface Settings { summary_budget_tokens: number; limits: Record<LimitKey, number> }
interface KillSwitchStatus { source: "signed_remote" | "last_known" | "none"; fetched_at?: string;
  signature: "valid" | "invalid_ignored" | "absent";
  adapters: { provider: ProviderId; state: "enabled" | "disabled" | "api_key_only"; reason?: string }[] }
```

**Limit rules** (`get_limits`; Rust builds them from `harness-core` consts). Integers. `lower`: value in
[bound, ceiling]; `higher`: value in [ceiling, bound]. concurrent_sessions 2 lower 1 · prompts_per_hour 30 lower 1 ·
turns_per_task 40 lower 1 · run_minutes_per_day 480 lower 30 · idle_pause_minutes 30 lower 5 (rule 1) ·
min_dispatch_gap_s 5 higher 600 · backoff_base_s 60 higher 3600 · pause_after_limit_errors 3 lower 1 (rule 10).
Spend-cap max is a placeholder for the human to set: `{daily_usd: 500, weekly_usd: 2000}`.

## Commands
| Command (args) | Returns | Notes |
|---|---|---|
| get_app_info() | AppInfo | |
| list_providers() / refresh_provider_status({provider}) | ProviderStatus[] / ProviderStatus | refresh reruns the CLI status command + binary check |
| open_provider_login({provider}) | {session_id} | CLI's own login in a `login` session; `rule_blocked` 7 if api-key-only, 6 if binary failed |
| confirm_personal_use({provider}) | ProviderStatus | rule 5 |
| set_api_key({provider, key, caps}) / update_spend_caps({provider, caps}) / remove_api_key({provider}) | ProviderStatus | caps required (rule 11); key goes to Keychain, never echoed |
| start_lead_request({lead, text}) / cancel_lead_request({request_id}) / list_lead_requests() | {request_id} / void / LeadRequest[] | one in-flight request at a time |
| list_plans() / get_plan({plan_id}) / update_plan({plan_id, edit}) / discard_plan({plan_id}) | PlanListItem[] / PlanView / PlanView / void | every edit returns a new hash and drops the approval |
| **approve_plan({plan_id, plan_hash})** | PlanView | ApprovalPort only. `plan_hash_mismatch` if stale; `plan_has_violations` if any |
| list_sessions() / pause_session / resume_session / kill_session({session_id}) | SessionView[] / SessionView | resume refused during backoff or at a ceiling (`rule_blocked` 10 / 1) |
| set_takeover({session_id, enabled}) | SessionView | enabling pauses automation (reason `takeover`); disabling leaves it paused until Resume |
| resume_provider({provider}) | void | user resume after 3 limit errors (rule 10) |
| attach_terminal({session_id}) / resize_terminal({session_id, cols, rows}) | {cols, rows, scrollback_b64} / void | |
| **pty_write({session_id, data})** | void | PtyInputPort only. `rule_blocked` 3 unless that session's takeover is on |
| list_reviews() / get_review({task_id}) / mark_reviewed({task_id}) | ReviewListItem[] / ReviewView / ReviewView | |
| get_usage() / get_limits() | UsageSnapshot / LimitsInfo | |
| get_settings() / update_settings({patch}) | Settings | patch `{summary_budget_tokens?, limits?: Partial<Record<LimitKey, number>>}`; looser than a ceiling → `rule_blocked` 1/10 |
| get_killswitch_status() | KillSwitchStatus | read-only (rule 12) |

**Events** (`useIpcEvent(name, handler)`): `provider_changed` ProviderStatus · `lead_changed` LeadRequest ·
`plan_changed` PlanView · `session_changed` SessionView · `terminal_output` TerminalChunk · `usage_changed` UsageSnapshot.

**Routes** (`src/app/paths.ts`): `/` → `/lead` · `/providers` · `/lead` · `/plans`, `/plans/:planId` · `/sessions`,
`/sessions/:sessionId` · `/review`, `/review/:taskId?tab=diff|tests|handoff` · `/usage` · `/settings` · `/about`.

## Mock (`createMockIpc({ scenario, now? })` → `{ client, approval, ptyInput, control }`)
- **Scenarios:** `ready` (default; MVP providers usable, gemini without key), `fresh` (signed out, unconfirmed, not
  installed), `binary_failed`, `killswitch` (a provider disabled, last-known config), `plan_draft`,
  `plan_violations` (turns over 40, duplicate fallback, fallback not in plan), `running` (worker + streaming terminal
  output), `rate_limited` (retry in 60 s; control can push it to 3 errors and a paused provider), `review_ready`,
  `review_injection` (hostile HANDOFF/diff/log text), `review_handoff_error`, `api_key` (gemini key with caps and
  spend), `errors` (every command rejects with `internal`).
- **Control:** `advance(ms)` on a fake clock (lead thinks for 1.5 s, then `plan_ready`); `emit(event, payload)`;
  `failNext(command, IpcError)`; `setUserIdle(min)`; `calls` records every `{command, args}` (tests assert, e.g.,
  zero `pty_write`).
- **Mirrors backend refusals:** missing or out-of-range caps; looser limits; stale hash or open violations on
  approve; an edit drops the approval; `pty_write` without takeover; login for an api-key-only provider; resume
  during backoff; the key is never echoed. Plan hash = SHA-256 of key-sorted JSON (WebCrypto), enough for a mock.
- Contains the sentinel `__HARNESS_MOCK__`; `make check` fails if it reaches `dist/`.
- **Client selection** (`src/lib/ipc/index.ts`): production builds always use `tauri.ts`; dev uses the mock unless
  `VITE_HARNESS_IPC=tauri`. The mock loads by dynamic `import()` on the dev path only, so it tree-shakes out.

## Rust stubs (`src-tauri/src/commands.rs`)
Every command above exists, is registered, and is listed in `build.rs` (AppManifest) and `capabilities/main.json`.
Reads return fixture JSON via `include_str!("../../src/lib/ipc/fixtures/<name>.json")`; `get_limits` builds from
`harness_core::compliance::ceilings`; `get_app_info` uses the package info. Mutations return
`IpcError{kind: "not_implemented"}`; `approve_plan` never mints an approval; `pty_write` refuses (`rule_blocked` 3).
