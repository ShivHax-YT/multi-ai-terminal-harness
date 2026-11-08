import { afterEach, describe, expect, it, vi } from "vitest";

import { loadIpc } from "./index";

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

describe("native transport selection", () => {
  it("uses the native transport inside Tauri even when development requests a mock", async () => {
    vi.stubEnv("DEV", true);
    vi.stubEnv("VITE_HARNESS_IPC", "mock");
    vi.stubGlobal("isTauri", true);
    expect((await loadIpc()).mode).toBe("native");
  });

  it("rejects browser-only actions before invoking native IPC", async () => {
    vi.stubEnv("DEV", true);
    vi.stubGlobal("isTauri", true);
    const invoke = vi.fn();
    vi.stubGlobal("__TAURI_INTERNALS__", { invoke });
    const bundle = await loadIpc();
    const plan = { plan_id: "sim-1", plan_hash: "hash" };
    await expect(bundle.approval.sim_approve_plan(plan)).rejects.toMatchObject({
      kind: "not_implemented",
    });
    await expect(bundle.client.sim_run({ ...plan, token: "token" })).rejects.toMatchObject({
      kind: "not_implemented",
    });
    await expect(bundle.client.choose_terminal_folder()).rejects.toMatchObject({
      kind: "not_implemented",
    });
    await expect(
      bundle.client.start_terminal({
        provider: "claude",
        folder: "/fake/project",
        confirm_personal_use: true,
      }),
    ).rejects.toMatchObject({ kind: "not_implemented" });
    await expect(
      bundle.ptyInput.pty_write({ session_id: "t-1", data: "fixture" }),
    ).rejects.toMatchObject({ kind: "rule_blocked", rule: 3 });
    expect(invoke).not.toHaveBeenCalled();
  });

  it("keeps the browser-only development demo explicitly labelled", async () => {
    vi.stubEnv("DEV", true);
    vi.stubEnv("VITE_HARNESS_IPC", "mock");
    vi.stubGlobal("isTauri", false);
    expect((await loadIpc()).mode).toBe("mock");
  });

  it("uses native IPC in production", async () => {
    vi.stubEnv("DEV", false);
    vi.stubEnv("VITE_HARNESS_IPC", "mock");
    vi.stubGlobal("isTauri", false);
    expect((await loadIpc()).mode).toBe("native");
  });
});
