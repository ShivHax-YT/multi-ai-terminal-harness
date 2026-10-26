// Stateful dev/test mock of the Harness backend (contract v1). It mirrors the backend's refusals so screens can be
// built and tested against them; it is never part of a production build (see ./index.ts and `make check`).

import { MVP_PROVIDER_IDS, isProviderId, type ProviderId } from "@/strings/providers";
import { bytesToBase64, utf8ToBase64 } from "@/lib/base64";
import {
  IpcRejection,
  LIMIT_KEYS,
  type ApprovalPort,
  type AuthMode,
  type Blocker,
  type CommandName,
  type IpcClient,
  type IpcError,
  type IpcEventName,
  type IpcEvents,
  type KillSwitchStatus,
  type LeadRequest,
  type LimitKey,
  type LimitsInfo,
  type Plan,
  type PlanEdit,
  type PlanListItem,
  type PlanStatus,
  type PlanView,
  type ProviderStatus,
  type ProviderUsage,
  type PtyInputPort,
  type ReviewListItem,
  type ReviewView,
  type SessionView,
  type Settings,
  type SettingsPatch,
  type SpendCaps,
  type TerminalAttach,
  type UsageSnapshot,
} from "../contract";
import killswitchJson from "../fixtures/killswitch.json";
import limitsJson from "../fixtures/limits.json";
import planJson from "../fixtures/plan.json";
import planViolationsJson from "../fixtures/plan-violations.json";
import providersJson from "../fixtures/providers.json";
import reviewInjectionJson from "../fixtures/review-injection.json";
import reviewJson from "../fixtures/review.json";
import settingsJson from "../fixtures/settings.json";
import usageJson from "../fixtures/usage.json";
import { checkPlan, planEstimates, planHash } from "./plan";

export const MOCK_SCENARIOS = [
  "ready",
  "fresh",
  "binary_failed",
  "killswitch",
  "plan_draft",
  "plan_violations",
  "running",
  "rate_limited",
  "review_ready",
  "review_injection",
  "review_handoff_error",
  "api_key",
  "errors",
] as const;

export type MockScenario = (typeof MOCK_SCENARIOS)[number];

export interface MockCall {
  command: CommandName;
  args: unknown;
}

/** Terminal scrollback cap per session (bytes). */
export const SCROLLBACK_CAP_BYTES = 256 * 1024;
/** How long the mock lead "thinks" before its plan is ready. */
export const LEAD_THINK_MS = 1500;
const TERMINAL_TICK_MS = 400;
const HOUR_MS = 60 * 60 * 1000;

const RULE_FOR_LIMIT: Record<LimitKey, 1 | 10> = {
  concurrent_sessions: 1,
  prompts_per_hour: 1,
  turns_per_task: 1,
  run_minutes_per_day: 1,
  idle_pause_minutes: 1,
  min_dispatch_gap_s: 10,
  backoff_base_s: 10,
  pause_after_limit_errors: 10,
};

function clone<T>(value: unknown): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

function reject(error: IpcError): never {
  throw new IpcRejection(error);
}

function notFound(what: string): never {
  return reject({ kind: "not_found", message: `${what} not found` });
}

function invalid(message: string): never {
  return reject({ kind: "invalid_input", message });
}

