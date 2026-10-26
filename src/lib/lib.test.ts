import { describe, expect, it } from "vitest";

import { paths } from "@/app/paths";

import { base64ToUtf8, utf8ToBase64 } from "./base64";
import { formatMinutes, formatTokens, formatUsd } from "./format";
import { formatCountdown, msUntil } from "./time";

describe("time", () => {
  it("formatCountdown", () => {
    expect(formatCountdown(0)).toBe("0:00");
    expect(formatCountdown(-5)).toBe("0:00");
    expect(formatCountdown(NaN)).toBe("0:00");
    expect(formatCountdown(999)).toBe("0:01");
    expect(formatCountdown(60_000)).toBe("1:00");
    expect(formatCountdown(3_723_000)).toBe("1:02:03");
  });

  it("msUntil", () => {
    expect(msUntil("2026-10-25T09:31:00Z", Date.parse("2026-10-25T09:30:00Z"))).toBe(60_000);
    expect(msUntil("not a date", 0)).toBe(0);
  });
});

describe("format", () => {
  it("USD, minutes, tokens", () => {
    expect(formatUsd(3.42)).toBe("$3.42");
    expect(formatUsd(500)).toBe("$500.00");
    expect(formatMinutes(45)).toBe("45 min");
    expect(formatMinutes(90)).toBe("1 h 30 min");
    expect(formatMinutes(480)).toBe("8 h");
    expect(formatTokens(950)).toBe("950");
    expect(formatTokens(182_400)).toBe("182.4k");
    expect(formatTokens(2_000)).toBe("2k");
    expect(formatTokens(1_250_000)).toBe("1.3M");
  });
});

describe("base64", () => {
  it("round-trips UTF-8 and control bytes", () => {
    const text = "\u001b[31mred\u001b[0m ✓ ünïcode\r\n";
    expect(base64ToUtf8(utf8ToBase64(text))).toBe(text);
  });
});

describe("paths", () => {
  it("builds every route and encodes ids", () => {
    expect(paths.plan("plan 1/x")).toBe("/plans/plan%201%2Fx");
    expect(paths.review("t1", "tests")).toBe("/review/t1?tab=tests");
    expect(paths.review("t1")).toBe("/review/t1");
    expect(paths.session("s-1")).toBe("/sessions/s-1");
    expect([
      paths.providers(),
      paths.lead(),
      paths.plans(),
      paths.sessions(),
      paths.reviews(),
      paths.usage(),
      paths.settings(),
      paths.about(),
    ]).toEqual([
      "/providers",
      "/lead",
      "/plans",
      "/sessions",
      "/review",
      "/usage",
      "/settings",
      "/about",
    ]);
  });
});
