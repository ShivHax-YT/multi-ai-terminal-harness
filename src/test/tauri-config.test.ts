// Tauri config guards: rule 5 (localhost only, strict CSP), rule 4 (no fs/shell/http for the webview), rule 6 (no
// bundled binaries or resources, no plugins), rule 8 (trademark-free name and id), and the security basics.
import { describe, expect, it } from "vitest";

import { readJson, readRepo } from "./repo";

interface TauriConf {
  productName: string;
  identifier: string;
  build: { devUrl: string; frontendDist: string };
  app: {
    withGlobalTauri: boolean;
    windows: {
      label: string;
      title: string;
      dragDropEnabled: boolean;
      minWidth: number;
      minHeight: number;
    }[];
    security: { csp: string; devCsp: string; freezePrototype: boolean; capabilities: string[] };
  };
  bundle: Record<string, unknown>;
  plugins?: Record<string, unknown>;
}

const conf = readJson("src-tauri/tauri.conf.json") as TauriConf;

function directives(csp: string): Map<string, string[]> {
  const out = new Map<string, string[]>();
  for (const part of csp.split(";")) {
    const [name, ...values] = part.trim().split(/\s+/);
    if (name !== undefined && name !== "") out.set(name, values);
  }
  return out;
}

const LOCAL_SOURCE =
  /^('self'|'none'|'unsafe-inline'|data:|ipc:|http:\/\/ipc\.localhost|(ws|http):\/\/127\.0\.0\.1:1420)$/;

describe("rule 5: localhost only, no remote content", () => {
  it("the production CSP is exactly the brief's and names no remote origin", () => {
    expect(conf.app.security.csp).toBe(
      "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src ipc: http://ipc.localhost; object-src 'none'; base-uri 'none'; frame-src 'none'; form-action 'none'",
    );
    for (const values of directives(conf.app.security.csp).values()) {
      for (const v of values) {
        expect(v).toMatch(LOCAL_SOURCE);
        expect(v).not.toMatch(/127\.0\.0\.1/);
      }
    }
  });

  it("devCsp only adds the Vite dev server on 127.0.0.1:1420", () => {
    const prod = directives(conf.app.security.csp);
    const dev = directives(conf.app.security.devCsp);
    expect([...dev.keys()].sort()).toEqual([...prod.keys()].sort());
    for (const [name, values] of dev) {
      const extra = values.filter((v) => !(prod.get(name) ?? []).includes(v));
      for (const v of extra) expect(v).toMatch(/^(ws|http):\/\/127\.0\.0\.1:1420$/);
      for (const v of values) expect(v).toMatch(LOCAL_SOURCE);
    }
  });

  it("devUrl and the Vite server bind to 127.0.0.1:1420 (strict port)", () => {
    expect(conf.build.devUrl).toBe("http://127.0.0.1:1420");
    const vite = readRepo("vite.config.ts");
    for (const block of ["server", "preview"]) {
      const body = new RegExp(`\\n  ${block}: \\{([\\s\\S]*?)\\n  \\},`).exec(vite)?.[1] ?? "";
      expect(body).toMatch(/\n {4}host: "127\.0\.0\.1",/);
      expect(body).toMatch(/\n {4}port: 1420,/);
      expect(body).toMatch(/\n {4}strictPort: true,/);
    }
    expect(vite).not.toMatch(/0\.0\.0\.0|host: true|--host/);
  });

  it("no remote URL is loaded by the window and there is no global Tauri object", () => {
    expect(conf.build.frontendDist).toBe("../dist");
    expect(conf.app.withGlobalTauri).toBe(false);
    expect(conf.app.security.freezePrototype).toBe(true);
    expect(JSON.stringify(conf.app.windows)).not.toMatch(/"url"/);
  });
});

describe("rule 4: no fs, shell or http access for the webview", () => {
  it("only the main capability exists and it grants core:default plus app commands", () => {
    expect(conf.app.security.capabilities).toEqual(["main"]);
    const cap = readJson("src-tauri/capabilities/main.json") as {
      windows: string[];
      permissions: unknown[];
      remote?: unknown;
    };
    expect(cap.windows).toEqual(["main"]);
    expect(cap.remote).toBeUndefined();
    for (const p of cap.permissions) {
      expect(typeof p).toBe("string");
      expect(p).toMatch(/^(core:default|allow-[a-z-]+)$/);
    }
  });
});

describe("rule 6: no bundled CLIs, resources or plugins", () => {
  it("tauri.conf.json has no externalBin, resources or plugin config", () => {
    expect(conf.bundle.externalBin).toBeUndefined();
    expect(conf.bundle.resources).toBeUndefined();
    expect(conf.plugins ?? {}).toEqual({});
  });

  it("no Tauri plugin crates in any Cargo.toml", () => {
    for (const f of [
      "src-tauri/Cargo.toml",
      "src-tauri/crates/harness-core/Cargo.toml",
      "src-tauri/crates/pty-view/Cargo.toml",
    ]) {
      expect(readRepo(f)).not.toMatch(/tauri-plugin/);
    }
  });

  it("package.json has no banned dependency", () => {
    const pkg = readJson("package.json") as {
      dependencies: Record<string, string>;
      devDependencies: Record<string, string>;
    };
    const names = [...Object.keys(pkg.dependencies), ...Object.keys(pkg.devDependencies)];
    const banned =
      /^(@tauri-apps\/plugin-|tauri-plugin-|framer-motion$|next-themes$|diff2html$|marked$|markdown-it$|react-markdown$|dompurify$|html-react-parser$|@anthropic-ai\/|@openai\/|openai$|@google\/|@google-ai\/)/;
    for (const name of names) expect(name).not.toMatch(banned);
  });
});

describe("rule 8: trademark-free name and bundle id", () => {
  it("is Harness / dev.local.harness", () => {
    expect(conf.productName).toBe("Harness");
    expect(conf.identifier).toBe("dev.local.harness");
    expect(conf.app.windows[0]?.title).toBe("Harness");
  });

  it("the main window matches the brief", () => {
    const w = conf.app.windows[0];
    expect(w?.label).toBe("main");
    expect(w?.dragDropEnabled).toBe(false);
    expect(w?.minWidth).toBe(1024);
    expect(w?.minHeight).toBe(700);
  });
});
