// Rule 3: text reaches a PTY only with take-over on and a real user event behind it.
import { describe, expect, it, vi } from "vitest";

import { createInputGate, MAX_CHUNK_BYTES, splitChunks } from "./input-gate";

function setup(takeover = true) {
  const element = document.createElement("div");
  const write = vi.fn(() => Promise.resolve());
  const onRefused = vi.fn();
  const state = { takeover };
  const gate = createInputGate(element, {
    write,
    takeoverOn: () => state.takeover,
    onRefused,
    isUserEvent: () => true,
  });
  const key = () => element.dispatchEvent(new KeyboardEvent("keydown", { key: "a" }));
  return { element, gate, write, onRefused, state, key };
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

describe("input gate", () => {
  it("take-over off plus a key sends nothing", async () => {
    const { gate, write, key } = setup(false);
    key();
    gate.onData("a");
    await flush();
    expect(write).not.toHaveBeenCalled();
  });

  it("take-over on plus a key sends once", async () => {
    const { gate, write, key } = setup();
    key();
    gate.onData("a");
    await flush();
    expect(write).toHaveBeenCalledTimes(1);
    expect(write).toHaveBeenCalledWith("a");
  });

  it("data with no user event, like a reply to a cursor query, is dropped", async () => {
    const { gate, write } = setup();
    gate.onData("\u001b[12;1R");
    await flush();
    expect(write).not.toHaveBeenCalled();
  });

  it("a key does not authorize data in a later turn", async () => {
    const { gate, write, key } = setup();
    key();
    await flush();
    gate.onData("\u001b[12;1R");
    await flush();
    expect(write).not.toHaveBeenCalled();
  });

  it("a browser event that is not trusted never counts", async () => {
    const element = document.createElement("div");
    const write = vi.fn(() => Promise.resolve());
    const gate = createInputGate(element, {
      write,
      takeoverOn: () => true,
      onRefused: vi.fn(),
    });
    // Scripted events have isTrusted = false, so this is what an injected event looks like.
    element.dispatchEvent(new KeyboardEvent("keydown", { key: "a" }));
    gate.onData("a");
    await flush();
    expect(write).not.toHaveBeenCalled();
  });

  it("shows a refusal once and does not retry", async () => {
    const { gate, write, onRefused, key } = setup();
    const refusal = new Error("Blocked by rule 3");
    write.mockImplementationOnce(() => Promise.reject(refusal));
    key();
    gate.onData("a");
    await flush();
    await flush();
    expect(write).toHaveBeenCalledTimes(1);
    expect(onRefused).toHaveBeenCalledWith(refusal);
  });

  it("keeps typed order while an earlier write is in flight", async () => {
    const { gate, write, key } = setup();
    const seen: string[] = [];
    write.mockImplementation((...args: unknown[]) => {
      seen.push(args[0] as string);
      return new Promise<void>((resolve) => setTimeout(resolve, 1));
    });
    key();
    gate.onData("a");
    gate.onData("b");
    gate.onData("c");
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(seen).toEqual(["a", "b", "c"]);
  });

  it("stops listening when disposed", async () => {
    const { gate, write, key } = setup();
    gate.dispose();
    key();
    gate.onData("a");
    await flush();
    expect(write).not.toHaveBeenCalled();
  });
});

describe("paste chunks", () => {
  it("never exceed the cap and never split a character", () => {
    const text = "é".repeat(MAX_CHUNK_BYTES);
    const chunks = splitChunks(text);
    expect(chunks.length).toBeGreaterThan(1);
    const encoder = new TextEncoder();
    for (const chunk of chunks) {
      expect(encoder.encode(chunk).length).toBeLessThanOrEqual(MAX_CHUNK_BYTES);
    }
    expect(chunks.join("")).toBe(text);
  });

  it("leave short text alone", () => {
    expect(splitChunks("short")).toEqual(["short"]);
  });
});
