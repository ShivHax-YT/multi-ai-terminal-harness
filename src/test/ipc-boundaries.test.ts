// Grep layer of the IPC boundaries (the ESLint zones are the other layer): the PTY write path (rule 3) and the
// approval path (rule 9) are named only in their allowed files, and `invoke` / @tauri-apps/api only in src/lib/ipc.
import { describe, expect, it } from "vitest";

import { isTestFile, listFiles, readRepo } from "./repo";

const sources = listFiles("src").filter((f) => /\.(ts|tsx)$/.test(f) && !isTestFile(f));

function filesMatching(re: RegExp): string[] {
  return sources.filter((f) => re.test(readRepo(f)));
}

describe("rule 3: the PTY write path", () => {
  it("pty_write / ptyWrite / pty-input appear only in the contract, the transports, the port and the terminal", () => {
    const allowed = (f: string) =>
      f === "src/lib/ipc/contract.ts" ||
      f === "src/lib/ipc/tauri.ts" ||
      f === "src/lib/ipc/pty-input.ts" ||
      f.startsWith("src/lib/ipc/mock/") ||
      f.startsWith("src/features/sessions/terminal/");
    const hits = filesMatching(/pty_write|ptyWrite|pty-input|writeToPty|write_to_pty/);
    expect(hits.filter((f) => !allowed(f))).toEqual([]);
    expect(hits).toContain("src/lib/ipc/tauri.ts");
  });

  it("usePtyInput is called only from the terminal view", () => {
    const hits = filesMatching(/usePtyInput\s*\(/).filter((f) => f !== "src/lib/ipc/pty-input.ts");
    expect(hits.filter((f) => !f.startsWith("src/features/sessions/terminal/"))).toEqual([]);
  });

  it("the general client type has no pty_write", () => {
    const contract = readRepo("src/lib/ipc/contract.ts");
    const client = /export interface IpcClient \{([\s\S]*?)\n\}/.exec(contract)?.[1] ?? "";
    expect(client).not.toBe("");
    expect(client).not.toMatch(/pty_write|approve_plan|invoke/);
  });
});

describe("rule 9: the approval path", () => {
  it("approve_plan appears only in the contract, the transports, the port and the plan screen", () => {
    const allowed = (f: string) =>
      f === "src/lib/ipc/contract.ts" ||
      f === "src/lib/ipc/tauri.ts" ||
      f === "src/lib/ipc/approval.ts" ||
      f.startsWith("src/lib/ipc/mock/") ||
      f.startsWith("src/features/plan/");
    const hits = filesMatching(/approve_plan|approvePlan/);
    expect(hits.filter((f) => !allowed(f))).toEqual([]);
  });

  it("useApproval is called only from the plan screen", () => {
    const hits = filesMatching(/useApproval\s*\(/).filter((f) => f !== "src/lib/ipc/approval.ts");
    expect(hits.filter((f) => !f.startsWith("src/features/plan/"))).toEqual([]);
  });

  it("the command palette never names an acting command", () => {
    const palette = readRepo("src/app/command-palette.tsx");
    const code = palette.replace(/\/\/.*$/gm, "");
    expect(code).not.toMatch(
      /\b(approve\w*|kill\w*|take.?over|pty\w*|resume\w*|pause\w*|reset\w*)\b/i,
    );
  });
});

describe("one IPC door", () => {
  it("invoke() and @tauri-apps/api appear only in src/lib/ipc", () => {
    const hits = filesMatching(/@tauri-apps\/api|\binvoke\s*[<(]/);
    expect(hits.filter((f) => !f.startsWith("src/lib/ipc/"))).toEqual([]);
    expect(hits).toContain("src/lib/ipc/tauri.ts");
  });

  it("the IPC bundle accessor (ports included) is used only in src/lib/ipc", () => {
    const hits = filesMatching(/useIpcBundle/);
    expect(hits.filter((f) => !f.startsWith("src/lib/ipc/"))).toEqual([]);
  });

  it("production client selection never loads the mock outside the dev branch", () => {
    const index = readRepo("src/lib/ipc/index.ts");
    expect(index).toMatch(
      /if \(import\.meta\.env\.DEV && import\.meta\.env\.VITE_HARNESS_IPC !== "tauri"\) \{\s*const \{ createDevMockIpc \} = await import\("\.\/mock"\);/,
    );
    expect(index).not.toMatch(/^import[^\n]*\.\/mock/m);
    const nonIpc = sources.filter((f) => !f.startsWith("src/lib/ipc/"));
    const specifier = /(from\s+|import\(\s*)["'][^"']*lib\/ipc\/(mock|fixtures)/;
    for (const f of nonIpc) expect(readRepo(f)).not.toMatch(specifier);
  });
});
