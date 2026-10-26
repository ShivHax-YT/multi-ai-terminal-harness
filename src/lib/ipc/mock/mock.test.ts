import { readFileSync } from "node:fs";
import path from "node:path";

import { Ajv2020 } from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { describe, expect, it } from "vitest";

import { IpcRejection, type IpcError, type PlanView, type ProviderId } from "../contract";
import planJson from "../fixtures/plan.json";
import planViolationsJson from "../fixtures/plan-violations.json";

import { createMockIpc, LEAD_THINK_MS, MOCK_SCENARIOS, MOCK_SENTINEL, type MockIpc } from "./index";
import { canonicalJson, planHash } from "./plan";

const root = path.resolve(import.meta.dirname, "../../../..");
const PLAN_ID = "plan-2026-10-25-001";

async function rejection(p: Promise<unknown>): Promise<IpcError> {
  try {
    await p;
  } catch (e) {
    expect(e).toBeInstanceOf(IpcRejection);
    return (e as IpcRejection).toJSON();
  }
  throw new Error("expected a rejection");
}

function validator() {
  const schema = JSON.parse(
    readFileSync(path.join(root, "docs/spec/plan.schema.json"), "utf8"),
  ) as object;
  const ajv = new Ajv2020({ strict: true, allErrors: true });
  addFormats(ajv);
  return ajv.compile(schema);
}

describe("plan fixtures match docs/spec/plan.schema.json", () => {
  const validate = validator();
  it.each([
    ["plan.json", planJson],
    ["plan-violations.json", planViolationsJson],
  ])("%s is schema-valid", (_name, plan) => {
    expect(validate(plan), JSON.stringify(validate.errors)).toBe(true);
  });

  it("plans the mock hands out stay schema-valid through edit and approval", async () => {
    const m = createMockIpc({ scenario: "plan_draft" });
    const view = await m.client.get_plan({ plan_id: PLAN_ID });
    expect(validate(view.plan)).toBe(true);
    const approved = await m.approval.approve_plan({ plan_id: PLAN_ID, plan_hash: view.plan_hash });
    expect(validate(approved.plan), JSON.stringify(validate.errors)).toBe(true);
    const edited = await m.client.update_plan({
      plan_id: PLAN_ID,
      edit: { kind: "set_acceptance", task_id: "t1", acceptance: ["passes"] },
    });
    expect(validate(edited.plan)).toBe(true);
  });
});

describe("mock basics", () => {
  it("every scenario starts and answers the read commands (errors rejects them all)", async () => {
    for (const scenario of MOCK_SCENARIOS) {
      const m = createMockIpc({ scenario });
      const reads = [
        m.client.get_app_info(),
        m.client.list_providers(),
        m.client.list_lead_requests(),
        m.client.list_plans(),
        m.client.list_sessions(),
        m.client.list_reviews(),
        m.client.get_usage(),
        m.client.get_limits(),
        m.client.get_settings(),
        m.client.get_killswitch_status(),
      ];
      if (scenario === "errors") {
        for (const r of reads) expect((await rejection(r)).kind).toBe("internal");
      } else {
        await expect(Promise.all(reads)).resolves.toHaveLength(reads.length);
      }
    }
  });

  it("carries the sentinel that make check looks for in dist/", () => {
    expect(createMockIpc().control.sentinel).toBe("__HARNESS_MOCK__");
    expect(MOCK_SENTINEL).toBe("__HARNESS_MOCK__");
  });

  it("records calls, injects failures and returns copies", async () => {
    const m = createMockIpc();
    const err: IpcError = {
      kind: "rate_limited",
      message: "slow down",
      retry_at: "2026-10-25T09:31:00Z",
    };
    m.control.failNext("list_providers", err);
    expect(await rejection(m.client.list_providers())).toEqual(err);
    const list = await m.client.list_providers();
    list[0]!.personal_use_confirmed = false;
    expect((await m.client.list_providers())[0]!.personal_use_confirmed).toBe(true);
    expect(m.control.calls.map((c) => c.command)).toEqual([
      "list_providers",
      "list_providers",
      "list_providers",
    ]);
  });

  it("limits come from the ceilings (the Rust test limits_match_fixture pins the fixture)", async () => {
    const limits = await createMockIpc().client.get_limits();
    expect(limits.rules.concurrent_sessions).toEqual({
      ceiling: 2,
      stricter: "lower",
      bound: 1,
      unit: "count",
    });
    expect(limits.rules.prompts_per_hour.ceiling).toBe(30);
    expect(limits.rules.turns_per_task.ceiling).toBe(40);
    expect(limits.rules.run_minutes_per_day.ceiling).toBe(480);
    expect(limits.rules.idle_pause_minutes.ceiling).toBe(30);
    expect(limits.rules.min_dispatch_gap_s).toEqual({
      ceiling: 5,
      stricter: "higher",
      bound: 600,
      unit: "seconds",
    });
    expect(limits.rules.backoff_base_s.ceiling).toBe(60);
    expect(limits.rules.pause_after_limit_errors.ceiling).toBe(3);
    expect(limits.spend_cap_max).toEqual({ daily_usd: 500, weekly_usd: 2000 });
  });
});

