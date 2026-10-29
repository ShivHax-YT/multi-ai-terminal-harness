import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { IpcRejection } from "@/lib/ipc/contract";

import {
  Countdown,
  EmptyState,
  ErrorAlert,
  LoadingSkeleton,
  Meter,
  meterLevel,
  ProviderName,
  StatusChip,
  UntrustedText,
} from "./index";

const HOSTILE =
  "<img src=x onerror=alert(1)> <script>alert(1)</script> [x](javascript:alert(1)) https://example.invalid";

describe("UntrustedText", () => {
  it("renders hostile text as one text node: no elements, no links, whitespace kept", () => {
    const { container } = render(<UntrustedText text={`${HOSTILE}\n  line two`} />);
    const el = container.querySelector("[data-untrusted]");
    expect(el?.children).toHaveLength(0);
    expect(el?.childNodes).toHaveLength(1);
    expect(el?.textContent).toBe(`${HOSTILE}\n  line two`);
    expect(container.querySelector("img, script, a, iframe")).toBeNull();
    expect(el?.className).toMatch(/whitespace-pre-wrap/);
  });

  it("has mono and block variants", () => {
    const { container } = render(<UntrustedText text="diff" mono block />);
    const el = container.querySelector("[data-untrusted]");
    expect(el?.tagName).toBe("DIV");
    expect(el?.className).toMatch(/font-mono/);
  });
});

describe("ErrorAlert", () => {
  it('shows "Blocked by rule N" for rule refusals', () => {
    render(
      <ErrorAlert
        error={new IpcRejection({ kind: "rule_blocked", rule: 3, message: "Take-over is off." })}
      />,
    );
    const alert = screen.getByRole("alert");
    expect(alert).toHaveTextContent("Blocked by rule 3:");
    expect(alert).toHaveTextContent("Take-over is off.");
  });

  it("normalizes unknown errors to internal and keeps messages as text", () => {
    const { container } = render(<ErrorAlert error={new Error("<b>boom</b>")} />);
    expect(screen.getByRole("alert")).toHaveTextContent("Something went wrong");
    expect(screen.getByRole("alert")).toHaveTextContent("<b>boom</b>");
    expect(container.querySelector("b")).toBeNull();
  });
});

describe("Meter", () => {
  it("levels: ok below 80 %, warning from 80 %, danger at 100 %", () => {
    expect(meterLevel(23, 30)).toBe("ok");
    expect(meterLevel(24, 30)).toBe("warning");
    expect(meterLevel(30, 30)).toBe("danger");
    expect(meterLevel(0, 0)).toBe("ok");
  });

  it('reads "x of y" with an icon plus a text label, never color alone', () => {
    render(<Meter label="Prompts this hour" current={24} limit={30} />);
    expect(screen.getByText("24 of 30")).toBeInTheDocument();
    expect(screen.getByText("Near limit")).toBeInTheDocument();
    expect(screen.getByRole("meter", { name: "Prompts this hour" })).toHaveAttribute(
      "aria-valuetext",
      "24 of 30, near limit",
    );
  });
});

describe("other composites", () => {
  it("ProviderName is plain text from the strings file, no image", () => {
    const { container } = render(<ProviderName id="codex" />);
    expect(container.textContent).not.toBe("");
    expect(container.querySelector("img, svg")).toBeNull();
  });

  it("Countdown formats time left and shows the done label after", () => {
    const now = Date.parse("2026-10-25T09:30:00Z");
    const { rerender } = render(<Countdown until="2026-10-25T09:31:05Z" now={now} />);
    expect(screen.getByText("1:05")).toBeInTheDocument();
    rerender(<Countdown until="2026-10-25T09:29:00Z" now={now} doneLabel="ready" />);
    expect(screen.getByText("ready")).toBeInTheDocument();
  });

  it("EmptyState and LoadingSkeleton are labelled", () => {
    render(
      <>
        <EmptyState title="No plans yet" description="Ask the lead." />
        <LoadingSkeleton label="Loading plans" />
      </>,
    );
    expect(screen.getByRole("heading", { name: "No plans yet" })).toBeInTheDocument();
    expect(screen.getByRole("status", { name: "Loading plans" })).toBeInTheDocument();
  });
});

describe("StatusChip", () => {
  it("shows the label as text and an icon for every tone", () => {
    for (const tone of ["success", "warning", "danger", "info", "neutral"] as const) {
      const { container, unmount } = render(<StatusChip tone={tone} label={`State ${tone}`} />);
      expect(screen.getByText(`State ${tone}`)).toBeInTheDocument();
      expect(container.querySelector("svg")).not.toBeNull();
      expect(container.querySelector(`[data-tone="${tone}"]`)).not.toBeNull();
      unmount();
    }
  });
});
