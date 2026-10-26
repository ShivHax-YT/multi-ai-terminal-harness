// The only TypeScript file that names providers or vendors (hard rule 8). Everything else imports from here.
// Plain-text names only: no logos, icons or brand colors, and no wording that implies partnership.
// src/strings/providers.rule8.test.ts fails the build if a name appears anywhere else in src/ or index.html.

/** Provider ids, exactly as in docs/spec/plan.schema.json. */
export const PROVIDER_IDS = ["claude", "codex", "grok", "kimi", "gemini", "glm"] as const;

export type ProviderId = (typeof PROVIDER_IDS)[number];

/** Providers in the MVP (lead + one worker). */
export const MVP_PROVIDER_IDS = ["claude", "codex"] as const satisfies readonly ProviderId[];

const LABELS: Record<ProviderId, string> = {
  claude: "Claude Code",
  codex: "Codex CLI",
  grok: "Grok Build",
  kimi: "Kimi Code",
  gemini: "Gemini CLI",
  glm: "GLM (through Claude Code)",
};

const VENDORS: Record<ProviderId, string> = {
  claude: "Anthropic",
  codex: "OpenAI",
  grok: "xAI",
  kimi: "Moonshot AI",
  gemini: "Google",
  glm: "Z.ai",
};

export function isProviderId(value: unknown): value is ProviderId {
  return typeof value === "string" && (PROVIDER_IDS as readonly string[]).includes(value);
}

/** The CLI's plain-text name, e.g. for a table cell. */
export function providerLabel(id: ProviderId): string {
  return LABELS[id];
}

/** The company that publishes the CLI. */
export function vendorName(id: ProviderId): string {
  return VENDORS[id];
}

/** The About-screen statement (rule 8): independent, not affiliated, names are their owners' trademarks. */
export function notAffiliatedStatement(): string {
  const vendors = [...new Set(PROVIDER_IDS.map((id) => VENDORS[id]))];
  const list = `${vendors.slice(0, -1).join(", ")} or ${vendors[vendors.length - 1] ?? ""}`;
  return (
    `Harness is an independent app. It is not affiliated with, endorsed by or sponsored by ${list}. ` +
    "Product names are trademarks of their respective owners and are used only to identify the command-line tools " +
    "you install and sign in to yourself."
  );
}
