// Rule 8: provider names come only from the strings file; no logos or icons; no wording that implies partnership.
import { screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { isTestFile, listFiles, readRepo } from "@/test/repo";
import { renderRoute } from "@/test/render";
import { PROVIDER_IDS, providerLabel } from "@/strings/providers";

const BRAND =
  /\b(anthropic|claude|openai|chatgpt|codex|gpt(-\w+)?|xai|x\.ai|grok|gemini|google|moonshot|kimi|zhipu|z\.ai|zai|glm)\b/i;
const IMPLIED = /official|powered by|partner|endorse|affiliat|https?:\/\//i;

const sources = listFiles("src/features/providers").filter(
  (f) => /\.tsx?$/.test(f) && !isTestFile(f),
);

describe("rule 8: source", () => {
  it("has source files to scan", () => {
    expect(sources.length).toBeGreaterThanOrEqual(4);
  });

  it("names no provider or vendor, and no partnership wording or URL", () => {
    for (const file of sources) {
      const text = readRepo(file);
      expect(BRAND.exec(text), `${file} names a provider`).toBeNull();
      expect(IMPLIED.exec(text), `${file} has implied-partnership wording or a URL`).toBeNull();
    }
  });

  it("has no image assets or icon imports of its own", () => {
    const files = listFiles("src/features/providers");
    expect(files.filter((f) => /\.(png|jpe?g|gif|svg|webp|ico|icns|avif)$/i.test(f))).toEqual([]);
  });
});

describe("rule 8: rendered", () => {
  it("shows each name as plain text from the strings file, with no images", async () => {
    const { container } = renderRoute("/providers", { mock: "ready" });
    await screen.findByRole("group", { name: providerLabel("claude") }, { timeout: 10_000 });
    const headings = screen
      .getAllByRole("group")
      .map((g) => within(g).getByRole("heading", { level: 2 }).textContent);
    expect(headings).toEqual(PROVIDER_IDS.map((id) => providerLabel(id)));
    expect(
      container.querySelector("img, picture, canvas, video, [style*='background-image']"),
    ).toBe(null);
    const main = container.querySelector("main");
    expect(main?.textContent ?? "").not.toMatch(IMPLIED);
  });

  it("does not name a provider in any card text other than through its name element", async () => {
    renderRoute("/providers", { mock: "ready" });
    const claude = await screen.findByRole(
      "group",
      { name: providerLabel("claude") },
      { timeout: 10_000 },
    );
    const outside = claude.textContent.replace(providerLabel("claude"), "");
    expect(outside).not.toMatch(BRAND);
    expect(within(claude).getByText(providerLabel("claude"))).toHaveAttribute(
      "data-provider",
      "claude",
    );
  });
});
