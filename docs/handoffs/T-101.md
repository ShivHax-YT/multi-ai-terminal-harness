# HANDOFF T-101

## Summary
Finished the T-101 scaffold on top of part A (4398946) and the part B WIP (04c20dc): Tauri 2 workspace with 33 contract stubs, Harness tokens, typed IPC contract with a Tauri client, two port modules and a stateful mock, app shell with route registry and screen placeholders, motion wrappers, shared composites and provider strings.
Guards for rules 3, 5, 8 and 9 come in three layers: the Cargo graph and the scan conf, the Tauri capability and AppManifest, and ESLint import zones built from one table, plus grep tests. Each layer is tested.
Fixed the vendored shadcn/Motion Primitives code for strict TS. Sonner no longer uses next-themes. Destructive button and badge use tokens. Fixture worktree paths are now neutral (.harness/worktrees).
Every check in make check-fast and make check passes, and so does the production build. The IPC mock does not reach dist/.

## Files changed
- eslint.config.js - new: strictTypeChecked, react, hooks, jsx-a11y, security bans, scoped import zones from one BOUNDARIES table
- src/main.tsx - entry: fontsource imports, loadIpc, App
- src/vite-env.d.ts - VITE_HARNESS_IPC and VITE_HARNESS_MOCK_SCENARIO types
- src/app/app.tsx - hash router plus providers
- src/app/providers.tsx - QueryClient (no retry, no refetch), IPC, theme, MotionConfig, tooltip, toaster
- src/app/shell.tsx - sidebar nav landmark, header (title, Cmd+K button, theme menu), Cmd+1..7, no route animation
- src/app/command-palette.tsx - navigation and theme only
- src/app/theme.tsx - light/dark/system, localStorage, .dark on html
- src/app/theme-menu.tsx - header theme dropdown
- src/app/nav.ts - one nav list for sidebar, titles, shortcuts and palette
- src/app/paths.ts - typed route helpers and patterns
- src/app/routes.tsx - lazy feature indexes
- src/app/shell.test.tsx - shell, shortcuts, palette (rule 9), theme
- src/lib/ipc/tauri.ts - Tauri transport (only invoke caller)
- src/lib/ipc/context.tsx - IpcProvider, useIpc, useIpcEvent, internal useIpcBundle
- src/lib/ipc/approval.ts - ApprovalPort hook (rule 9)
- src/lib/ipc/pty-input.ts - PtyInputPort hook (rule 3)
- src/lib/ipc/index.ts - client selection, mock by dynamic import on the dev path only
- src/lib/ipc/contract.ts - lint fix (compile-time self-check export)
- src/lib/ipc/mock/index.ts - createMockIpc, control, sentinel, dev realtime mock
- src/lib/ipc/mock/backend.ts - lint fixes, isAuthMode, neutral worktree paths
- src/lib/ipc/mock/plan.ts - formatting only
- src/lib/ipc/mock/mock.test.ts - scenarios, mirrored refusals, ajv schema validation
- src/lib/ipc/fixtures/review.json - neutral worktree paths
- src/lib/ipc/fixtures/review-injection.json - neutral worktree paths
- src/lib/time.ts - useNow, msUntil, formatCountdown
- src/lib/format.ts - USD, minutes, tokens
- src/lib/lib.test.ts - time, format, base64, paths
- src/lib/hooks/use-mobile.ts - lint fix
- src/components/motion/index.tsx - Stagger, Shimmer (opacity pulse), Reveal, PanelSwitch, MotionRoot
- src/components/motion/reduced-motion.ts - live prefers-reduced-motion hook
- src/components/motion/motion.test.tsx - reduced motion renders static; timing and property limits
- src/components/motion-primitives/animated-group.tsx - strict TS, transform/opacity presets only
- src/components/motion-primitives/in-view.tsx - strict TS
- src/components/motion-primitives/text-shimmer.tsx - strict TS, token colors (unused until human OK)
- src/components/motion-primitives/transition-panel.tsx - strict TS
- src/components/common - ProviderName, UntrustedText, EmptyState, ErrorAlert, LoadingSkeleton, Countdown, Meter, CopyButton, index, tests
- src/components/ui/sonner.tsx - theme from the Harness provider (no next-themes)
- src/components/ui/button.tsx - destructive variant uses tokens
- src/components/ui/badge.tsx - destructive variant uses tokens
- src/components/ui - prettier formatting of the generated components
- src/features/providers/index.tsx - placeholder (T-102)
- src/features/lead/index.tsx - placeholder (T-103)
- src/features/plan/index.tsx - placeholder (T-104)
- src/features/sessions/index.tsx - placeholder (T-105)
- src/features/sessions/terminal/index.tsx - placeholder SessionTerminal(props: {sessionId, kind}) (T-106)
- src/features/review/index.tsx - placeholder (T-107)
- src/features/usage/index.tsx - placeholder (T-108)
- src/features/settings/index.tsx - placeholder (T-109)
- src/features/about/index.tsx - name, version, placeholder note, notAffiliatedStatement
- src/features/about/about.test.tsx - About (rule 8)
- src/strings/providers.rule8.test.ts - names only in providers.ts; fixtures as exact JSON ids
- src/styles/tokens.test.ts - tokens.md = globals.css, contrast recomputed, banned hues
- src/test/setup.ts - jest-dom, cleanup, matchMedia and observer stubs, setReducedMotion
- src/test/render.tsx - renderRoute(path, { mock })
- src/test/repo.ts - read-only repo file helpers for guard tests
- src/test/eslint-boundaries.rule3.test.ts - lints snippets against eslint.config.js (alias and relative)
- src/test/ipc-boundaries.test.ts - grep layer for pty_write, approve_plan, invoke
- src/test/command-parity.test.ts - contract = generate_handler = build.rs = capability = commands.rs
- src/test/tauri-config.test.ts - rules 4, 5, 6, 8 config checks
- src/test/no-remote.rule5.test.ts - no remote URLs, bundled fonts
- HANDOFF.md - this file

