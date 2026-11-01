// Tauri's freezePrototype hardening (tauri.conf.json) freezes Object.prototype, so a plain `namespace.toString = fn`
// throws at module load. xterm has exactly one such assignment. Rewrite only that line, and fail the build if it moves,
// rather than turn the hardening off.
const KEYCODE_UTILS_ASSIGNMENT =
  /(\w+)\.toString=(\w+)(?=;function \w+\(\w+\)\{return \w+\.strToKeyCode)/;

export function patchXterm(source: string): string {
  if (!KEYCODE_UTILS_ASSIGNMENT.test(source)) {
    throw new Error("xterm changed: re-check its assignments to Object.prototype names.");
  }
  return source.replace(
    KEYCODE_UTILS_ASSIGNMENT,
    'Object.defineProperty($1,"toString",{value:$2,writable:true,configurable:true,enumerable:true})',
  );
}

export function xtermFrozenPrototype() {
  return {
    name: "xterm-frozen-prototype",
    enforce: "pre" as const,
    transform(source: string, id: string) {
      return id.includes("@xterm/xterm/lib/xterm.mjs")
        ? { code: patchXterm(source), map: null }
        : null;
    },
  };
}
