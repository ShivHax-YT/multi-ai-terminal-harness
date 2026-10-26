// ESLint flat config. Besides style and type checks it enforces two product boundaries:
//
// - Security: untrusted text never becomes HTML (react/no-danger; innerHTML, outerHTML, insertAdjacentHTML,
//   document.write, window.open, eval, new Function are banned everywhere, generated code included).
// - Import zones (docs/tasks/T-101-ipc-contract.md "Boundaries"): rule 3 (PTY input port, xterm), rule 9 (approval
//   port), one IPC door (@tauri-apps/api), the mock never ships, motion only through src/components/motion/, and
//   features never import each other.
//
// A later flat-config object that sets `no-restricted-imports` or `import-x/no-restricted-paths` REPLACES the options
// of an earlier one for the same file, which could silently drop a restriction. So every file belongs to exactly one
// SCOPE below (each scope ignores the files of the scopes before it), and each scope's options are computed from the
// one BOUNDARIES table. src/test/eslint-boundaries.rule3.test.ts lints snippets against this config.
import js from "@eslint/js";
import { createTypeScriptImportResolver } from "eslint-import-resolver-typescript";
import { importX } from "eslint-plugin-import-x";
import jsxA11y from "eslint-plugin-jsx-a11y";
import react from "eslint-plugin-react";
import reactHooks from "eslint-plugin-react-hooks";
import globals from "globals";
import tseslint from "typescript-eslint";

const FEATURES = ["providers", "lead", "plan", "sessions", "review", "usage", "settings", "about"];

/** Mutually exclusive file scopes, first match wins. */
const TS = "**/*.{ts,tsx}";
const SCOPES = [
  { id: "tests", files: [`src/test/${TS}`, "src/**/*.test.{ts,tsx}"] },
  { id: "terminal", files: [`src/features/sessions/terminal/${TS}`] },
  ...FEATURES.map((f) => ({ id: `feature:${f}`, files: [`src/features/${f}/${TS}`] })),
  { id: "ipc", files: [`src/lib/ipc/${TS}`] },
  { id: "motion", files: [`src/components/motion/${TS}`, `src/components/motion-primitives/${TS}`] },
  { id: "routes", files: ["src/app/routes.tsx"] },
  { id: "rest", files: [`src/${TS}`, "*.{ts,js}"] },
];

/**
 * Every boundary: what it guards (module paths for import-x/no-restricted-paths, which resolves both the `@` alias
 * and relative imports; package names for no-restricted-imports) and the scopes allowed to import it.
 */
const BOUNDARIES = [
  {
    id: "pty-input",
    message: "Rule 3: only the terminal view (src/features/sessions/terminal/**) may use the PTY input port.",
    modules: ["./src/lib/ipc/pty-input.ts"],
    allow: ["terminal", "ipc", "tests"],
  },
  {
    id: "xterm",
    message: "Rule 3: xterm.js lives only in src/features/sessions/terminal/**.",
    packages: { patterns: ["@xterm/*"] },
    allow: ["terminal", "tests"],
  },
  {
    id: "approval",
    message: "Rule 9: only the plan screen (src/features/plan/**) may use the approval port.",
    modules: ["./src/lib/ipc/approval.ts"],
    allow: ["feature:plan", "ipc", "tests"],
  },
  {
    id: "ipc-internal",
    message: "Use useIpc() / useIpcEvent() from @/lib/ipc; the bundle and its ports stay inside src/lib/ipc.",
    modules: ["./src/lib/ipc/context.tsx", "./src/lib/ipc/tauri.ts"],
    allow: ["ipc", "tests"],
  },
  {
    id: "tauri-api",
    message: "One IPC door: @tauri-apps/api is used only in src/lib/ipc/**.",
    packages: { names: ["@tauri-apps/api"], patterns: ["@tauri-apps/api/*"] },
    allow: ["ipc"],
  },
  {
    id: "mock",
    message: "The IPC mock and fixtures never ship: import them only in src/lib/ipc/**, src/test/** or tests.",
    modules: ["./src/lib/ipc/mock", "./src/lib/ipc/fixtures"],
    allow: ["ipc", "tests"],
  },
  {
    id: "motion",
    message: "Motion only through the wrappers in src/components/motion/ (they honour reduced motion).",
    modules: ["./src/components/motion-primitives"],
    packages: { names: ["motion", "framer-motion"], patterns: ["motion/*", "framer-motion/*"] },
    allow: ["motion"],
  },
  {
    id: "banned-packages",
    message: "Banned dependency (docs/tasks/T-101.md): no Tauri plugins, theme or HTML/markdown renderers.",
    packages: {
      names: ["next-themes", "diff2html", "marked", "markdown-it", "react-markdown", "dompurify"],
      patterns: ["@tauri-apps/plugin-*", "tauri-plugin-*"],
    },
    allow: [],
  },
];

