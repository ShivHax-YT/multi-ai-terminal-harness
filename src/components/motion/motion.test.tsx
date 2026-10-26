import { render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";

import { readRepo } from "@/test/repo";
import { setReducedMotion } from "@/test/setup";

import { MOTION_MS, PanelSwitch, Reveal, Shimmer, Stagger } from "./index";

afterEach(() => {
  setReducedMotion(false);
});

function all() {
  return render(
    <>
      <Stagger>
        <p>one</p>
        <p>two</p>
      </Stagger>
      <Shimmer>Thinking</Shimmer>
      <Reveal>
        <p>entrance</p>
      </Reveal>
      <PanelSwitch activeIndex={1}>
        <p>first</p>
        <p>second</p>
      </PanelSwitch>
    </>,
  );
}

describe("motion wrappers", () => {
  it("render static content under prefers-reduced-motion", () => {
    setReducedMotion(true);
    const { container } = all();
    const marks = [...container.querySelectorAll("[data-motion]")].map((e) =>
      e.getAttribute("data-motion"),
    );
    expect(marks).toEqual(["static", "static", "static", "static"]);
    for (const el of container.querySelectorAll("*")) {
      expect((el as HTMLElement).style.opacity).toBe("");
      expect((el as HTMLElement).style.transform).toBe("");
    }
    expect(screen.getByText("second")).toBeInTheDocument();
    expect(screen.queryByText("first")).not.toBeInTheDocument();
  });

  it("animate otherwise, with the same content", () => {
    const { container } = all();
    const marks = [...container.querySelectorAll("[data-motion]")].map((e) =>
      e.getAttribute("data-motion"),
    );
    expect(marks).toEqual(["stagger", "shimmer", "reveal", "panel"]);
    expect(screen.getByText("one")).toBeInTheDocument();
    expect(screen.getByText("Thinking")).toBeInTheDocument();
    expect(screen.getByText("entrance")).toBeInTheDocument();
    expect(screen.getByText("second")).toBeInTheDocument();
  });

  it("timings stay inside the design limits", () => {
    expect(MOTION_MS.staggerStep).toBe(40);
    expect(MOTION_MS.staggerItem).toBeLessThanOrEqual(MOTION_MS.staggerMax);
    expect(MOTION_MS.staggerMax).toBeLessThanOrEqual(300);
    expect(MOTION_MS.panel).toBeLessThanOrEqual(MOTION_MS.panelMax);
    expect(MOTION_MS.panelMax).toBeLessThanOrEqual(250);
    expect(MOTION_MS.entrance).toBeLessThanOrEqual(600);
  });

  it("the wrappers animate transform and opacity only (Shimmer is an opacity pulse until the human OKs Text Shimmer)", () => {
    const src = readRepo("src/components/motion/index.tsx");
    const animated = [
      ...src.matchAll(/\b(?:hidden|visible|enter|center|exit|animate|initial):\s*\{([^}]*)\}/g),
    ]
      .map((m) => m[1] ?? "")
      .join(",");
    const keys = [...animated.matchAll(/([a-zA-Z]+):/g)].map((m) => m[1]);
    for (const k of keys)
      expect(["opacity", "x", "y", "scale", "transition", "staggerChildren"]).toContain(k);
    expect(src).not.toMatch(/TextShimmer|backgroundPosition|filter|blur/);
    expect(src).toMatch(/<MotionConfig reducedMotion="user">/);
  });
});