## Tests run
pnpm install --frozen-lockfile - ok (Node 22.22.0; one engine warning, see risks)
pnpm -s typecheck - PASS
pnpm -s lint - PASS (0 warnings)
pnpm -s test - PASS, 13 files, 138 tests
pnpm -s format:check - PASS
pnpm -s build - PASS; grep for __HARNESS_MOCK__ in dist finds nothing
cargo fmt --all -- --check - PASS
cargo clippy --workspace --all-targets -- -D warnings - PASS
cargo test --workspace - PASS (app 8, harness-core 12)
scripts/ci/compliance-scan.sh - clean
scripts/ci/check-crate-boundary.sh - pass
tests/compliance/selftest.sh - 43 passed, 0 failed
make -s check-fast - PASS
make -s check - PASS
jq productName/identifier acceptance check - true
pnpm tauri build --debug --no-bundle - PASS (built src-tauri/target/debug/app; webkit2gtk-4.1 2.52)

## Hard rules touched
- 1 - cargo test -p harness-core ceilings (one test per value); cargo test -p app limits_match_fixture; mock.test.ts limits and settings refusals
- 3 - make crate-boundary; selftest R3 cases; src/test/eslint-boundaries.rule3.test.ts; src/test/ipc-boundaries.test.ts; cargo test pty_write_refuses_with_rule_3; mock.test.ts pty_write without take-over
- 4, 6 - src/test/tauri-config.test.ts rule 4 / rule 6 (capability = core:default + app commands; no plugins, externalBin or resources)
- 5 - src/test/tauri-config.test.ts rule 5 (CSP, devCsp, 127.0.0.1:1420); src/test/no-remote.rule5.test.ts
- 7 - mock.test.ts: login for the API-key-only provider is rule_blocked 7
- 8 - src/strings/providers.rule8.test.ts; src/features/about/about.test.tsx; src/styles/tokens.test.ts banned hues; compliance scan
- 9 - src/test/ipc-boundaries.test.ts; src/app/shell.test.tsx palette; cargo test stub_never_approves; mock.test.ts hash and violation refusals
- 10, 11, 12 - mock.test.ts backoff and pause, spend-cap validation, kill-switch scenario
- Security - eslint snippet tests (dangerouslySetInnerHTML, innerHTML, eval, window.open); common.test.tsx UntrustedText; make check dist sentinel

## Open risks / questions
Node: only Node 22 is installed, and engines.node stays ">=24" as the brief asks. pnpm prints an engine warning but does not block. CI uses Node 24.
Text Shimmer animates background-position, so it needs the human's OK. Until then Shimmer is an opacity pulse and text-shimmer.tsx is vendored but unused.
The ESLint guard tests turn type-aware parsing off for the virtual snippet files. Only the boundary and security rules run on them.
Tests are exempt from the import zones (tests scope) so screen tests can use the mock and ports.
Spend-cap max (500/2000 USD) is still a placeholder for the human to set.
pnpm tauri dev is a human check (Cmd+K, Cmd+1..7, theme menu, About). This headless machine cannot run it.

## Confidence
high, every check in make check passes and each hard-rule guard has a negative test that would fail if the boundary broke.
