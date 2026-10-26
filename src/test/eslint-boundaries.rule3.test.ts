// Lints snippets against the real eslint.config.js to prove the import zones hold (rule 3, rule 9, one IPC door, the
// mock never ships, motion through wrappers, feature isolation) for both the `@` alias and relative imports, and that
// untrusted text can never become HTML. If a flat-config override silently dropped a restriction, this fails.
import path from "node:path";

import { ESLint } from "eslint";
import { beforeAll, describe, expect, it } from "vitest";

const root = path.resolve(import.meta.dirname, "../..");
let eslint: ESLint;

beforeAll(() => {
  eslint = new ESLint({
    cwd: root,
    // Snippet files do not exist on disk, so type-aware parsing is off and only the guard rules run.
    overrideConfig: {
      languageOptions: { parserOptions: { projectService: false, project: null } },
    },
    ruleFilter: ({ ruleId }) =>
      [
        "import-x/no-restricted-paths",
        "no-restricted-imports",
        "no-restricted-properties",
        "no-restricted-syntax",
        "no-restricted-globals",
        "react/no-danger",
        "no-eval",
        "no-new-func",
      ].includes(ruleId),
  });
});

async function errors(file: string, code: string): Promise<string[]> {
  const [result] = await eslint.lintText(code, { filePath: path.join(root, file) });
  if (result === undefined) throw new Error("no lint result");
  const fatal = result.messages.filter((m) => m.fatal === true);
  if (fatal.length > 0) throw new Error(`parse error: ${fatal.map((m) => m.message).join("; ")}`);
  return result.messages.map((m) => m.ruleId ?? "unknown");
}

const imp = (what: string, from: string) =>
  `import { ${what} } from "${from}";\nexport const x = ${what};\n`;

describe("rule 3: PTY input port and xterm only in the terminal view", () => {
  const port = "usePtyInput";
  const cases: [file: string, source: string][] = [
    ["src/features/lead/thread.tsx", "@/lib/ipc/pty-input"],
    ["src/features/lead/thread.tsx", "../../lib/ipc/pty-input"],
    ["src/features/plan/approve.tsx", "@/lib/ipc/pty-input"],
    ["src/features/plan/approve.tsx", "../../lib/ipc/pty-input.ts"],
    ["src/features/sessions/list/row.tsx", "@/lib/ipc/pty-input"],
    ["src/app/shell-extra.tsx", "@/lib/ipc/pty-input"],
    ["src/app/shell-extra.tsx", "../lib/ipc/pty-input"],
    ["src/components/common/x.tsx", "@/lib/ipc/pty-input"],
  ];
  it.each(cases)("%s may not import %s", async (file, source) => {
    expect(await errors(file, imp(port, source))).toContain("import-x/no-restricted-paths");
  });

  it("the terminal view may import the port (alias and relative)", async () => {
    const file = "src/features/sessions/terminal/input-gate.tsx";
    expect(await errors(file, imp(port, "@/lib/ipc/pty-input"))).toEqual([]);
    expect(await errors(file, imp(port, "../../../lib/ipc/pty-input"))).toEqual([]);
  });

  it("xterm is blocked outside the terminal view", async () => {
    const code = imp("Terminal", "@xterm/xterm");
    expect(await errors("src/features/lead/x.tsx", code)).toContain("no-restricted-imports");
    expect(await errors("src/features/sessions/list/x.tsx", code)).toContain(
      "no-restricted-imports",
    );
    expect(await errors("src/app/x.tsx", code)).toContain("no-restricted-imports");
    expect(await errors("src/features/sessions/terminal/view.tsx", code)).toEqual([]);
  });
});

describe("rule 9: approval port only in the plan screen", () => {
  const code = (from: string) => imp("useApproval", from);
  it.each([
    ["src/features/lead/x.tsx", "@/lib/ipc/approval"],
    ["src/features/lead/x.tsx", "../../lib/ipc/approval"],
    ["src/app/command-palette-extra.tsx", "@/lib/ipc/approval"],
    ["src/features/review/x.tsx", "@/lib/ipc/approval"],
    ["src/features/sessions/terminal/x.tsx", "@/lib/ipc/approval"],
  ])("%s may not import %s", async (file, from) => {
    expect(await errors(file, code(from))).toContain("import-x/no-restricted-paths");
  });
  it("the plan screen may", async () => {
    expect(await errors("src/features/plan/approve.tsx", code("@/lib/ipc/approval"))).toEqual([]);
    expect(await errors("src/features/plan/approve.tsx", code("../../lib/ipc/approval"))).toEqual(
      [],
    );
  });
  it("the IPC bundle (which carries both ports) stays inside src/lib/ipc", async () => {
    const c = imp("useIpcBundle", "@/lib/ipc/context");
    expect(await errors("src/features/lead/x.tsx", c)).toContain("import-x/no-restricted-paths");
    expect(await errors("src/app/x.tsx", c)).toContain("import-x/no-restricted-paths");
    expect(await errors("src/lib/ipc/extra.ts", c)).toEqual([]);
  });
});

