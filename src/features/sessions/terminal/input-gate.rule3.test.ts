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
  // xterm emits a key's data during the event, after the capture listener and before dispatch ends.
  const key = (data = "a") => {
    const deliver = () => {
      gate.onData(data);
    };
    element.addEventListener("keydown", deliver, true);
    element.dispatchEvent(new KeyboardEvent("keydown", { key: "a", bubbles: true }));
    element.removeEventListener("keydown", deliver, true);
  };
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

  it("a key does not authorize data after dispatch ends", async () => {
    const { element, gate, write } = setup();
    element.dispatchEvent(new KeyboardEvent("keydown", { key: "a", bubbles: true }));
    gate.onData("a");
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
    const { element, gate, write } = setup();
    const seen: string[] = [];
    write.mockImplementation((...args: unknown[]) => {
      seen.push(args[0] as string);
      return new Promise<void>((resolve) => setTimeout(resolve, 1));
    });
    element.addEventListener(
      "keydown",
      () => {
        gate.onData("a");
        gate.onData("b");
        gate.onData("c");
      },
      true,
    );
    element.dispatchEvent(new KeyboardEvent("keydown", { key: "a", bubbles: true }));
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

  it("keeps composed text when input follows compositionend before xterm's timer", async () => {
    const { element, write, onRefused, state, gate: earlier } = setup();
    earlier.dispose();
    // xterm's listener is registered first. It queues onData from compositionend. The browser then
    // dispatches input before that timer. Closing the turn on that input drops the character.
    const held: { gate: ReturnType<typeof createInputGate> | null } = { gate: null };
    element.addEventListener("compositionend", () => {
      setTimeout(() => {
        held.gate?.onData("é");
        held.gate?.onData("\u001b[?12;1R");
        held.gate?.onData("\u001b[0n");
        held.gate?.onData("\u001b[12;1R");
      }, 0);
    });
    const gate = createInputGate(element, {
      write,
      takeoverOn: () => state.takeover,
      onRefused,
      isUserEvent: () => true,
    });
    held.gate = gate;
    element.dispatchEvent(new KeyboardEvent("keydown", { key: "Dead", bubbles: true }));
    element.dispatchEvent(new CompositionEvent("compositionend", { data: "é", bubbles: true }));
    element.dispatchEvent(new InputEvent("input", { bubbles: true, data: "é" }));
    element.dispatchEvent(
      new InputEvent("input", { bubbles: true, inputType: "insertFromComposition", data: "é" }),
    );
    element.dispatchEvent(new KeyboardEvent("keypress", { key: "é", bubbles: true }));
    await flush();
    expect(write).toHaveBeenCalledTimes(1);
    expect(write).toHaveBeenCalledWith("é");
    await flush();
    gate.onData("x");
    expect(write).toHaveBeenCalledTimes(1);
  });

  it("keeps text when input follows keyCode 229 before xterm's timer", async () => {
    const { element, write, onRefused, state, gate: earlier } = setup();
    earlier.dispose();
    const held: { gate: ReturnType<typeof createInputGate> | null } = { gate: null };
    element.addEventListener("keydown", () => {
      setTimeout(() => {
        held.gate?.onData("日");
      }, 0);
    });
    const gate = createInputGate(element, {
      write,
      takeoverOn: () => state.takeover,
      onRefused,
      isUserEvent: () => true,
    });
    held.gate = gate;
    const key = new KeyboardEvent("keydown", { key: "Unidentified", bubbles: true });
    Object.defineProperty(key, "keyCode", { get: () => 229 });
    element.dispatchEvent(key);
    element.dispatchEvent(new InputEvent("input", { bubbles: true, data: "日" }));
    await flush();
    expect(write).toHaveBeenCalledTimes(1);
    expect(write).toHaveBeenCalledWith("日");
  });

  it("drops cursor, device-attribute, and focus replies while a key is dispatching", async () => {
    const { element, gate, write } = setup();
    element.addEventListener(
      "keydown",
      () => {
        gate.onData("\u001b[12;1R");
        gate.onData("\u001b[?1;2c");
        gate.onData("\u001b[I");
        gate.onData("\u001b[O");
        gate.onData("a");
      },
      true,
    );
    element.dispatchEvent(new KeyboardEvent("keydown", { key: "a", bubbles: true }));
    await flush();
    expect(write).toHaveBeenCalledTimes(1);
    expect(write).toHaveBeenCalledWith("a");
  });

  it("sends a unicode paste in order", async () => {
    const { element, gate, write } = setup();
    const seen: string[] = [];
    write.mockImplementation((...args: unknown[]) => {
      seen.push(args[0] as string);
      return Promise.resolve();
    });
    element.addEventListener(
      "paste",
      () => {
        gate.onData("你");
        gate.onData("好");
      },
      true,
    );
    element.dispatchEvent(new Event("paste", { bubbles: true }));
    await flush();
    expect(seen).toEqual(["你", "好"]);
  });

  it("does not write or refuse a queued chunk after take-over is turned off", async () => {
    const { element, gate, write, onRefused, state } = setup();
    write.mockImplementation((...args: unknown[]) => {
      if (args[0] === "a") state.takeover = false;
      return Promise.resolve();
    });
    element.addEventListener(
      "keydown",
      () => {
        gate.onData("a");
        gate.onData("b");
      },
      true,
    );
    element.dispatchEvent(new KeyboardEvent("keydown", { key: "a", bubbles: true }));
    await flush();
    await flush();
    expect(write).toHaveBeenCalledTimes(1);
    expect(write).toHaveBeenCalledWith("a");
    expect(onRefused).not.toHaveBeenCalled();
  });

  it("drops a queued chunk after dispose", async () => {
    const { element, gate, write, onRefused } = setup();
    write.mockImplementation(() => {
      gate.dispose();
      return Promise.resolve();
    });
    element.addEventListener(
      "keydown",
      () => {
        gate.onData("a");
        gate.onData("b");
      },
      true,
    );
    element.dispatchEvent(new KeyboardEvent("keydown", { key: "a", bubbles: true }));
    await flush();
    await flush();
    expect(write).toHaveBeenCalledTimes(1);
    expect(onRefused).not.toHaveBeenCalled();
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