describe("provider scenarios and refusals", () => {
  const status = async (m: MockIpc, id: ProviderId) =>
    (await m.client.list_providers()).find((p) => p.provider === id)!;

  it("ready: the MVP pair is usable, the API-key-only provider is not, and has no sign-in (rule 7)", async () => {
    const m = createMockIpc();
    expect((await status(m, "claude")).usable).toEqual({ lead: true, worker: true, blockers: [] });
    expect((await status(m, "codex")).usable.worker).toBe(true);
    const keyOnly = await status(m, "gemini");
    expect(keyOnly.auth_modes).toEqual(["api_key"]);
    expect(keyOnly.usable.blockers).toEqual(["api_key_missing"]);
    const e = await rejection(m.client.open_provider_login({ provider: "gemini" }));
    expect(e).toMatchObject({ kind: "rule_blocked", rule: 7 });
  });

  it("ready: login opens a login session with take-over on", async () => {
    const m = createMockIpc();
    const { session_id } = await m.client.open_provider_login({ provider: "claude" });
    const s = (await m.client.list_sessions()).find((x) => x.session_id === session_id)!;
    expect(s.kind).toBe("login");
    expect(s.takeover).toBe(true);
  });

  it("fresh: signed out, unconfirmed and not installed", async () => {
    const m = createMockIpc({ scenario: "fresh" });
    const s = await status(m, "claude");
    expect(s.usable.blockers).toEqual(
      expect.arrayContaining([
        "not_installed",
        "binary_unchecked",
        "signed_out",
        "personal_use_unconfirmed",
      ]),
    );
    const confirmed = await m.client.confirm_personal_use({ provider: "claude" });
    expect(confirmed.personal_use_confirmed).toBe(true);
    expect(confirmed.usable.blockers).not.toContain("personal_use_unconfirmed");
  });

  it("binary_failed: sign-in is refused (rule 6)", async () => {
    const m = createMockIpc({ scenario: "binary_failed" });
    const s = await status(m, "codex");
    expect(s.binary.state).toBe("failed");
    expect(s.usable.blockers).toContain("binary_failed");
    expect(await rejection(m.client.open_provider_login({ provider: "codex" }))).toMatchObject({
      kind: "rule_blocked",
      rule: 6,
    });
  });

  it("killswitch: an adapter disabled by the last-known signed config (rule 12)", async () => {
    const m = createMockIpc({ scenario: "killswitch" });
    const ks = await m.client.get_killswitch_status();
    expect(ks.source).toBe("last_known");
    expect(ks.adapters.find((a) => a.provider === "codex")?.state).toBe("disabled");
    expect((await status(m, "codex")).usable.blockers).toContain("killswitch_disabled");
    expect(await rejection(m.client.open_provider_login({ provider: "codex" }))).toMatchObject({
      rule: 12,
    });
  });

  it("API keys: caps are required, finite, positive, within the max and weekly >= daily (rule 11)", async () => {
    const m = createMockIpc();
    const key = "sk-mock-secret-value";
    const bad: unknown[] = [
      undefined,
      null,
      { daily_usd: Infinity, weekly_usd: Infinity },
      { daily_usd: 0, weekly_usd: 10 },
      { daily_usd: 501, weekly_usd: 1000 },
      { daily_usd: 20, weekly_usd: 2001 },
      { daily_usd: 50, weekly_usd: 10 },
      { daily_usd: "10", weekly_usd: 20 },
    ];
    for (const caps of bad) {
      const e = await rejection(
        m.client.set_api_key({
          provider: "gemini",
          key,
          caps: caps as { daily_usd: number; weekly_usd: number },
        }),
      );
      expect(e).toMatchObject({ kind: "rule_blocked", rule: 11 });
    }
    const ok = await m.client.set_api_key({
      provider: "gemini",
      key,
      caps: { daily_usd: 10, weekly_usd: 50 },
    });
    expect(ok.api_key).toEqual({ present: true, caps: { daily_usd: 10, weekly_usd: 50 } });
    expect(ok.usable.worker).toBe(true);
    expect(JSON.stringify(ok)).not.toContain(key);
    expect(JSON.stringify(m.control.calls)).not.toContain(key);
    expect(JSON.stringify(await m.client.list_providers())).not.toContain(key);
    const usage = await m.client.get_usage();
    expect(usage.providers.find((u) => u.provider === "gemini")?.spend?.caps).toEqual({
      daily_usd: 10,
      weekly_usd: 50,
    });
    const removed = await m.client.remove_api_key({ provider: "gemini" });
    expect(removed.api_key).toEqual({ present: false, caps: null });
  });

  it("api_key scenario: the key-only provider has caps and spend", async () => {
    const m = createMockIpc({ scenario: "api_key" });
    const usage = await m.client.get_usage();
    const spend = usage.providers.find((u) => u.auth_mode === "api_key")?.spend;
    expect(spend?.caps).toEqual({ daily_usd: 20, weekly_usd: 100 });
    expect((await status(m, "gemini")).usable.lead).toBe(true);
  });
});

