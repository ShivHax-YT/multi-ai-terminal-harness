// Harness IPC contract v1 (UI <-> backend). Spec: docs/tasks/T-101-ipc-contract.md. Screen briefs consume this file
// and never edit it; a change is a lead commit.
//
// Conventions: snake_case commands, argument keys and payload fields; times are RFC 3339 UTC strings; money is USD.
// Every command rejects only with IpcError. Any model, CLI or worker text in any field is untrusted: render it with
// UntrustedText, never as HTML or markdown.

import type { ProviderId } from "@/strings/providers";

export type { ProviderId };

export type AuthMode = "subscription" | "api_key";

// ---- errors -----------------------------------------------------------------------------------------------------

export type IpcErrorKind =
  | "not_found"
  | "invalid_input"
  | "rule_blocked"
  | "plan_hash_mismatch"
  | "plan_has_violations"
  | "rate_limited"
  | "not_implemented"
  | "internal";

export interface IpcError {
  kind: IpcErrorKind;
  message: string;
  rule?: number;
  retry_at?: string;
}

const ERROR_KINDS: readonly IpcErrorKind[] = [
  "not_found",
  "invalid_input",
  "rule_blocked",
  "plan_hash_mismatch",
  "plan_has_violations",
  "rate_limited",
  "not_implemented",
  "internal",
];

/** The value every command rejects with: an Error (so stacks and `instanceof` work) that is also an IpcError. */
export class IpcRejection extends Error implements IpcError {
  readonly kind: IpcErrorKind;
  readonly rule?: number;
  readonly retry_at?: string;

  constructor(error: IpcError) {
    super(error.message);
    this.name = "IpcRejection";
    this.kind = error.kind;
    if (error.rule !== undefined) this.rule = error.rule;
    if (error.retry_at !== undefined) this.retry_at = error.retry_at;
  }

  toJSON(): IpcError {
    const out: IpcError = { kind: this.kind, message: this.message };
    if (this.rule !== undefined) out.rule = this.rule;
    if (this.retry_at !== undefined) out.retry_at = this.retry_at;
    return out;
  }
}

export function isIpcError(value: unknown): value is IpcError {
  if (typeof value !== "object" || value === null) return false;
  const v = value as Record<string, unknown>;
  return (
    typeof v.kind === "string" &&
    (ERROR_KINDS as readonly string[]).includes(v.kind) &&
    typeof v.message === "string" &&
    (v.rule === undefined || typeof v.rule === "number") &&
    (v.retry_at === undefined || typeof v.retry_at === "string")
  );
}

/** Normalizes anything thrown by a transport into an IpcRejection (unknown shapes become `internal`). */
export function toIpcRejection(value: unknown): IpcRejection {
  if (value instanceof IpcRejection) return value;
  if (isIpcError(value)) return new IpcRejection(value);
  const message =
    value instanceof Error ? value.message : typeof value === "string" ? value : "IPC failure";
  return new IpcRejection({ kind: "internal", message });
}

// ---- plan, task, approval (mirror docs/spec/plan.schema.json) and handoff (docs/spec/handoff.md) -----------------

export interface ProviderAuth {
  provider: ProviderId;
  auth_mode: AuthMode;
}

export interface Task {
  id: string;
  title: string;
  role: string;
  provider: ProviderId;
  auth_mode: AuthMode;
  owned_files: string[];
  acceptance: string[];
  depends_on: string[];
  estimated_usage: { prompts: number; turns: number };
  fallback_providers: ProviderAuth[];
}

export interface Approval {
  plan_hash: string;
  approved_at: string;
  approved_via: "ui";
  nonce: string;
}

export interface Plan {
  format_version: 1;
  plan_id: string;
  created_at: string;
  lead: ProviderAuth;
  request_summary: string;
  summary_budget_tokens: number;
  tasks: Task[];
  approval?: Approval;
}

export interface Handoff {
  task_id: string;
  summary: string;
  files_changed: { path: string; note: string }[];
  tests_run: string;
  hard_rules: string[];
  risks: string;
  confidence: { level: "low" | "medium" | "high"; why: string };
}

// ---- app and providers --------------------------------------------------------------------------------------------

export interface AppInfo {
  name: string;
  version: string;
  identifier: string;
}

/** Finite, > 0, <= spend_cap_max, weekly >= daily (rule 11). */
export interface SpendCaps {
  daily_usd: number;
  weekly_usd: number;
}