/** Feature isolation: a feature imports no other feature; routes.tsx imports feature indexes only. */
function featureZones(scopeId) {
  const all = "./src/features";
  if (scopeId === "tests") return [];
  if (scopeId === "routes") {
    return [
      {
        target: ".",
        from: all,
        except: FEATURES.map((f) => `./${f}/index.tsx`),
        message: "routes.tsx may import only each feature's index.tsx.",
      },
    ];
  }
  const own = scopeId === "terminal" ? "sessions" : scopeId.startsWith("feature:") ? scopeId.slice(8) : null;
  return FEATURES.filter((f) => f !== own).map((f) => ({
    target: ".",
    from: `${all}/${f}`,
    message:
      own === null
        ? "Only src/app/routes.tsx imports features."
        : "Features are independent briefs: never import another feature.",
  }));
}

function scopeRules(scopeId) {
  const restricted = BOUNDARIES.filter((b) => !b.allow.includes(scopeId));
  const zones = [
    ...restricted.flatMap((b) =>
      (b.modules ?? []).map((from) => ({ target: ".", from, message: b.message })),
    ),
    ...featureZones(scopeId),
  ];
  const paths = restricted.flatMap((b) =>
    (b.packages?.names ?? []).map((name) => ({ name, message: b.message })),
  );
  const patterns = restricted
    .filter((b) => (b.packages?.patterns ?? []).length > 0)
    .map((b) => ({ group: b.packages.patterns, message: b.message }));
  return {
    "no-restricted-imports": ["error", { paths, patterns }],
    "import-x/no-restricted-paths": ["error", { zones }],
  };
}

const scopeConfigs = SCOPES.map((scope, i) => ({
  name: `harness/boundaries/${scope.id}`,
  files: scope.files,
  ignores: SCOPES.slice(0, i).flatMap((s) => s.files),
  rules: scopeRules(scope.id),
}));

const securityRules = {
  "react/no-danger": "error",
  "no-eval": "error",
  "no-implied-eval": "error",
  "no-new-func": "error",
  "no-restricted-properties": [
    "error",
    { object: "document", property: "write", message: "Never write HTML into the document." },
    { object: "document", property: "writeln", message: "Never write HTML into the document." },
    { object: "window", property: "open", message: "No new windows or external links from the webview." },
    { object: "window", property: "eval", message: "No eval." },
    { object: "globalThis", property: "eval", message: "No eval." },
    { property: "innerHTML", message: "Untrusted text never becomes HTML; render a text node (UntrustedText)." },
    { property: "outerHTML", message: "Untrusted text never becomes HTML; render a text node (UntrustedText)." },
    { property: "insertAdjacentHTML", message: "Untrusted text never becomes HTML." },
  ],
  "no-restricted-globals": [
    "error",
    { name: "open", message: "No window.open." },
    { name: "eval", message: "No eval." },
  ],
  "no-restricted-syntax": [
    "error",
    { selector: "NewExpression[callee.name='Function']", message: "No new Function." },
    {
      selector: "JSXAttribute[name.name='dangerouslySetInnerHTML']",
      message: "Untrusted text never becomes HTML; render a text node (UntrustedText).",
    },
  ],
};

const GENERATED = ["src/components/ui/**", "src/components/motion-primitives/**"];

export default tseslint.config(
  {
    ignores: [
      "dist/**",
      "coverage/**",
      "node_modules/**",
      "src-tauri/**",
      "spike/**",
      "docs/**",
      ".claude/**",
      "examples/**",
    ],
  },
  {
    name: "harness/base",
    files: ["**/*.{ts,tsx,js}"],
    languageOptions: {
      ecmaVersion: 2023,
      sourceType: "module",
      globals: { ...globals.browser, ...globals.node },
    },
    plugins: { react, "import-x": importX },
    settings: {
      react: { version: "19" },
      "import-x/resolver-next": [createTypeScriptImportResolver({ alwaysTryTypes: true })],
    },
    rules: securityRules,
  },
  {
    name: "harness/typescript",
    files: ["**/*.{ts,tsx}"],
    ignores: GENERATED,
    extends: [
      js.configs.recommended,
      ...tseslint.configs.strictTypeChecked,
      react.configs.flat.recommended,
      react.configs.flat["jsx-runtime"],
      reactHooks.configs.flat["recommended-latest"] ?? reactHooks.configs.flat.recommended,
      jsxA11y.flatConfigs.recommended,
    ],
    languageOptions: {
      parserOptions: { projectService: true, tsconfigRootDir: import.meta.dirname },
    },
    rules: {
      ...securityRules,
      "react/prop-types": "off",
      "@typescript-eslint/no-confusing-void-expression": ["error", { ignoreArrowShorthand: true }],
      "@typescript-eslint/restrict-template-expressions": ["error", { allowNumber: false }],
      "@typescript-eslint/no-unused-vars": [
        "error",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_", destructuredArrayIgnorePattern: "^_" },
      ],
      "react-hooks/set-state-in-effect": "off",
    },
  },
  {
    name: "harness/generated",
    files: GENERATED,
    languageOptions: { parser: tseslint.parser },
  },
  {
    name: "harness/tests",
    files: ["src/test/**", "src/**/*.test.ts", "src/**/*.test.tsx"],
    rules: {
      "@typescript-eslint/no-non-null-assertion": "off",
      "@typescript-eslint/require-await": "off",
    },
  },
  ...scopeConfigs,
);
