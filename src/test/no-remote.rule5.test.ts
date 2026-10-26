// Rule 5 (and strict CSP): the UI loads nothing remote. No http(s) URL in app source or index.html, no protocol-relative
// URL, and fonts come from the bundled @fontsource packages. Test files are exempt (they hold URLs as test data).
import { describe, expect, it } from "vitest";

import { isTestFile, listFiles, readRepo } from "./repo";

// SVG namespaces in vendored icon markup are identifiers, not fetches.
const ALLOWED = /^https?:\/\/www\.w3\.org\//;
// Hostile mock data (prompt-injection fixture for the review screen): never loaded, never shipped (the Rust stubs
// include only the read fixtures, and the dist sentinel keeps the mock out of the bundle).
const HOSTILE_FIXTURES = new Set(["src/lib/ipc/fixtures/review-injection.json"]);

describe("rule 5: no remote content", () => {
  const files = [
    ...listFiles("src").filter((f) => !isTestFile(f) && !HOSTILE_FIXTURES.has(f)),
    "index.html",
  ];

  it("no http(s) or protocol-relative URL in src/ or index.html", () => {
    const hits: string[] = [];
    for (const f of files) {
      const text = readRepo(f);
      for (const m of text.matchAll(/https?:\/\/[^\s"'`)]+/gi)) {
        if (!ALLOWED.test(m[0])) hits.push(`${f}: ${m[0]}`);
      }
      // Protocol-relative URLs inside a string or url(...): "//host/...".
      for (const m of text.matchAll(/["'`(]\/\/[a-z0-9-]+\.[a-z]/gi)) hits.push(`${f}: ${m[0]}`);
    }
    expect(hits).toEqual([]);
  });

  it("the hostile fixture is never bundled into the Rust binary", () => {
    expect(readRepo("src-tauri/src/commands.rs")).not.toMatch(/review-injection/);
  });

  it("fonts are bundled through @fontsource, never fetched", () => {
    const main = readRepo("src/main.tsx");
    expect(main).toContain('import "@fontsource-variable/inter";');
    expect(main).toContain('import "@fontsource-variable/jetbrains-mono";');
    const css = readRepo("src/styles/globals.css");
    expect(css).not.toMatch(/@import\s+url\(|fonts\.googleapis|@font-face[^}]*url\(\s*["']?https?:/);
    expect(readRepo("index.html")).not.toMatch(/<link[^>]+(stylesheet|preconnect|font)/);
  });

  it("index.html loads only the local entry script", () => {
    const scripts = [...readRepo("index.html").matchAll(/<script[^>]*src="([^"]+)"/g)].map((m) => m[1]);
    expect(scripts).toEqual(["/src/main.tsx"]);
  });
});