export type Blocker =
  | "adapter_unavailable"
  | "not_installed"
  | "binary_failed"
  | "binary_unchecked"
  | "signed_out"
  | "sign_in_unknown"
  | "personal_use_unconfirmed"
  | "api_key_missing"
  | "killswitch_disabled"
  | "provider_paused";

export type KillSwitchState = "enabled" | "disabled" | "api_key_only";

export interface BinaryCheck {
  kind: "codesign" | "checksum" | "install_source";
  result: "pass" | "fail" | "not_applicable";
  detail: string;
}

export interface ProviderStatus {
  provider: ProviderId;
  adapter_available: boolean;
  /** API-key-only providers list ["api_key"] only (rule 7). */
  auth_modes: AuthMode[];
  install: {
    state: "installed" | "not_installed";
    version?: string;
    path?: string;
    install_hint?: string;
  };
  /** Rule 6. */
  binary: {
    state: "verified" | "failed" | "unchecked";
    checked_at?: string;
    checks: BinaryCheck[];
  };
  /** From the CLI's documented status output only (rule 4). */
  sign_in: { state: "signed_in" | "signed_out" | "unknown"; checked_at?: string };
  /** Rule 5. */
  personal_use_confirmed: boolean;
  /** null = no api_key mode; the key itself is never returned. */
  api_key: { present: boolean; caps: SpendCaps | null } | null;
  /** Rule 12. */
  killswitch: KillSwitchState;
  /** Backend-computed; the UI never overrides it. */
  usable: { lead: boolean; worker: boolean; blockers: Blocker[] };
}

// ---- lead and plans -----------------------------------------------------------------------------------------------

export interface LeadRequest {
  request_id: string;
  lead: ProviderId;
  text: string;
  created_at: string;
  state: "thinking" | "plan_ready" | "rate_limited" | "error" | "cancelled";
  messages: { at: string; text: string }[];
  plan_id?: string;
  error?: string;
  retry_at?: string;
}

export type PlanStatus = "draft" | "approved" | "superseded" | "running" | "done";

export interface PlanViolation {
  rule: number;
  message: string;
  task_id?: string;
}

export interface PlanEstimate {
  provider: ProviderId;
  auth_mode: AuthMode;
  prompts: number;
  max_task_turns: number;
}

export interface PlanView {
  plan: Plan;
  plan_hash: string;
  status: PlanStatus;
  /** Backend check (mirrors spike/plan/check.jq). */
  violations: PlanViolation[];
  estimates: PlanEstimate[];
  /** True when an edit voided an earlier approval. */
  needs_reapproval: boolean;
}

export interface PlanListItem {
  plan_id: string;
  created_at: string;
  lead: ProviderId;
  status: PlanView["status"];
  task_count: number;
}

export type PlanEdit =
  | { kind: "set_provider"; task_id: string; provider: ProviderId; auth_mode: AuthMode }
  | { kind: "set_fallbacks"; task_id: string; fallback_providers: Task["fallback_providers"] }
  | { kind: "set_acceptance"; task_id: string; acceptance: string[] }
  | { kind: "remove_task"; task_id: string };

// ---- sessions and terminals ---------------------------------------------------------------------------------------

/** T-004 state machine. */
export type SessionState =
  | { kind: "spawning" }
  | { kind: "running" }
  | { kind: "idle" }
  | { kind: "rate_limited"; retry_at: string; attempt: number; consecutive_limit_errors: number }
  | { kind: "exited"; code?: number; signal?: string }
  | { kind: "killed" };

export type PauseReason =
  | "user"
  | "user_idle"
  | "app_background"
  | "takeover"
  | "limit_errors"
  | "ceiling"
  | "spend_cap"
  | "killswitch";

export interface SessionView {
  session_id: string;
  kind: "worker" | "login";
  provider: ProviderId;
  task_id?: string;
  plan_id?: string;
  title?: string;
  role?: string;
  branch?: string;
  worktree?: string;
  state: SessionState;
  paused: { reason: PauseReason; until?: string } | null;
  turns: { current: number; limit: number };
  started_at: string;
  /** Login sessions start with takeover = true (the backend sets it). */
  takeover: boolean;
}

/** Raw PTY bytes, base64. Untrusted: render only inside the terminal view. */
export interface TerminalChunk {
  session_id: string;
  seq: number;
  data_b64: string;
}

export interface TerminalAttach {
  cols: number;
  rows: number;
  scrollback_b64: string;
}

// ---- review -------------------------------------------------------------------------------------------------------

export interface ReviewListItem {
  task_id: string;
  plan_id: string;
  title: string;
  provider: ProviderId;
  state: "running" | "ready" | "reviewed" | "failed";
}

