import { describe, expect, it } from "vitest";

import type { SessionView } from "@/lib/ipc";

import { applySessionSnapshot, isLiveSession } from "./session-state";

function session(id: string, revision: number, state: SessionView["state"]): SessionView {
  return {
    session_id: id,
    kind: "interactive",
    provider: "claude",
    state,
    paused: null,
    turns: { current: 0, limit: 0 },
    started_at: "2026-11-01T00:00:00Z",
    takeover: true,
    revision,
  };
}

describe("session snapshots", () => {
  it("ignores an older revision so a stale event cannot revive an ended session", () => {
    const current = [session("t-1", 3, { kind: "killed" })];
    const next = applySessionSnapshot(current, session("t-1", 2, { kind: "running" }));
    expect(next[0]?.state.kind).toBe("killed");
  });

  it("applies a newer revision", () => {
    const current = [session("t-1", 2, { kind: "stopping" })];
    const next = applySessionSnapshot(current, session("t-1", 3, { kind: "killed" }));
    expect(next[0]?.state.kind).toBe("killed");
  });

  it("counts a stopping session as live", () => {
    expect(isLiveSession({ kind: "stopping" })).toBe(true);
    expect(isLiveSession({ kind: "killed" })).toBe(false);
  });
});