describe("settings refusals (rules 1 and 10)", () => {
  it("refuses looser-than-ceiling limits and accepts stricter ones", async () => {
    const m = createMockIpc();
    expect(
      await rejection(m.client.update_settings({ patch: { limits: { prompts_per_hour: 31 } } })),
    ).toMatchObject({
      kind: "rule_blocked",
      rule: 1,
    });
    expect(
      await rejection(
        m.client.update_settings({ patch: { limits: { run_minutes_per_day: 481 } } }),
      ),
    ).toMatchObject({ rule: 1 });
    expect(
      await rejection(m.client.update_settings({ patch: { limits: { backoff_base_s: 30 } } })),
    ).toMatchObject({
      kind: "rule_blocked",
      rule: 10,
    });
    expect(
      await rejection(m.client.update_settings({ patch: { limits: { min_dispatch_gap_s: 4 } } })),
    ).toMatchObject({
      rule: 10,
    });
    expect(
      await rejection(m.client.update_settings({ patch: { limits: { turns_per_task: 0 } } })),
    ).toMatchObject({
      kind: "invalid_input",
    });
    const next = await m.client.update_settings({
      patch: { limits: { prompts_per_hour: 20, backoff_base_s: 120 } },
    });
    expect(next.limits.prompts_per_hour).toBe(20);
    expect(next.limits.backoff_base_s).toBe(120);
    expect((await m.client.get_usage()).providers[0]?.prompts_last_hour.limit).toBe(20);
  });
});