function ruleBlocked(rule: number, message: string, retryAt?: string): never {
  const error: IpcError = { kind: "rule_blocked", rule, message };
  if (retryAt !== undefined) error.retry_at = retryAt;
  return reject(error);
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function randomHex(bytes: number): string {
  const buf = new Uint8Array(bytes);
  crypto.getRandomValues(buf);
  return [...buf].map((b) => b.toString(16).padStart(2, "0")).join("");
}

interface PlanRecord {
  plan: Plan;
  status: PlanStatus;
  needs_reapproval: boolean;
}

interface TerminalRecord {
  cols: number;
  rows: number;
  bytes: Uint8Array;
  seq: number;
}

interface ProviderPacing {
  consecutive_limit_errors: number;
  paused: boolean;
  paused_until?: string;
  backoff?: { retry_at: string; attempt: number };
}

interface Timer {
  id: number;
  at: number;
  fn: () => void | Promise<void>;
  every?: number;
}

type Listener = (payload: never) => void;

export class MockBackend {
  readonly scenario: MockScenario;
  readonly calls: MockCall[] = [];

  private nowMs: number;
  private timers: Timer[] = [];
  private timerSeq = 0;
  private idSeq = 0;
  private listeners = new Map<IpcEventName, Set<Listener>>();
  private failures = new Map<CommandName, IpcError[]>();
  private ready: Promise<void>;

  private providers = new Map<ProviderId, ProviderStatus>();
  private pacing = new Map<ProviderId, ProviderPacing>();
  private apiKeys = new Map<ProviderId, string>();
  private usage: UsageSnapshot;
  private settings: Settings;
  private readonly limits: LimitsInfo;
  private killswitch: KillSwitchStatus;
  private leadRequests: LeadRequest[] = [];
  private plans = new Map<string, PlanRecord>();
  private sessions = new Map<string, SessionView>();
  private terminals = new Map<string, TerminalRecord>();
  private reviews = new Map<string, ReviewView>();

  constructor(scenario: MockScenario, now: number) {
    this.scenario = scenario;
    this.nowMs = now;
    for (const status of clone<ProviderStatus[]>(providersJson)) {
      this.providers.set(status.provider, status);
      this.pacing.set(status.provider, { consecutive_limit_errors: 0, paused: false });
    }
    this.usage = clone<UsageSnapshot>(usageJson);
    this.settings = clone<Settings>(settingsJson);
    this.limits = clone<LimitsInfo>(limitsJson);
    this.killswitch = clone<KillSwitchStatus>(killswitchJson);
    this.ready = this.setup();
  }

  // ---- clock, timers, events, failure injection ------------------------------------------------------------------

  nowIso(offsetMs = 0): string {
    return new Date(this.nowMs + offsetMs).toISOString();
  }

  private schedule(delayMs: number, fn: () => void | Promise<void>, every?: number): number {
    this.timerSeq += 1;
    const timer: Timer = { id: this.timerSeq, at: this.nowMs + delayMs, fn };
    if (every !== undefined) timer.every = every;
    this.timers.push(timer);
    return timer.id;
  }

  private cancelTimer(id: number | undefined): void {
    if (id === undefined) return;
    this.timers = this.timers.filter((t) => t.id !== id);
  }

  async advance(ms: number): Promise<void> {
    await this.ready;
    const target = this.nowMs + Math.max(0, ms);
    for (;;) {
      const due = this.timers
        .filter((t) => t.at <= target)
        .sort((a, b) => a.at - b.at || a.id - b.id)[0];
      if (due === undefined) break;
      this.nowMs = due.at;
      if (due.every === undefined) this.cancelTimer(due.id);
      else due.at += due.every;
      await due.fn();
    }
    this.nowMs = target;
  }

  emit<E extends IpcEventName>(event: E, payload: IpcEvents[E]): void {
    const set = this.listeners.get(event);
    if (set === undefined) return;
    for (const listener of [...set]) (listener as (p: IpcEvents[E]) => void)(clone(payload));
  }

  listen<E extends IpcEventName>(event: E, handler: (payload: IpcEvents[E]) => void): () => void {
    let set = this.listeners.get(event);
    if (set === undefined) {
      set = new Set();
      this.listeners.set(event, set);
    }
    const listener = handler as Listener;
    set.add(listener);
    return () => {
      set.delete(listener);
    };
  }

  failNext(command: CommandName, error: IpcError): void {
    const queue = this.failures.get(command) ?? [];
    queue.push(error);
    this.failures.set(command, queue);
  }

  async setUserIdle(minutes: number): Promise<void> {
    await this.ready;
    this.usage.user_idle_minutes = minutes;
    if (minutes >= this.settings.limits.idle_pause_minutes) {
      for (const s of this.sessions.values()) {
        if (s.kind === "worker" && s.paused === null && isLive(s)) {
          s.paused = { reason: "user_idle" };
          this.emit("session_changed", s);
        }
      }
    }
    this.emit("usage_changed", this.usageSnapshot());
  }

  /** Every command goes through here: record, apply injected failures, run, return a copy. */
  private async run<T>(command: CommandName, args: unknown, impl: () => T | Promise<T>): Promise<T> {
    this.calls.push({ command, args: clone(args ?? null) });
    await this.ready;
    const queued = this.failures.get(command);
    const injected = queued?.shift();
    if (injected !== undefined) throw new IpcRejection(injected);
    if (this.scenario === "errors") {
      throw new IpcRejection({ kind: "internal", message: "mock scenario: every command fails" });
    }
    const result = await impl();
    return result === undefined ? result : clone<T>(result);
  }

  // ---- scenario setup --------------------------------------------------------------------------------------------

  private apiKeyOnlyProviders(): Set<ProviderId> {
    const out = new Set<ProviderId>();
    for (const s of this.providers.values()) if (!s.auth_modes.includes("subscription")) out.add(s.provider);
    return out;
  }

  private provider(id: unknown): ProviderStatus {
    if (!isProviderId(id)) return invalid("unknown provider");
    const status = this.providers.get(id);
    return status ?? notFound("provider");
  }

  private secondMvp(): ProviderId {
    return MVP_PROVIDER_IDS[1];
  }

  private async setup(): Promise<void> {
    const s = this.scenario;
    if (s === "fresh") {
      for (const p of this.providers.values()) {
        if (!p.adapter_available) continue;
        p.install = { state: "not_installed" };
        p.binary = { state: "unchecked", checks: [] };
        p.sign_in = { state: "signed_out" };
        p.personal_use_confirmed = false;
      }
      this.usage.providers = [];
    }
    if (s === "binary_failed") {
      const p = this.provider(this.secondMvp());
      p.binary = {
        state: "failed",
        checked_at: this.nowIso(),
        checks: [
          { kind: "codesign", result: "fail", detail: "codesign: code object is not signed at all." },
          { kind: "checksum", result: "not_applicable", detail: "The vendor publishes no checksum for this install method." },
          { kind: "install_source", result: "fail", detail: "Install path does not match the vendor installer." },
        ],
      };
    }
    if (s === "killswitch") {
      const id = this.secondMvp();
      this.killswitch = {
        source: "last_known",
        fetched_at: this.nowIso(-26 * HOUR_MS),
        signature: "valid",
        adapters: this.killswitch.adapters.map((a) =>
          a.provider === id
            ? { provider: id, state: "disabled", reason: "Disabled by the signed config while terms are re-checked." }
            : a,
        ),
      };
      this.provider(id).killswitch = "disabled";
    }
    if (s === "api_key") {
      for (const id of this.apiKeyOnlyProviders()) {
        const caps: SpendCaps = { daily_usd: 20, weekly_usd: 100 };
        this.apiKeys.set(id, "mock-key-never-returned");
        this.provider(id).api_key = { present: true, caps };
        const usage = this.newUsage(id, "api_key");
        usage.prompts_last_hour.current = 3;
        usage.tokens_today = { input: 182_400, output: 21_950, is_estimate: true };
        usage.spend = { today_usd: 3.42, week_usd: 11.8, caps, is_estimate: true };
        this.usage.providers.push(usage);
      }
    }
    if (s === "plan_draft" || s === "running" || s === "rate_limited" || s.startsWith("review")) {
      const plan = clone<Plan>(planJson);
      this.plans.set(plan.plan_id, { plan, status: "draft", needs_reapproval: false });
      this.leadRequests.push({
        request_id: "req-fixture",
        lead: plan.lead.provider,
        text: plan.request_summary,
        created_at: this.nowIso(-5 * 60 * 1000),
        state: "plan_ready",
        messages: [{ at: this.nowIso(-5 * 60 * 1000), text: `Plan ready: ${String(plan.tasks.length)} tasks.` }],
        plan_id: plan.plan_id,
      });
      if (s !== "plan_draft") {
        const record = this.plans.get(plan.plan_id);
        if (record !== undefined) {
          plan.approval = {
            plan_hash: await planHash(plan),
            approved_at: this.nowIso(-4 * 60 * 1000),
            approved_via: "ui",
            nonce: randomHex(16),
          };
          record.status = s.startsWith("review") ? "done" : "running";
        }
      }
    }
    if (s === "plan_violations") {
      const plan = clone<Plan>(planViolationsJson);
      this.plans.set(plan.plan_id, { plan, status: "draft", needs_reapproval: false });
    }
    if (s === "running" || s === "rate_limited") this.setupWorker(s === "rate_limited");
    if (s === "review_ready" || s === "review_handoff_error") {
      const review = clone<ReviewView>(reviewJson);
      if (s === "review_handoff_error") {
        review.handoff = { ok: false, error: "handoff: missing section: Tests run (line 9)" };
      }
      this.reviews.set(review.task_id, review);
    }
    if (s === "review_injection") {
      const review = clone<ReviewView>(reviewInjectionJson);
      this.reviews.set(review.task_id, review);
    }
  }

  private setupWorker(rateLimited: boolean): void {
    const plan = clone<Plan>(planJson);
    const task = plan.tasks[0];
    if (task === undefined) return;
    const session: SessionView = {
      session_id: "s-1",
      kind: "worker",
      provider: task.provider,
      task_id: task.id,
      plan_id: plan.plan_id,
      title: task.title,
      role: task.role,
      branch: `harness/${task.id}`,
      worktree: `.claude/worktrees/${task.id}`,
      state: { kind: "running" },
      paused: null,
      turns: { current: 12, limit: this.settings.limits.turns_per_task },
      started_at: this.nowIso(-18 * 60 * 1000),
      takeover: false,
    };
    this.sessions.set(session.session_id, session);
    this.terminals.set(session.session_id, { cols: 120, rows: 32, bytes: new Uint8Array(), seq: 0 });
    this.appendTerminal(session.session_id, "\u001b[2m[harness] read-only mirror of the headless worker\u001b[0m\r\n", false);
    const usage = this.usage.providers.find((u) => u.provider === task.provider && u.auth_mode === "subscription");
    if (usage !== undefined) {
      usage.sessions.current = 1;
      usage.prompts_last_hour.current = 4;
      usage.max_task_turns.current = 12;
      usage.max_task_turns.task_id = task.id;
      usage.run_minutes_today.current = 18;
      usage.tokens_today = { input: 48_210, output: 6_120, is_estimate: true };
    }
    if (rateLimited) {
      this.rateLimit(session, 1);
    } else {
      let step = 0;
      this.schedule(
        TERMINAL_TICK_MS,
        () => {
          const live = this.sessions.get(session.session_id);
          if (live === undefined || !isLive(live) || live.paused !== null) return;
          step += 1;
          this.appendTerminal(session.session_id, `step ${String(step)}: editing src/features/settings/form.tsx\r\n`);
        },
        TERMINAL_TICK_MS,
      );
    }
  }

  /** A rate-limit error on a worker: backoff from the base, doubling; pause the provider at the threshold. */
  private rateLimit(session: SessionView, consecutive: number): void {
    const pacing = this.pacing.get(session.provider);
    if (pacing === undefined) return;
    const threshold = this.settings.limits.pause_after_limit_errors;
    pacing.consecutive_limit_errors = consecutive;
    if (consecutive >= threshold) {
      pacing.paused = true;
      pacing.paused_until = this.nowIso(HOUR_MS);
      delete pacing.backoff;
      session.state = { kind: "idle" };
      session.paused = { reason: "limit_errors", until: pacing.paused_until };
    } else {
      const delay = this.settings.limits.backoff_base_s * 1000 * 2 ** (consecutive - 1);
      const retryAt = this.nowIso(delay);
      pacing.backoff = { retry_at: retryAt, attempt: consecutive };
      session.state = { kind: "rate_limited", retry_at: retryAt, attempt: consecutive, consecutive_limit_errors: consecutive };
      this.schedule(delay, () => {
        const live = this.sessions.get(session.session_id);
        if (live === undefined || live.state.kind !== "rate_limited") return;
        this.rateLimit(live, consecutive + 1);
      });
    }
    this.emit("session_changed", session);
    this.emit("provider_changed", this.providerStatus(session.provider));
    this.emit("usage_changed", this.usageSnapshot());
  }

  // ---- derived views ---------------------------------------------------------------------------------------------

  private providerStatus(id: ProviderId): ProviderStatus {
    const status = this.provider(id);
    status.usable = this.computeUsable(status);
    return status;
  }

  private computeUsable(s: ProviderStatus): ProviderStatus["usable"] {
    if (!s.adapter_available) return { lead: false, worker: false, blockers: ["adapter_unavailable"] };
    const blockers: Blocker[] = [];
    if (s.install.state === "not_installed") blockers.push("not_installed");
    if (s.binary.state === "failed") blockers.push("binary_failed");
    else if (s.binary.state === "unchecked") blockers.push("binary_unchecked");
    if (s.killswitch === "disabled") blockers.push("killswitch_disabled");
    if (this.pacing.get(s.provider)?.paused === true) blockers.push("provider_paused");
    const subscriptionAllowed = s.auth_modes.includes("subscription") && s.killswitch !== "api_key_only";
    const subscriptionBlockers: Blocker[] = [];
    if (s.sign_in.state === "signed_out") subscriptionBlockers.push("signed_out");
    else if (s.sign_in.state === "unknown") subscriptionBlockers.push("sign_in_unknown");
    if (!s.personal_use_confirmed) subscriptionBlockers.push("personal_use_unconfirmed");
    const subscriptionOk = subscriptionAllowed && subscriptionBlockers.length === 0;
    const keyOk = s.api_key?.present === true && s.api_key.caps !== null;
    if (!subscriptionOk && !keyOk) {
      if (subscriptionAllowed) blockers.push(...subscriptionBlockers);
      else blockers.push("api_key_missing");
    }
    const usable = blockers.length === 0;
    return { lead: usable, worker: usable, blockers };
  }

  private newUsage(provider: ProviderId, authMode: AuthMode): ProviderUsage {
    const l = this.settings.limits;
    const r = this.limits.rules;
    return {
      provider,
      auth_mode: authMode,
      sessions: { current: 0, limit: l.concurrent_sessions, ceiling: r.concurrent_sessions.ceiling },
      prompts_last_hour: { current: 0, limit: l.prompts_per_hour, ceiling: r.prompts_per_hour.ceiling },
      max_task_turns: { current: 0, limit: l.turns_per_task, ceiling: r.turns_per_task.ceiling },
      run_minutes_today: { current: 0, limit: l.run_minutes_per_day, ceiling: r.run_minutes_per_day.ceiling },
      pacing: { consecutive_limit_errors: 0, paused: false },
      tokens_today: { input: 0, output: 0, is_estimate: true },
      spend: null,
    };
  }

  private usageSnapshot(): UsageSnapshot {
    const l = this.settings.limits;
    for (const u of this.usage.providers) {
      u.sessions.limit = l.concurrent_sessions;
      u.prompts_last_hour.limit = l.prompts_per_hour;
      u.max_task_turns.limit = l.turns_per_task;
      u.run_minutes_today.limit = l.run_minutes_per_day;
      const pacing = this.pacing.get(u.provider);
      if (pacing !== undefined) {
        u.pacing = { consecutive_limit_errors: pacing.consecutive_limit_errors, paused: pacing.paused };
        if (pacing.paused_until !== undefined) u.pacing.paused_until = pacing.paused_until;
        if (pacing.backoff !== undefined) u.pacing.backoff = { ...pacing.backoff };
      }
    }
    this.usage.as_of = this.nowIso();
    this.usage.idle_pause_minutes = l.idle_pause_minutes;
    return this.usage;
  }

  private async planView(record: PlanRecord): Promise<PlanView> {
    const ceilings = {
      turnsPerTask: this.limits.rules.turns_per_task.ceiling,
      promptsPerHour: this.limits.rules.prompts_per_hour.ceiling,
      apiKeyOnly: this.apiKeyOnlyProviders(),
    };
    return {
      plan: record.plan,
      plan_hash: await planHash(record.plan),
      status: record.status,
      violations: checkPlan(record.plan, ceilings),
      estimates: planEstimates(record.plan),
      needs_reapproval: record.needs_reapproval,
    };
  }

  private planRecord(planId: unknown): PlanRecord {
    if (typeof planId !== "string") return invalid("plan_id must be a string");
    return this.plans.get(planId) ?? notFound("plan");
  }

  private session(sessionId: unknown): SessionView {
    if (typeof sessionId !== "string") return invalid("session_id must be a string");
    return this.sessions.get(sessionId) ?? notFound("session");
  }

  private appendTerminal(sessionId: string, text: string, emit = true): void {
    const term = this.terminals.get(sessionId);
    if (term === undefined) return;
    const chunk = new TextEncoder().encode(text);
    const merged = new Uint8Array(term.bytes.length + chunk.length);
    merged.set(term.bytes);
    merged.set(chunk, term.bytes.length);
    term.bytes = merged.length > SCROLLBACK_CAP_BYTES ? merged.slice(merged.length - SCROLLBACK_CAP_BYTES) : merged;
    term.seq += 1;
    if (emit) this.emit("terminal_output", { session_id: sessionId, seq: term.seq, data_b64: bytesToBase64(chunk) });
  }

  private validateCaps(caps: unknown): SpendCaps {
    const max = this.limits.spend_cap_max;
    if (!isObject(caps)) return ruleBlocked(11, "Daily and weekly spend caps are required.");
    const { daily_usd: daily, weekly_usd: weekly } = caps;
    if (typeof daily !== "number" || typeof weekly !== "number" || !Number.isFinite(daily) || !Number.isFinite(weekly)) {
      return ruleBlocked(11, "Spend caps must be numbers; there is no unlimited value.");
    }
    if (daily <= 0 || weekly <= 0) return ruleBlocked(11, "Spend caps must be greater than zero.");
    if (daily > max.daily_usd || weekly > max.weekly_usd) {
      return ruleBlocked(
        11,
        `Spend caps can be at most $${String(max.daily_usd)} a day and $${String(max.weekly_usd)} a week.`,
      );
    }
    if (weekly < daily) return ruleBlocked(11, "The weekly cap must be at least the daily cap.");
    return { daily_usd: daily, weekly_usd: weekly };
  }

  // ---- commands --------------------------------------------------------------------------------------------------

  readonly client: IpcClient = {
    get_app_info: () =>
      this.run("get_app_info", undefined, () => ({
        name: "Harness",
        version: "0.1.0",
        identifier: "dev.local.harness",
      })),

    list_providers: () =>
      this.run("list_providers", undefined, () => [...this.providers.keys()].map((id) => this.providerStatus(id))),

    refresh_provider_status: (args) =>
      this.run("refresh_provider_status", args, () => {
        const status = this.provider(args.provider);
        if (status.binary.state !== "unchecked") status.binary.checked_at = this.nowIso();
        if (status.sign_in.state !== "unknown") status.sign_in.checked_at = this.nowIso();
        const out = this.providerStatus(status.provider);
        this.emit("provider_changed", out);
        return out;
      }),

    open_provider_login: (args) =>
      this.run("open_provider_login", args, () => {
        const status = this.provider(args.provider);
        if (!status.adapter_available) return invalid("this provider is not available yet");
        if (!status.auth_modes.includes("subscription")) {
          return ruleBlocked(7, "This provider runs on an API key only; there is no sign-in.");
        }
        if (status.killswitch === "disabled") return ruleBlocked(12, "This adapter is disabled by the signed config.");
        if (status.killswitch === "api_key_only") return ruleBlocked(12, "The signed config allows an API key only.");
        if (status.binary.state === "failed") return ruleBlocked(6, "The CLI failed verification; sign-in is refused.");
        if (status.install.state === "not_installed") return invalid("Install the CLI first.");
        this.idSeq += 1;
        const session: SessionView = {
          session_id: `login-${String(this.idSeq)}`,
          kind: "login",
          provider: status.provider,
          state: { kind: "running" },
          paused: null,
          turns: { current: 0, limit: 0 },
          started_at: this.nowIso(),
          takeover: true,
        };
        this.sessions.set(session.session_id, session);
        this.terminals.set(session.session_id, { cols: 100, rows: 30, bytes: new Uint8Array(), seq: 0 });
        this.appendTerminal(session.session_id, "Follow the sign-in steps of the CLI in this terminal.\r\n$ ");
        this.emit("session_changed", session);
        return { session_id: session.session_id };
      }),

    confirm_personal_use: (args) =>
      this.run("confirm_personal_use", args, () => {
        const status = this.provider(args.provider);
        if (!status.auth_modes.includes("subscription")) return invalid("This provider has no subscription sign-in.");
        status.personal_use_confirmed = true;
        const out = this.providerStatus(status.provider);
        this.emit("provider_changed", out);
        return out;
      }),

    set_api_key: (args) =>
      this.run("set_api_key", { ...args, key: "<redacted>" }, () => {
        const status = this.provider(args.provider);
        if (status.api_key === null) return invalid("This provider has no API-key mode.");
        const caps = this.validateCaps((args as { caps?: unknown }).caps);
        if (typeof args.key !== "string" || args.key.trim() === "") return invalid("Enter an API key.");
        this.apiKeys.set(status.provider, args.key);
        status.api_key = { present: true, caps };
        let usage = this.usage.providers.find((u) => u.provider === status.provider && u.auth_mode === "api_key");
        if (usage === undefined) {
          usage = this.newUsage(status.provider, "api_key");
          this.usage.providers.push(usage);
        }
        usage.spend = { today_usd: usage.spend?.today_usd ?? 0, week_usd: usage.spend?.week_usd ?? 0, caps, is_estimate: true };
        const out = this.providerStatus(status.provider);
        this.emit("provider_changed", out);
        this.emit("usage_changed", this.usageSnapshot());
        return out;
      }),

    update_spend_caps: (args) =>
      this.run("update_spend_caps", args, () => {
        const status = this.provider(args.provider);
        if (status.api_key?.present !== true) return invalid("Add an API key first.");
        const caps = this.validateCaps((args as { caps?: unknown }).caps);
        status.api_key = { present: true, caps };
        const usage = this.usage.providers.find((u) => u.provider === status.provider && u.auth_mode === "api_key");
        if (usage?.spend) usage.spend.caps = caps;
        const out = this.providerStatus(status.provider);
        this.emit("provider_changed", out);
        this.emit("usage_changed", this.usageSnapshot());
        return out;
      }),

    remove_api_key: (args) =>
      this.run("remove_api_key", args, () => {
        const status = this.provider(args.provider);
        if (status.api_key === null) return invalid("This provider has no API-key mode.");
        this.apiKeys.delete(status.provider);
        status.api_key = { present: false, caps: null };
        this.usage.providers = this.usage.providers.filter(
          (u) => !(u.provider === status.provider && u.auth_mode === "api_key"),
        );
        const out = this.providerStatus(status.provider);
        this.emit("provider_changed", out);
        this.emit("usage_changed", this.usageSnapshot());
        return out;
      }),

    start_lead_request: (args) =>
      this.run("start_lead_request", args, () => {
        const status = this.providerStatus(this.provider(args.lead).provider);
        if (typeof args.text !== "string" || args.text.trim() === "") return invalid("Describe what you want built.");
        if (this.leadRequests.some((r) => r.state === "thinking")) {
          return invalid("A lead request is already in flight; wait or cancel it.");
        }
        if (!status.usable.lead) return invalid("That provider cannot lead right now.");
        this.idSeq += 1;
        const request: LeadRequest = {
          request_id: `req-${String(this.idSeq)}`,
          lead: status.provider,
          text: args.text,
          created_at: this.nowIso(),
          state: "thinking",
          messages: [{ at: this.nowIso(), text: "Reading the request and the repository layout." }],
        };
        this.leadRequests.unshift(request);
        this.emit("lead_changed", request);
        const authMode: AuthMode =
          status.auth_modes.includes("subscription") && status.killswitch !== "api_key_only" ? "subscription" : "api_key";
        this.schedule(LEAD_THINK_MS, async () => {
          if (request.state !== "thinking") return;
          const plan = clone<Plan>(planJson);
          this.idSeq += 1;
          plan.plan_id = `plan-mock-${String(this.idSeq)}`;
          plan.created_at = this.nowIso();
          plan.lead = { provider: status.provider, auth_mode: authMode };
          plan.request_summary = args.text.slice(0, 500);
          const record: PlanRecord = { plan, status: "draft", needs_reapproval: false };
          this.plans.set(plan.plan_id, record);
          request.state = "plan_ready";
          request.plan_id = plan.plan_id;
          request.messages.push({ at: this.nowIso(), text: `Plan ready: ${String(plan.tasks.length)} tasks.` });
          this.emit("plan_changed", await this.planView(record));
          this.emit("lead_changed", request);
        });
        return { request_id: request.request_id };
      }),

    cancel_lead_request: (args) =>
      this.run("cancel_lead_request", args, () => {
        const request = this.leadRequests.find((r) => r.request_id === args.request_id) ?? notFound("lead request");
        if (request.state !== "thinking" && request.state !== "rate_limited") {
          return invalid("Only a request in flight can be cancelled.");
        }
        request.state = "cancelled";
        this.emit("lead_changed", request);
      }),

    list_lead_requests: () => this.run("list_lead_requests", undefined, () => this.leadRequests),

    list_plans: () =>
      this.run("list_plans", undefined, () =>
        [...this.plans.values()]
          .map(
            (r): PlanListItem => ({
              plan_id: r.plan.plan_id,
              created_at: r.plan.created_at,
              lead: r.plan.lead.provider,
              status: r.status,
              task_count: r.plan.tasks.length,
            }),
          )
          .sort((a, b) => (a.created_at < b.created_at ? 1 : -1)),
      ),

    get_plan: (args) => this.run("get_plan", args, () => this.planView(this.planRecord(args.plan_id))),

    update_plan: (args) =>
      this.run("update_plan", args, async () => {
        const record = this.planRecord(args.plan_id);
        if (record.status !== "draft" && record.status !== "approved") {
          return invalid(`A ${record.status} plan cannot be edited.`);
        }
        applyEdit(record.plan, args.edit);
        if (record.plan.approval !== undefined) {
          delete record.plan.approval;
          record.needs_reapproval = true;
        }
        record.status = "draft";
        const view = await this.planView(record);
        this.emit("plan_changed", view);
        return view;
      }),

    discard_plan: (args) =>
      this.run("discard_plan", args, () => {
        const record = this.planRecord(args.plan_id);
        if (record.status === "running") return invalid("A running plan cannot be discarded.");
        this.plans.delete(record.plan.plan_id);
      }),

    list_sessions: () => this.run("list_sessions", undefined, () => [...this.sessions.values()]),

    pause_session: (args) =>
      this.run("pause_session", args, () => {
        const s = this.session(args.session_id);
        if (!isLive(s)) return invalid("The session has ended.");
        s.paused ??= { reason: "user" };
        this.emit("session_changed", s);
        return s;
      }),

    resume_session: (args) =>
      this.run("resume_session", args, () => {
        const s = this.session(args.session_id);
        if (!isLive(s)) return invalid("The session has ended.");
        if (s.takeover) return invalid("Hand control back (turn take-over off) before resuming automation.");
        if (s.state.kind === "rate_limited") {
          return ruleBlocked(10, "The provider is backing off after a rate limit.", s.state.retry_at);
        }
        const pacing = this.pacing.get(s.provider);
        if (pacing?.paused === true) {
          return ruleBlocked(10, "The provider is paused after repeated limit errors; resume the provider.", pacing.paused_until);
        }
        if (s.kind === "worker" && s.turns.current >= s.turns.limit) {
          return ruleBlocked(1, "The task reached its turn ceiling.");
        }
        if (s.paused?.reason === "user_idle" && this.usage.user_idle_minutes >= this.settings.limits.idle_pause_minutes) {
          return ruleBlocked(1, "Automation stays paused while you are away.");
        }
        s.paused = null;
        this.emit("session_changed", s);
        return s;
      }),

    kill_session: (args) =>
      this.run("kill_session", args, () => {
        const s = this.session(args.session_id);
        s.state = { kind: "killed" };
        s.paused = null;
        s.takeover = false;
        this.emit("session_changed", s);
        return s;
      }),

    set_takeover: (args) =>
      this.run("set_takeover", args, () => {
        const s = this.session(args.session_id);
        if (typeof args.enabled !== "boolean") return invalid("enabled must be a boolean");
        if (!isLive(s)) return invalid("The session has ended.");
        if (args.enabled) {
          s.takeover = true;
          s.paused = { reason: "takeover" };
        } else {
          s.takeover = false;
        }
        this.emit("session_changed", s);
        return s;
      }),

    resume_provider: (args) =>
      this.run("resume_provider", args, () => {
        const status = this.provider(args.provider);
        const pacing = this.pacing.get(status.provider);
        if (pacing === undefined) return;
        pacing.paused = false;
        pacing.consecutive_limit_errors = 0;
        delete pacing.paused_until;
        delete pacing.backoff;
        for (const s of this.sessions.values()) {
          if (s.provider === status.provider && s.paused?.reason === "limit_errors") {
            s.paused = null;
            this.emit("session_changed", s);
          }
        }
        this.emit("provider_changed", this.providerStatus(status.provider));
        this.emit("usage_changed", this.usageSnapshot());
      }),

    attach_terminal: (args) =>
      this.run("attach_terminal", args, (): TerminalAttach => {
        const s = this.session(args.session_id);
        const term = this.terminals.get(s.session_id) ?? notFound("terminal");
        return { cols: term.cols, rows: term.rows, scrollback_b64: bytesToBase64(term.bytes) };
      }),

    resize_terminal: (args) =>
      this.run("resize_terminal", args, () => {
        const s = this.session(args.session_id);
        const term = this.terminals.get(s.session_id) ?? notFound("terminal");
        const ok = (n: unknown): n is number => Number.isInteger(n) && (n as number) >= 2 && (n as number) <= 1000;
        if (!ok(args.cols) || !ok(args.rows)) return invalid("cols and rows must be integers from 2 to 1000");
        term.cols = args.cols;
        term.rows = args.rows;
      }),

    list_reviews: () =>
      this.run("list_reviews", undefined, () =>
        [...this.reviews.values()].map(
          (r): ReviewListItem => ({
            task_id: r.task_id,
            plan_id: r.plan_id,
            title: r.title,
            provider: r.provider,
            state: r.reviewed ? "reviewed" : r.test_log.status === "failed" ? "failed" : "ready",
          }),
        ),
      ),

    get_review: (args) =>
      this.run("get_review", args, () => this.reviews.get(args.task_id) ?? notFound("review")),

    mark_reviewed: (args) =>
      this.run("mark_reviewed", args, () => {
        const review = this.reviews.get(args.task_id) ?? notFound("review");
        review.reviewed = true;
        return review;
      }),

    get_usage: () => this.run("get_usage", undefined, () => this.usageSnapshot()),

    get_limits: () => this.run("get_limits", undefined, () => this.limits),

    get_settings: () => this.run("get_settings", undefined, () => this.settings),

    update_settings: (args) =>
      this.run("update_settings", args, () => {
        const patch: unknown = (args as { patch?: unknown }).patch;
        if (!isObject(patch)) return invalid("patch must be an object");
        const next: Settings = clone(this.settings);
        const typed = patch as SettingsPatch;
        if (typed.summary_budget_tokens !== undefined) {
          const v = typed.summary_budget_tokens;
          if (!Number.isInteger(v) || v < 1 || v > 1_000_000) {
            return invalid("summary_budget_tokens must be an integer from 1 to 1000000");
          }
          next.summary_budget_tokens = v;
        }
        if (typed.limits !== undefined) {
          if (!isObject(typed.limits)) return invalid("limits must be an object");
          for (const [key, value] of Object.entries(typed.limits)) {
            if (!(LIMIT_KEYS as readonly string[]).includes(key)) return invalid(`unknown limit ${key}`);
            const k = key as LimitKey;
            const rule = this.limits.rules[k];
            if (!Number.isInteger(value)) return invalid(`${k} must be an integer`);
            const v = value as number;
            const looser = rule.stricter === "lower" ? v > rule.ceiling : v < rule.ceiling;
            if (looser) {
              return ruleBlocked(RULE_FOR_LIMIT[k], `${k} cannot be looser than its ceiling (${String(rule.ceiling)}).`);
            }
            const inRange = rule.stricter === "lower" ? v >= rule.bound : v <= rule.bound;
            if (!inRange) return invalid(`${k} must stay between ${String(rule.bound)} and ${String(rule.ceiling)}`);
            next.limits[k] = v;
          }
        }
        this.settings = next;
        for (const s of this.sessions.values()) if (s.kind === "worker") s.turns.limit = next.limits.turns_per_task;
        this.emit("usage_changed", this.usageSnapshot());
        return this.settings;
      }),

    get_killswitch_status: () => this.run("get_killswitch_status", undefined, () => this.killswitch),

    listen: (event, handler) => Promise.resolve(this.listen(event, handler)),
  };

  readonly approval: ApprovalPort = {
    approve_plan: (args) =>
      this.run("approve_plan", args, async () => {
        const record = this.planRecord(args.plan_id);
        if (record.status !== "draft") return invalid(`A ${record.status} plan cannot be approved again.`);
        const view = await this.planView(record);
        if (typeof args.plan_hash !== "string" || args.plan_hash !== view.plan_hash) {
          return reject({ kind: "plan_hash_mismatch", message: "The plan changed since you reviewed it. Review it again." });
        }
        if (view.violations.length > 0) {
          return reject({
            kind: "plan_has_violations",
            message: `The plan has ${String(view.violations.length)} open violation(s).`,
          });
        }
        record.plan.approval = {
          plan_hash: view.plan_hash,
          approved_at: this.nowIso(),
          approved_via: "ui",
          nonce: randomHex(16),
        };
        record.status = "approved";
        record.needs_reapproval = false;
        const out = await this.planView(record);
        this.emit("plan_changed", out);
        return out;
      }),
  };

  readonly ptyInput: PtyInputPort = {
    pty_write: (args) =>
      this.run("pty_write", args, () => {
        const s = this.session(args.session_id);
        if (!s.takeover) return ruleBlocked(3, "Take-over is off; automation never types into a terminal.");
        if (!isLive(s)) return invalid("The session has ended.");
        if (typeof args.data !== "string") return invalid("data must be text");
        this.appendTerminal(s.session_id, args.data);
      }),
  };

  /** For tests: the terminal scrollback as base64 (same as attach_terminal, without recording a call). */
  scrollbackB64(sessionId: string): string {
    return bytesToBase64(this.terminals.get(sessionId)?.bytes ?? new Uint8Array());
  }

  /** For tests and the dev console: write text into a session's mirror as if the worker printed it. */
  printToTerminal(sessionId: string, text: string): void {
    this.appendTerminal(sessionId, text);
  }

  static encodeText(text: string): string {
    return utf8ToBase64(text);
  }
}

function isLive(s: SessionView): boolean {
  return s.state.kind !== "killed" && s.state.kind !== "exited";
}

function applyEdit(plan: Plan, edit: PlanEdit): void {
  if (!isObject(edit) || typeof edit.task_id !== "string") invalid("edit must name a task");
  const task = plan.tasks.find((t) => t.id === edit.task_id) ?? notFound("task");
  switch (edit.kind) {
    case "set_provider":
      if (!isProviderId(edit.provider)) invalid("unknown provider");
      if (edit.auth_mode !== "subscription" && edit.auth_mode !== "api_key") invalid("unknown auth_mode");
      task.provider = edit.provider;
      task.auth_mode = edit.auth_mode;
      return;
    case "set_fallbacks":
      if (!Array.isArray(edit.fallback_providers)) invalid("fallback_providers must be an array");
      for (const fb of edit.fallback_providers) {
        if (!isProviderId(fb.provider) || (fb.auth_mode !== "subscription" && fb.auth_mode !== "api_key")) {
          invalid("each fallback needs a provider and an auth_mode");
        }
      }
      task.fallback_providers = edit.fallback_providers.map((f) => ({ provider: f.provider, auth_mode: f.auth_mode }));
      return;
    case "set_acceptance":
      if (!Array.isArray(edit.acceptance) || !edit.acceptance.every((a) => typeof a === "string")) {
        invalid("acceptance must be a list of strings");
      }
      task.acceptance = [...edit.acceptance];
      return;
    case "remove_task":
      if (plan.tasks.length === 1) invalid("A plan needs at least one task.");
      if (plan.tasks.some((t) => t.depends_on.includes(task.id))) invalid("Another task depends on this one.");
      plan.tasks = plan.tasks.filter((t) => t.id !== task.id);
      return;
    default:
      invalid("unknown edit kind");
  }
}