export interface ReviewLink {
  kind: "diff" | "test_log" | "handoff";
  task_id: string;
  path?: string;
}

export interface ReviewView {
  task_id: string;
  plan_id: string;
  title: string;
  provider: ProviderId;
  branch: string;
  worktree: string;
  owned_files: string[];
  /** Unified diff. */
  diff: { text: string; truncated: boolean };
  test_log: {
    status: "passed" | "failed" | "not_run";
    command: string;
    exit_code: number | null;
    output: string;
    truncated: boolean;
  };
  handoff: { ok: true; data: Handoff } | { ok: false; error: string };
  lead_summary: { text: string; tokens: number; budget: number; links: ReviewLink[] } | null;
  reviewed: boolean;
}

// ---- usage, limits, settings, kill switch -------------------------------------------------------------------------

/** limit = the user's stricter value, else the ceiling. */
export interface Meter {
  current: number;
  limit: number;
  ceiling: number;
}

export interface ProviderUsage {
  provider: ProviderId;
  auth_mode: AuthMode;
  sessions: Meter;
  prompts_last_hour: Meter;
  max_task_turns: Meter & { task_id?: string };
  run_minutes_today: Meter;
  pacing: {
    next_dispatch_at?: string;
    backoff?: { retry_at: string; attempt: number };
    consecutive_limit_errors: number;
    paused: boolean;
    paused_until?: string;
  };
  tokens_today: { input: number; output: number; is_estimate: boolean };
  /** api_key only. */
  spend: { today_usd: number; week_usd: number; caps: SpendCaps; is_estimate: boolean } | null;
}

export interface UsageSnapshot {
  as_of: string;
  user_idle_minutes: number;
  idle_pause_minutes: number;
  app_in_background: boolean;
  providers: ProviderUsage[];
}

export const LIMIT_KEYS = [
  "concurrent_sessions",
  "prompts_per_hour",
  "turns_per_task",
  "run_minutes_per_day",
  "idle_pause_minutes",
  "min_dispatch_gap_s",
  "backoff_base_s",
  "pause_after_limit_errors",
] as const;

export type LimitKey = (typeof LIMIT_KEYS)[number];

/** Integers. `lower`: value in [bound, ceiling]; `higher`: value in [ceiling, bound]. */
export interface LimitRule {
  ceiling: number;
  stricter: "lower" | "higher";
  bound: number;
  unit: "count" | "per_hour" | "minutes" | "seconds";
}

export interface LimitsInfo {
  rules: Record<LimitKey, LimitRule>;
  spend_cap_max: SpendCaps;
}

export interface Settings {
  summary_budget_tokens: number;
  limits: Record<LimitKey, number>;
}

export interface SettingsPatch {
  summary_budget_tokens?: number;
  limits?: Partial<Record<LimitKey, number>>;
}

export interface KillSwitchStatus {
  source: "signed_remote" | "last_known" | "none";
  fetched_at?: string;
  signature: "valid" | "invalid_ignored" | "absent";
  adapters: { provider: ProviderId; state: KillSwitchState; reason?: string }[];
}

// ---- commands -----------------------------------------------------------------------------------------------------

/** Every command, in contract order. Must equal lib.rs generate_handler!, build.rs and the capability (parity test). */
export const COMMANDS = [
  "get_app_info",
  "list_providers",
  "refresh_provider_status",
  "open_provider_login",
  "confirm_personal_use",
  "set_api_key",
  "update_spend_caps",
  "remove_api_key",
  "start_lead_request",
  "cancel_lead_request",
  "list_lead_requests",
  "list_plans",
  "get_plan",
  "update_plan",
  "discard_plan",
  "approve_plan",
  "list_sessions",
  "pause_session",
  "resume_session",
  "kill_session",
  "set_takeover",
  "resume_provider",
  "attach_terminal",
  "resize_terminal",
  "pty_write",
  "list_reviews",
  "get_review",
  "mark_reviewed",
  "get_usage",
  "get_limits",
  "get_settings",
  "update_settings",
  "get_killswitch_status",
] as const;

export type CommandName = (typeof COMMANDS)[number];

/** Commands reachable only through a port module (rule 9: ApprovalPort; rule 3: PtyInputPort). */
export type PortCommandName = "approve_plan" | "pty_write";

export interface ProviderArgs {
  provider: ProviderId;
}
export interface PlanArgs {
  plan_id: string;
}
export interface SessionArgs {
  session_id: string;
}
export interface TaskArgs {
  task_id: string;
}

