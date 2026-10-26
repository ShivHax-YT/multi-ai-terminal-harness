// Rule 8: provider and vendor names live only in src/strings/providers.ts. Everywhere else in src/ and index.html
// they are absent, except that fixtures may hold a provider id as an exact JSON string ("claude"). Test files are
// exempt. Also: no image assets in src/, and no brand-named files.
import { describe, expect, it } from "vitest";

import { isTestFile, listFiles, readRepo } from "@/test/repo";

import {
  isProviderId,
  MVP_PROVIDER_IDS,
  notAffiliatedStatement,
  PROVIDER_IDS,
  providerLabel,
  vendorName,
} from "./providers";

const BRAND =
  /\b(anthropic|claude|openai|chatgpt|codex|gpt(-\w+)?|xai|x\.ai|grok|gemini|google|moonshot|kimi|zhipu|z\.ai|zai|glm)\b/gi;

const STRINGS_FILE = "src/strings/providers.ts";
const FIXTURE_DIR = "src/lib/ipc/fixtures/";

function brandHits(file: string, text: string): string[] {
  const hits: string[] = [];
  for (const m of text.matchAll(BRAND)) {
    const at = m.index;
    const word = m[0];
    if (file.startsWith(FIXTURE_DIR)) {
      const exactJsonId =
        text[at - 1] === '"' && text[at + word.length] === '"' && isProviderId(word);
      if (exactJsonId) continue;
    }
    const line = text.slice(0, at).split("\n").length;
    hits.push(`${file}:${String(line)}: ${word}`);
  }
  return hits;
}

describe("rule 8: provider names only from src/strings/providers.ts", () => {
  const files = [
    ...listFiles("src").filter((f) => !isTestFile(f) && f !== STRINGS_FILE),
    "index.html",
  ];

  it("no provider or vendor name anywhere else in src/ or index.html", () => {
    expect(files.length).toBeGreaterThan(50);
    const hits = files.flatMap((f) => brandHits(f, readRepo(f)));
    expect(hits).toEqual([]);
  });

  it("the scan catches names in code and non-id fixture text", () => {
    expect(brandHits("src/features/x.tsx", 'const label = "Claude Code";')).toHaveLength(1);
    expect(brandHits("src/features/x.tsx", "// works with codex")).toHaveLength(1);
    expect(brandHits(`${FIXTURE_DIR}x.json`, '{"provider": "claude"}')).toEqual([]);
    expect(brandHits(`${FIXTURE_DIR}x.json`, '{"title": "Ask claude to fix it"}')).toHaveLength(1);
    expect(brandHits(`${FIXTURE_DIR}x.json`, '{"path": ".claude/x"}')).toHaveLength(1);
  });

  it("src/ has no image assets (no logos or icons; generic glyphs come from lucide-react)", () => {
    const images = listFiles("src").filter((f) =>
      /\.(png|jpe?g|gif|svg|webp|ico|icns|avif)$/i.test(f),
    );
    expect(images).toEqual([]);
  });

  it("index.html and the app title carry no provider name", () => {
    expect(readRepo("index.html")).toContain("<title>Harness</title>");
  });
});

describe("providers.ts", () => {
  it("ids match docs/spec/plan.schema.json", () => {
    const schema = JSON.parse(readRepo("docs/spec/plan.schema.json")) as {
      $defs: { provider: { enum: string[] } };
    };
    expect([...PROVIDER_IDS]).toEqual(schema.$defs.provider.enum);
    expect([...MVP_PROVIDER_IDS]).toEqual(["claude", "codex"]);
  });

  it("every id has a plain-text label and a vendor, with no partnership wording", () => {
    for (const id of PROVIDER_IDS) {
      expect(providerLabel(id)).toMatch(/^[A-Za-z0-9 .()]+$/);
      expect(vendorName(id)).toMatch(/^[A-Za-z0-9 .]+$/);
      expect(`${providerLabel(id)} ${vendorName(id)}`).not.toMatch(
        /official|powered|partner|certified/i,
      );
    }
    expect(notAffiliatedStatement()).not.toMatch(/official|powered by|partner/i);
  });

  it("isProviderId accepts ids only", () => {
    expect(isProviderId("codex")).toBe(true);
    expect(isProviderId("Codex")).toBe(false);
    expect(isProviderId(undefined)).toBe(false);
  });
});