describe("lead and plans (rule 9)", () => {
  it("the lead thinks for 1.5 s, then the plan is ready; one request in flight", async () => {
    const m = createMockIpc();
    const events: string[] = [];
    await m.client.listen("lead_changed", (r) => events.push(r.state));
    const planEvents: PlanView[] = [];
    await m.client.listen("plan_changed", (p) => planEvents.push(p));
    const { request_id } = await m.client.start_lead_request({
      lead: "claude",
      text: "Add a usage panel",
    });
    expect(
      await rejection(m.client.start_lead_request({ lead: "claude", text: "again" })),
    ).toMatchObject({
      kind: "invalid_input",
    });
    await m.control.advance(LEAD_THINK_MS - 1);
    expect((await m.client.list_lead_requests())[0]?.state).toBe("thinking");
    await m.control.advance(1);
    const req = (await m.client.list_lead_requests()).find((r) => r.request_id === request_id)!;
    expect(req.state).toBe("plan_ready");
    expect(events).toEqual(["thinking", "plan_ready"]);
    expect(planEvents[0]?.plan.plan_id).toBe(req.plan_id);
    expect(planEvents[0]?.status).toBe("draft");
  });

  it("cancel stops a thinking request", async () => {
    const m = createMockIpc();
    const { request_id } = await m.client.start_lead_request({ lead: "codex", text: "x" });
    await m.client.cancel_lead_request({ request_id });
    await m.control.advance(LEAD_THINK_MS);
    expect((await m.client.list_lead_requests())[0]?.state).toBe("cancelled");
    expect(await m.client.list_plans()).toEqual([]);
  });

  it("approval needs the current hash; an edit drops it and needs re-approval", async () => {
    const m = createMockIpc({ scenario: "plan_draft" });
    const view = await m.client.get_plan({ plan_id: PLAN_ID });
    expect(view.status).toBe("draft");
    expect(view.plan.approval).toBeUndefined();
    expect(view.plan_hash).toBe(await planHash(view.plan));
    expect(
      await rejection(m.approval.approve_plan({ plan_id: PLAN_ID, plan_hash: "0".repeat(64) })),
    ).toMatchObject({
      kind: "plan_hash_mismatch",
    });
    const approved = await m.approval.approve_plan({ plan_id: PLAN_ID, plan_hash: view.plan_hash });
    expect(approved.status).toBe("approved");
    expect(approved.plan.approval?.plan_hash).toBe(view.plan_hash);
    expect(approved.plan.approval?.approved_via).toBe("ui");
    const edited = await m.client.update_plan({
      plan_id: PLAN_ID,
      edit: {
        kind: "set_acceptance",
        task_id: "t3",
        acceptance: ["Docs updated", "make check passes"],
      },
    });
    expect(edited.plan.approval).toBeUndefined();
    expect(edited.status).toBe("draft");
    expect(edited.needs_reapproval).toBe(true);
    expect(edited.plan_hash).not.toBe(view.plan_hash);
    expect(
      await rejection(m.approval.approve_plan({ plan_id: PLAN_ID, plan_hash: view.plan_hash })),
    ).toMatchObject({
      kind: "plan_hash_mismatch",
    });
    const again = await m.approval.approve_plan({ plan_id: PLAN_ID, plan_hash: edited.plan_hash });
    expect(again.needs_reapproval).toBe(false);
  });

  it("an edit that makes a fallback the task's own provider opens a rule 2 violation", async () => {
    const m = createMockIpc({ scenario: "plan_draft" });
    const edited = await m.client.update_plan({
      plan_id: PLAN_ID,
      edit: { kind: "set_provider", task_id: "t3", provider: "claude", auth_mode: "subscription" },
    });
    expect(edited.violations).toEqual([expect.objectContaining({ rule: 2, task_id: "t3" })]);
  });

  it("plan_violations: over 40 turns, duplicate fallback, fallback not in plan; approval refused", async () => {
    const m = createMockIpc({ scenario: "plan_violations" });
    const [item] = await m.client.list_plans();
    const view = await m.client.get_plan({ plan_id: item!.plan_id });
    const rules = view.violations.map((v) => v.rule);
    expect(rules).toEqual(expect.arrayContaining([1, 2, 9]));
    expect(view.violations.some((v) => /twice/.test(v.message))).toBe(true);
    expect(
      await rejection(
        m.approval.approve_plan({ plan_id: view.plan.plan_id, plan_hash: view.plan_hash }),
      ),
    ).toMatchObject({ kind: "plan_has_violations" });
  });

  it("the hash ignores key order and the approval field", async () => {
    expect(canonicalJson({ b: 1, a: [2, { d: 1, c: 2 }] })).toBe('{"a":[2,{"c":2,"d":1}],"b":1}');
    const plan = structuredClone(planJson) as Parameters<typeof planHash>[0];
    const withApproval = {
      ...plan,
      approval: { plan_hash: "x", approved_at: "y", approved_via: "ui" as const, nonce: "z" },
    };
    expect(await planHash(withApproval)).toBe(await planHash(plan));
    expect(await planHash(plan)).toMatch(/^[0-9a-f]{64}$/);
  });
});