describe("one IPC door, mock never ships, motion through wrappers, independent features", () => {
  it("@tauri-apps/api only in src/lib/ipc", async () => {
    const c = imp("invoke", "@tauri-apps/api/core");
    expect(await errors("src/features/settings/x.tsx", c)).toContain("no-restricted-imports");
    expect(await errors("src/app/x.tsx", c)).toContain("no-restricted-imports");
    expect(await errors("src/lib/ipc/extra.ts", c)).toEqual([]);
    expect(await errors("src/app/x.tsx", imp("x", "@tauri-apps/plugin-shell"))).toContain(
      "no-restricted-imports",
    );
  });

  it("the mock and fixtures only in src/lib/ipc, src/test and tests", async () => {
    const c = imp("createMockIpc", "@/lib/ipc/mock");
    expect(await errors("src/features/usage/x.tsx", c)).toContain("import-x/no-restricted-paths");
    expect(await errors("src/app/x.tsx", imp("p", "../lib/ipc/fixtures/plan.json"))).toContain(
      "import-x/no-restricted-paths",
    );
    expect(await errors("src/features/usage/x.test.tsx", c)).toEqual([]);
    expect(await errors("src/test/extra.tsx", c)).toEqual([]);
  });

  it("motion only in src/components/motion", async () => {
    expect(await errors("src/features/lead/x.tsx", imp("motion", "motion/react"))).toContain(
      "no-restricted-imports",
    );
    expect(await errors("src/features/lead/x.tsx", imp("motion", "motion"))).toContain(
      "no-restricted-imports",
    );
    expect(
      await errors(
        "src/features/lead/x.tsx",
        imp("AnimatedGroup", "@/components/motion-primitives/animated-group"),
      ),
    ).toContain("import-x/no-restricted-paths");
    expect(await errors("src/components/motion/extra.tsx", imp("motion", "motion/react"))).toEqual(
      [],
    );
    expect(await errors("src/features/lead/x.tsx", imp("Stagger", "@/components/motion"))).toEqual(
      [],
    );
  });

  it("features never import each other; routes.tsx imports feature indexes only", async () => {
    expect(await errors("src/features/lead/x.tsx", imp("P", "@/features/plan"))).toContain(
      "import-x/no-restricted-paths",
    );
    expect(await errors("src/features/lead/x.tsx", imp("P", "../plan"))).toContain(
      "import-x/no-restricted-paths",
    );
    expect(await errors("src/app/shell-extra.tsx", imp("P", "@/features/plan"))).toContain(
      "import-x/no-restricted-paths",
    );
    expect(await errors("src/app/routes.tsx", imp("P", "@/features/plan"))).toEqual([]);
    expect(
      await errors("src/app/routes.tsx", imp("SessionTerminal", "@/features/sessions/terminal")),
    ).toContain("import-x/no-restricted-paths");
    expect(
      await errors("src/features/sessions/detail/x.tsx", imp("SessionTerminal", "../terminal")),
    ).toEqual([]);
  });
});

describe("security: untrusted text never becomes HTML", () => {
  const files = ["src/features/review/diff.tsx", "src/components/ui/extra.tsx", "src/lib/x.tsx"];
  it.each(files)("dangerouslySetInnerHTML is an error in %s", async (file) => {
    const code =
      "export const X = ({ t }: { t: string }) => <div dangerouslySetInnerHTML={{ __html: t }} />;\n";
    expect(await errors(file, code)).toContain("react/no-danger");
  });
  it.each([
    ["el.innerHTML = t;", "no-restricted-properties"],
    ["el.outerHTML = t;", "no-restricted-properties"],
    ['el.insertAdjacentHTML("beforeend", t);', "no-restricted-properties"],
    ["document.write(t);", "no-restricted-properties"],
    ['window.open("x");', "no-restricted-properties"],
    ['open("x");', "no-restricted-globals"],
    ["eval(t);", "no-eval"],
    ["new Function(t);", "no-new-func"],
  ])("%s is an error", async (stmt, rule) => {
    const code = `export function f(el: Element, t: string) {\n  ${stmt}\n}\n`;
    expect(await errors("src/features/lead/x.ts", code)).toContain(rule);
    expect(await errors("src/components/motion-primitives/x.ts", code)).toContain(rule);
  });
});