/** The general client (`useIpc()`). It has no generic invoke and no approve_plan or pty_write. */
export interface IpcClient {
  get_app_info(): Promise<AppInfo>;

  list_providers(): Promise<ProviderStatus[]>;
  refresh_provider_status(args: ProviderArgs): Promise<ProviderStatus>;
  open_provider_login(args: ProviderArgs): Promise<{ session_id: string }>;
  confirm_personal_use(args: ProviderArgs): Promise<ProviderStatus>;
  set_api_key(args: {
    provider: ProviderId;
    key: string;
    caps: SpendCaps;
  }): Promise<ProviderStatus>;
  update_spend_caps(args: { provider: ProviderId; caps: SpendCaps }): Promise<ProviderStatus>;
  remove_api_key(args: ProviderArgs): Promise<ProviderStatus>;

  start_lead_request(args: { lead: ProviderId; text: string }): Promise<{ request_id: string }>;
  cancel_lead_request(args: { request_id: string }): Promise<void>;
  list_lead_requests(): Promise<LeadRequest[]>;

  list_plans(): Promise<PlanListItem[]>;
  get_plan(args: PlanArgs): Promise<PlanView>;
  update_plan(args: { plan_id: string; edit: PlanEdit }): Promise<PlanView>;
  discard_plan(args: PlanArgs): Promise<void>;

  list_sessions(): Promise<SessionView[]>;
  pause_session(args: SessionArgs): Promise<SessionView>;
  resume_session(args: SessionArgs): Promise<SessionView>;
  kill_session(args: SessionArgs): Promise<SessionView>;
  set_takeover(args: { session_id: string; enabled: boolean }): Promise<SessionView>;
  resume_provider(args: ProviderArgs): Promise<void>;
  attach_terminal(args: SessionArgs): Promise<TerminalAttach>;
  resize_terminal(args: { session_id: string; cols: number; rows: number }): Promise<void>;

  list_reviews(): Promise<ReviewListItem[]>;
  get_review(args: TaskArgs): Promise<ReviewView>;
  mark_reviewed(args: TaskArgs): Promise<ReviewView>;

  get_usage(): Promise<UsageSnapshot>;
  get_limits(): Promise<LimitsInfo>;
  get_settings(): Promise<Settings>;
  update_settings(args: { patch: SettingsPatch }): Promise<Settings>;
  get_killswitch_status(): Promise<KillSwitchStatus>;

  /** Subscribe to a backend event. Events carry full snapshots. Resolves to an unsubscribe function. */
  listen<E extends IpcEventName>(
    event: E,
    handler: (payload: IpcEvents[E]) => void,
  ): Promise<() => void>;
}

/** Rule 9: the only way to approve a plan. Importable only from src/features/plan/**. */
export interface ApprovalPort {
  approve_plan(args: { plan_id: string; plan_hash: string }): Promise<PlanView>;
}

/** Rule 3: the only way to type into a PTY (human keystrokes, take-over on). Importable only from the terminal view. */
export interface PtyInputPort {
  /** `data` is UTF-8 text from xterm.js onData. */
  pty_write(args: { session_id: string; data: string }): Promise<void>;
}

/** What a transport (Tauri or the dev mock) provides. Ports are handed out only by their own modules. */
export interface IpcBundle {
  client: IpcClient;
  approval: ApprovalPort;
  ptyInput: PtyInputPort;
}

// ---- events -------------------------------------------------------------------------------------------------------

export interface IpcEvents {
  provider_changed: ProviderStatus;
  lead_changed: LeadRequest;
  plan_changed: PlanView;
  session_changed: SessionView;
  terminal_output: TerminalChunk;
  usage_changed: UsageSnapshot;
}

export type IpcEventName = keyof IpcEvents;

export const EVENT_NAMES = [
  "provider_changed",
  "lead_changed",
  "plan_changed",
  "session_changed",
  "terminal_output",
  "usage_changed",
] as const satisfies readonly IpcEventName[];

// Compile-time checks: COMMANDS = client methods + port commands, and EVENT_NAMES = IpcEvents keys.
type ClientCommandName = Exclude<keyof IpcClient, "listen">;
type Equals<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false;
const commandsMatchClient: Equals<CommandName, ClientCommandName | PortCommandName> = true;
const eventsMatch: Equals<(typeof EVENT_NAMES)[number], IpcEventName> = true;
/** True by construction; a drift between the lists above fails to compile. */
export const CONTRACT_SELF_CHECK: readonly [true, true] = [commandsMatchClient, eventsMatch];