describe("sessions and the terminal (rules 1, 3, 10)", () => {
  it("running: streams terminal output; pty_write needs take-over (rule 3)", async () => {
    const m = createMockIpc({ scenario: "running" });
    const chunks: number[] = [];
    await m.client.listen("terminal_output", (c) => chunks.push(c.seq));
    await m.control.advance(1200);
    expect(chunks.length).toBe(3);
    const e = await rejection(m.ptyInput.pty_write({ session_id: "s-1", data: "ls\r" }));
    expect(e).toMatchObject({ kind: "rule_blocked", rule: 3 });
    const on = await m.client.set_takeover({ session_id: "s-1", enabled: true });
    expect(on.paused?.reason).toBe("takeover");
    await m.ptyInput.pty_write({ session_id: "s-1", data: "ls\r" });
    expect(await rejection(m.client.resume_session({ session_id: "s-1" }))).toMatchObject({
      kind: "invalid_input",
    });
    const off = await m.client.set_takeover({ session_id: "s-1", enabled: false });
    expect(off.paused?.reason).toBe("takeover");
    const resumed = await m.client.resume_session({ session_id: "s-1" });
    expect(resumed.paused).toBeNull();
    const attach = await m.client.attach_terminal({ session_id: "s-1" });
    expect(atob(attach.scrollback_b64)).toContain("ls\r");
  });

  it("running: user idle past the threshold pauses workers and blocks resume (rule 1)", async () => {
    const m = createMockIpc({ scenario: "running" });
    await m.control.setUserIdle(30);
    const s = (await m.client.list_sessions())[0]!;
    expect(s.paused?.reason).toBe("user_idle");
    expect(await rejection(m.client.resume_session({ session_id: s.session_id }))).toMatchObject({
      rule: 1,
    });
    await m.control.setUserIdle(0);
    expect((await m.client.resume_session({ session_id: s.session_id })).paused).toBeNull();
  });

  it("rate_limited: backoff from 60 s doubling, pause after 3 errors, user resume (rule 10)", async () => {
    const m = createMockIpc({ scenario: "rate_limited" });
    let s = (await m.client.list_sessions())[0]!;
    expect(s.state).toMatchObject({ kind: "rate_limited", attempt: 1 });
    const first = s.state.kind === "rate_limited" ? Date.parse(s.state.retry_at) : 0;
    const now = Date.parse((await m.client.get_usage()).as_of);
    expect(first - now).toBe(60_000);
    expect(await rejection(m.client.resume_session({ session_id: s.session_id }))).toMatchObject({
      kind: "rule_blocked",
      rule: 10,
    });
    await m.control.advance(60_000);
    s = (await m.client.list_sessions())[0]!;
    expect(s.state).toMatchObject({ kind: "rate_limited", attempt: 2 });
    await m.control.advance(120_000);
    s = (await m.client.list_sessions())[0]!;
    expect(s.paused?.reason).toBe("limit_errors");
    const provider = (await m.client.list_providers()).find((p) => p.provider === s.provider)!;
    expect(provider.usable.blockers).toContain("provider_paused");
    expect(
      (await m.client.get_usage()).providers.find((u) => u.provider === s.provider)?.pacing,
    ).toMatchObject({
      consecutive_limit_errors: 3,
      paused: true,
    });
    await m.client.resume_provider({ provider: s.provider });
    expect(
      (await m.client.list_providers()).find((p) => p.provider === s.provider)?.usable.blockers,
    ).toEqual([]);
  });

  it("no command ever types into a terminal on its own", async () => {
    const m = createMockIpc({ scenario: "running" });
    await m.control.advance(10_000);
    await m.client.list_sessions();
    expect(m.control.calls.filter((c) => c.command === "pty_write")).toHaveLength(0);
  });
});

describe("review scenarios", () => {
  it("review_ready and review_handoff_error", async () => {
    const ready = createMockIpc({ scenario: "review_ready" });
    const [item] = await ready.client.list_reviews();
    const review = await ready.client.get_review({ task_id: item!.task_id });
    expect(review.handoff.ok).toBe(true);
    expect((await ready.client.mark_reviewed({ task_id: item!.task_id })).reviewed).toBe(true);
    const broken = createMockIpc({ scenario: "review_handoff_error" });
    const [b] = await broken.client.list_reviews();
    const r = await broken.client.get_review({ task_id: b!.task_id });
    expect(r.handoff).toMatchObject({ ok: false });
  });

  it("review_injection passes hostile text through unchanged (the UI renders it as text)", async () => {
    const m = createMockIpc({ scenario: "review_injection" });
    const [item] = await m.client.list_reviews();
    const r = await m.client.get_review({ task_id: item!.task_id });
    expect(r.title).toContain("<img");
    expect(JSON.stringify(r)).toMatch(/javascript:|<script>/);
  });
});
