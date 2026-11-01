import { describe, expect, it } from "vitest";

import { createAttachGeneration } from "./attach-generation";

describe("attach generation", () => {
  it("allows one attach at a time and ignores an older generation", () => {
    const generation = createAttachGeneration();
    const first = generation.begin();
    expect(first).toBe(1);
    expect(generation.begin()).toBeNull();
    generation.finish();
    const second = generation.begin();
    expect(second).toBe(2);
    expect(generation.shouldApply(first ?? 0, 10, null)).toBe(false);
    expect(generation.shouldApply(second ?? 0, 10, null)).toBe(true);
  });

  it("does not apply a snapshot older than output already shown", () => {
    const generation = createAttachGeneration();
    const ticket = generation.begin();
    expect(generation.shouldApply(ticket ?? 0, 4, 8)).toBe(false);
    expect(generation.shouldApply(ticket ?? 0, 8, 8)).toBe(true);
    expect(generation.shouldApply(ticket ?? 0, 9, 8)).toBe(true);
  });
});
