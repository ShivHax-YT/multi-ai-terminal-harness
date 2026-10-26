// docs/design/tokens.md is the source of truth: every color in its table must equal globals.css (light `:root`, dark
// `.dark`), every contrast ratio it states is recomputed (WCAG 2.x), and no blue, teal-green or clay-orange appears
// anywhere (rule 8: no provider brand colors). Radius and motion tokens are checked too.
import { describe, expect, it } from "vitest";

import { isTestFile, listFiles, readRepo } from "@/test/repo";

const css = readRepo("src/styles/globals.css");
const doc = readRepo("docs/design/tokens.md");

function block(selector: string): Map<string, string> {
  const start = css.indexOf(`${selector} {`);
  const body = css.slice(start, css.indexOf("}", start));
  const out = new Map<string, string>();
  for (const m of body.matchAll(/(--[a-z0-9-]+):\s*([^;]+);/g))
    out.set(m[1] ?? "", (m[2] ?? "").trim().toLowerCase());
  return out;
}

const light = block(":root");
const dark = block(".dark");

function luminance(hex: string): number {
  const h = hex.replace("#", "");
  const [r, g, b] = [0, 2, 4].map((i) => {
    const c = parseInt(h.slice(i, i + 2), 16) / 255;
    return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  }) as [number, number, number];
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

export function contrast(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x) as [number, number];
  return (hi + 0.05) / (lo + 0.05);
}

function hueSat(hex: string): { hue: number; sat: number } {
  const h = hex.replace("#", "");
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16) / 255) as [
    number,
    number,
    number,
  ];
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const l = (max + min) / 2;
  const d = max - min;
  if (d === 0) return { hue: 0, sat: 0 };
  const sat = d / (1 - Math.abs(2 * l - 1));
  let hue = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
  hue = (hue * 60 + 360) % 360;
  return { hue, sat };
}

interface Row {
  tokens: string[][];
  light: string[];
  dark: string[];
  contrast: string;
}

