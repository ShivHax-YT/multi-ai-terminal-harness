// The app runs with Object.prototype frozen (tauri.conf.json), where assigning an inherited name on a plain object
// throws. jsdom tests stand in for xterm, so this checks the real bundle: the crash only showed up in the native app.
import { describe, expect, it } from "vitest";

import { readRepo } from "@/test/repo";

import { patchXterm } from "../../../../vite.xterm-frozen-prototype";

const OBJECT_PROTOTYPE_ASSIGNMENT =
  /[\w$)\]]\.(toString|valueOf|constructor|hasOwnProperty|isPrototypeOf|propertyIsEnumerable|toLocaleString)=[^=]/;

describe("xterm under a frozen Object.prototype", () => {
  it("the patched bundle assigns no inherited Object.prototype name", () => {
    const source = readRepo("node_modules/@xterm/xterm/lib/xterm.mjs");
    expect(source).toMatch(OBJECT_PROTOTYPE_ASSIGNMENT);
    expect(patchXterm(source)).not.toMatch(OBJECT_PROTOTYPE_ASSIGNMENT);
  });

  it("the build fails loudly if xterm changes", () => {
    expect(() => patchXterm("something else entirely")).toThrow(/xterm changed/);
  });

  it("freezePrototype stays on", () => {
    const config = JSON.parse(readRepo("src-tauri/tauri.conf.json")) as {
      app: { security: { freezePrototype: boolean } };
    };
    expect(config.app.security.freezePrototype).toBe(true);
  });
});
