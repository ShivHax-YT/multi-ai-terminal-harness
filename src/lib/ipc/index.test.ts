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