function rows(): Row[] {
  const table = doc.slice(doc.indexOf("| Token | Light | Dark |"), doc.indexOf("Derived tokens"));
  return table
    .split("\n")
    .filter((l) => l.startsWith("| --"))
    .map((l) => {
      const [tokenCell = "", lightCell = "", darkCell = "", contrastCell = ""] = l
        .split("|")
        .slice(1, -1)
        .map((c) => c.trim());
      const tokens = tokenCell
        .replace(/\([^)]*\)/g, "")
        .split("/")
        .map((g) =>
          g
            .split(",")
            .map((t) => t.trim())
            .filter((t) => t.startsWith("--")),
        );
      const hexes = (c: string) =>
        [...c.matchAll(/#[0-9A-Fa-f]{6}/g)].map((m) => m[0].toLowerCase());
      const lightHex = hexes(lightCell);
      return {
        tokens,
        light: lightHex,
        dark: darkCell === "same" ? lightHex : hexes(darkCell),
        contrast: contrastCell,
      };
    });
}

describe("tokens.md = globals.css", () => {
  const table = rows();

  it("parses the 8 color rows", () => {
    expect(table).toHaveLength(8);
  });

  it("every token in the table has its light and dark value in globals.css", () => {
    let checked = 0;
    for (const row of table) {
      row.tokens.forEach((group, i) => {
        for (const token of group) {
          expect(light.get(token), `${token} light`).toBe(row.light[i]);
          expect(dark.get(token), `${token} dark`).toBe(row.dark[i]);
          checked += 1;
        }
      });
    }
    expect(checked).toBe(17);
  });

  it("derived tokens reuse table colors only", () => {
    for (const theme of [light, dark]) {
      expect(theme.get("--card-foreground")).toBe(theme.get("--foreground"));
      expect(theme.get("--popover-foreground")).toBe(theme.get("--foreground"));
      expect(theme.get("--secondary-foreground")).toBe(theme.get("--foreground"));
      expect(theme.get("--accent-foreground")).toBe(theme.get("--foreground"));
      expect(theme.get("--sidebar-primary")).toBe(theme.get("--primary"));
      expect(theme.get("--sidebar-ring")).toBe(theme.get("--primary"));
      expect(theme.get("--sidebar-border")).toBe(theme.get("--border"));
    }
    expect(light.get("--primary-foreground")).toBe("#ffffff");
    expect(dark.get("--primary-foreground")).toBe("#17171b");
    expect(light.get("--destructive-foreground")).toBe("#ffffff");
    expect(dark.get("--destructive-foreground")).toBe("#17171b");
  });
});

describe("contrast ratios (WCAG AA)", () => {
  const L = (t: string) => light.get(t) ?? "";
  const D = (t: string) => dark.get(t) ?? "";
  // [row index, pairs in the order the doc lists the numbers, minimum ratio]
  const expectations: [number, [string, string][], number][] = [
    [2, [["--input", "--card"]], 3],
    [
      3,
      [
        ["--foreground", "--background"],
        ["--muted-foreground", "--background"],
        ["--muted-foreground", "--muted"],
      ],
      4.5,
    ],
    [
      4,
      [
        ["--primary", "--background"],
        ["--primary-foreground", "--primary"],
      ],
      4.5,
    ],
    [
      5,
      [
        ["--success", "--background"],
        ["--warning", "--background"],
      ],
      4.5,
    ],
    [
      6,
      [
        ["--destructive", "--background"],
        ["--destructive-foreground", "--destructive"],
      ],
      4.5,
    ],
  ];

  it.each(expectations)(
    "row %i states the recomputed ratios and meets the minimum",
    (index, pairs, min) => {
      const row = rows()[index];
      expect(row).toBeDefined();
      const stated = [...(row?.contrast ?? "").matchAll(/\b\d+\.\d\b/g)].map((m) => Number(m[0]));
      const computed = pairs.flatMap(([a, b]) => [contrast(L(a), L(b)), contrast(D(a), D(b))]);
      expect(stated).toHaveLength(computed.length);
      computed.forEach((value, i) => {
        expect(Math.abs(value - (stated[i] ?? 0))).toBeLessThanOrEqual(0.06);
        expect(value).toBeGreaterThanOrEqual(min);
      });
    },
  );

  it("terminal text is readable and the focus ring is at least 3:1", () => {
    expect(contrast(L("--terminal-fg"), L("--terminal-bg"))).toBeCloseTo(15.2, 0);
    expect(D("--terminal-bg")).toBe(L("--terminal-bg"));
    expect(contrast(L("--ring"), L("--background"))).toBeGreaterThanOrEqual(3);
    expect(contrast(D("--ring"), D("--background"))).toBeGreaterThanOrEqual(3);
  });
});

describe("rule 8: no blue, teal-green or clay-orange anywhere", () => {
  const banned = (hue: number) =>
    (hue >= 140 && hue <= 265) || // teal-green, cyan, blue
    (hue >= 10 && hue <= 35); // clay-orange

  it("every saturated color in globals.css sits outside the banned hues", () => {
    const hexes = [...css.matchAll(/#[0-9a-fA-F]{6}\b/g)].map((m) => m[0]);
    expect(hexes.length).toBeGreaterThan(40);
    for (const hex of hexes) {
      const { hue, sat } = hueSat(hex);
      if (sat > 0.2) expect(banned(hue), `${hex} hue ${hue.toFixed(0)}`).toBe(false);
    }
  });

  it("app code uses tokens only: no raw colors or Tailwind palette hues", () => {
    const files = listFiles("src").filter(
      (f) => /\.(ts|tsx|css)$/.test(f) && !isTestFile(f) && f !== "src/styles/globals.css",
    );
    const raw = /#[0-9a-fA-F]{3,8}\b(?![-\w])|\b(rgb|rgba|hsl|hsla|oklch|oklab)\(/;
    const palette =
      /\b(bg|text|border|ring|fill|stroke|from|to|via|outline|shadow)-(blue|sky|cyan|teal|emerald|green|lime|indigo|violet|purple|orange|amber|yellow|red|rose|pink|fuchsia|slate|gray|zinc|neutral|stone)-\d{2,3}\b/;
    const hits = files.filter((f) => {
      const text = readRepo(f);
      return raw.test(text.replace(/&#\d+;/g, "")) || palette.test(text);
    });
    expect(hits).toEqual([]);
  });
});

describe("radius, motion and type tokens", () => {
  it("radius: 14px cards, 10px controls, full chips", () => {
    expect(light.get("--radius-card")).toBe("14px");
    expect(light.get("--radius-control")).toBe("10px");
    expect(light.get("--radius-chip")).toBe("9999px");
  });

  it("motion: 150 / 220 / 300 / 600 ms and the ease-out curve", () => {
    expect(light.get("--duration-fast")).toBe("150ms");
    expect(light.get("--duration-base")).toBe("220ms");
    expect(light.get("--duration-slow")).toBe("300ms");
    expect(light.get("--duration-entrance")).toBe("600ms");
    expect(css).toMatch(/--ease-out:\s*cubic-bezier\(0\.16,\s*1,\s*0\.3,\s*1\)/);
  });

  it("type: Inter Variable 16px / 1.55, JetBrains Mono Variable 13px / 1.5", () => {
    expect(css).toMatch(/--font-sans:\s*"Inter Variable"/);
    expect(css).toMatch(/--font-mono:\s*"JetBrains Mono Variable"/);
    expect(css).toMatch(/font-size: 16px;/);
    expect(css).toMatch(/line-height: 1\.55;/);
    expect(css).toMatch(/font-size: 13px;\s*line-height: 1\.5;/);
  });
});
