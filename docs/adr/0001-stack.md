# ADR 0001: App stack (Tauri 2 vs native Swift/SwiftUI)

Status: **Accepted: Tauri 2** (ShivHax-YT, 2026-10-25).
Date: 2026-10-25. Author: lead session (architect role). Decider: ShivHax-YT.

## Context

Phase 1 needs a macOS desktop app that spawns official, unmodified provider CLIs (`claude`, `codex`, later `grok`,
`kimi`, `gemini`), drives them only through headless JSONL or ACP stdio (hard rule 3), shows each session in a
view-only terminal the human can take over, and enforces the 12 hard rules in code with CI tests. It ships notarized
with Developer ID **outside** the Mac App Store, because App Sandbox would also sandbox the child CLIs and break them
(rule 4 notes). Phase 5 adds Windows.

The two options in CLAUDE.md:

- **A. Tauri 2**: Rust core (process spawning, adapters, scheduler, compliance), TypeScript UI in the system webview,
  xterm.js for terminals, `portable-pty` for PTYs.
- **B. Native Swift/SwiftUI**: Swift core and UI, SwiftTerm for terminals and PTYs.

Facts about this machine (checked 2026-10-25): Swift 6.4 and Xcode are installed; Rust/cargo and pnpm are **not**;
Node 24 and npm are. Claude Code 2.1.295 and Codex CLI 0.162.0 are installed.

**Assumption to confirm:** the human works mainly in web/TypeScript front-end (React, Tailwind, shadcn/ui) and has
no Rust or Swift experience. This weighs heavily in "Maintainability" below; if it's wrong, re-read that row.

## Options compared

| Concern | A. Tauri 2 | B. Swift/SwiftUI |
|---|---|---|
| PTY for the view-only terminal | `portable-pty` (from WezTerm): openpty on macOS, ConPTY on Windows. Bytes stream to xterm.js over a `tauri::ipc::Channel`. Mature, but **pin the version**: a macOS build break on 0.9.0 is noted in ARCHITECTURE.md | SwiftTerm: mature terminal emulator plus `LocalProcess` (forkpty). Native rendering, no IPC hop. Its view and process types are coupled, so it needs a wrapper to keep the write side private |
| Headless child processes (JSONL / ACP stdio) | `tokio::process::Command` with piped stdio, `process_group(0)`, `kill_on_drop`; kill the whole group with `killpg`. Line-delimited JSON parsing with `serde_json` is well-trodden | Apple's `swift-subprocess` package or Foundation `Process`. Process groups need `posix_spawn` attributes; `Process` alone can't set them. Swift 6 strict concurrency makes stream plumbing correct but slow to write (expect Sendable fights) |
| Orphan cleanup / signals | Process group per session + `kill_on_drop`; SIGCHLD reaping handled by tokio. On Windows, Job Objects | Process group via posix_spawn; DispatchSource for signals. Manual and easy to get subtly wrong |
| **Rule 3** (scheduler/lead can't reach PTY write) | Strongest option: put PTY spawn/write in its own crate (`pty-view`). `harness-core` (lead, scheduler, adapters) **does not depend on it** in Cargo.toml, so the compiler forbids the import. CI asserts the dep graph with `cargo metadata` + the existing regex scan. The webview reaches PTY write only through one Tauri command, allowed for the main window via a capability file and called only from xterm.js `onData` (keyboard) | Equivalent structure with SwiftPM targets: `HarnessCore` doesn't depend on `PTYView`. Also compiler-enforced. CI assertion via `swift package describe --type json` |
| **Rule 1** compiled ceilings | `pub const` in a `compliance` module; no config type has a field for them | `static let` in a caseless `enum`; same guarantee |
| **Rule 4** file-access layer + denylist | One Rust module owns all non-worktree FS access; denylist embedded at build time (`include_str!` of `compliance/denylist.toml`). The webview gets **no** fs/shell plugin permissions at all | One Swift type owns FS access; denylist bundled as a resource or generated Swift constant |
| **Rule 6** binary verification | `codesign --verify --strict` subprocess or the Security framework via the `security-framework` crate; `sha2` for vendor checksums | Native Security framework (`SecStaticCodeCheckValidity`), CryptoKit for hashes. Slightly cleaner on macOS |
| **Rules 7, 11** API keys in Keychain | `keyring` crate (macOS Keychain now, Windows Credential Manager in Phase 5) | Native Keychain Services. macOS only |
| **Rule 12** signed kill-switch config | Ed25519 verify (`ed25519-dalek` or minisign) against `compliance/killswitch.pub` | CryptoKit `Curve25519.Signing`, no dependency |
| **Rule 5** localhost only | No listening socket by default (custom protocol IPC). Phase 2 MCP server binds `127.0.0.1` explicitly | No socket by default; same for the MCP server |
| **Rule 8** branding | `productName` / `identifier` in `tauri.conf.json` (already scanned) | `CFBundleName` / identifier in `Info.plist` (already scanned) |
| Signing, notarization, outside App Store | Tauri bundler signs with hardened runtime and notarizes from env vars (signing identity + App Store Connect API key). No App Sandbox entitlement | Xcode archive → Developer ID → `notarytool`. The most native, best-documented path |
| Auto-update | `tauri-plugin-updater` with its own signed update manifests | Sparkle 2 with EdDSA-signed appcasts. Very mature |
| Windows (Phase 5) | Same Rust core and TS UI. Needed changes: ConPTY (already in `portable-pty`), Job Objects, Windows credential paths in the denylist, WebView2 | **A second app.** SwiftUI doesn't run on Windows; the UI and most platform code get rewritten |
| Webview security surface | Agent output is untrusted. Render terminal output only through xterm.js, never as HTML; strict CSP; no remote content | No webview, smaller surface |
| Binary size | Small (system webview) | Small |
| Toolchain on this Mac today | Must install rustup and pnpm first (`brew install` / `corepack enable` asks permission) | Ready now: Swift 6.4 + Xcode installed |
| Maintainability by the human (assumption above) | UI in React/TypeScript is home turf. The Rust core is new, but it's where the compliance logic lives and where reviewers and the `compliance-auditor` focus. Two languages and an IPC boundary to learn | Whole app in an unfamiliar language and IDE. SwiftUI state and Swift 6 concurrency have a steep curve; the human would depend on agents for every change |
| Agent build loop | `cargo` / `pnpm` CLIs; Context7 for docs | `swift build`, `xcodebuild`; MobileBuildMCP (`examples/mcp.swift-path.json`), not run-tested |

## Recommendation

**Tauri 2**, for three reasons:

1. **Windows is in the plan.** Tauri carries the core and UI to Windows in Phase 5; Swift means building a second app.
2. **It fits the assumed skill set.** The UI is React/TypeScript, which the human already works in. The rule-critical
   core sits in a separate Rust crate that reviewers and the compliance-auditor focus on.
3. **Every hard rule has a clean enforcement point**, and rule 3 is the strongest of all: a Cargo dependency edge that
   doesn't exist can't be imported. `keyring` covers Keychain now and Credential Manager later.

**Choose Swift instead if** the app will stay macOS-only, the human is (or will become) Swift-first, or a fully
native feel and zero-FFI access to Security/CryptoKit matter more than the Windows port. Swift also needs no toolchain
setup on this machine.

## Decision

**Accepted: Tauri 2**, chosen by ShivHax-YT on 2026-10-25, for the reasons in the Recommendation above.

- Layout for Phase 1: a Cargo workspace under `src-tauri/` with crates `harness-core` (lead, scheduler, adapters,
  compliance constants, file-access layer), `pty-view` (PTY spawn and write) and `app` (Tauri shell). The UI lives in
  `src/` (TypeScript, strict mode).
- `harness-core` must never depend on `pty-view` (rule 3). CI checks this.
- The language-skills assumption in Context hasn't been confirmed. It affects how much review the Rust core needs,
  not the choice.
- The Swift-specific follow-ups below no longer apply. The Tauri ones land with the Phase 1 scaffold: unconditional
  cargo/pnpm checks in the Makefile and CI would fail until `src-tauri/` and `package.json` exist.

## Consequences and follow-up edits once decided

Both options:
- `CLAUDE.md`: replace the "Stack decision" TODO block with the decision (the SessionStart hook keys off the
  `TODO (HUMAN MUST CHOOSE` string, so it must be gone).
- `docs/ARCHITECTURE.md`: replace the Stack TODO.
- `Makefile`: delete the other stack's branch in `stack-fast` / `stack-full` and make the checks unconditional.
- `.github/workflows/ci.yml`: replace the `stack` job steps with the chosen block; pin action SHAs before release.
- `compliance/pty-boundary.conf`: real PTY write symbols and scheduler/lead paths (below).
- A product name and bundle ID containing no provider trademark (rule 8). This is a separate human decision and is
  needed before Phase 1 scaffolding.

If **Tauri 2**:
- Install rustup (stable, `rustfmt` + `clippy`) and pnpm. Layout: Cargo workspace under `src-tauri/` with crates
  `harness-core`, `pty-view`, `app`; UI in `src/`.
- `package.json` must define `typecheck`, `lint` and `test` scripts (the Makefile greps for them).
- `pty-boundary.conf`: `PTY_DIRS_RE` covering `harness-core`, `scheduler`, `lead`; add a CI step asserting
  `harness-core` has no dependency path to `pty-view`.
- Pin `portable-pty` to a version verified to build on macOS in a Phase 1 spike; avoid 0.9.0 until the break is
  confirmed fixed.
- Tauri capabilities: the main window may call only the app's own commands. No `fs`, `shell` or `http` plugin
  permissions for the webview.

If **Swift/SwiftUI**:
- Layout: `Package.swift` with targets `HarnessCore`, `PTYView`, `App`; sources in `Sources/`, tests in `Tests/`
  (the Makefile lints those paths). Install SwiftLint (`brew install swiftlint`).
- `pty-boundary.conf`: the scan's path regex is case-sensitive and lowercase today. Change it to
  `(^|/)([Ss]cheduler|[Ll]ead|[Oo]rchestrator|HarnessCore)(/|\.)` and set the SwiftTerm write symbols
  (`send(` on the terminal view / `LocalProcess.send`).
- Merge `examples/mcp.swift-path.json` into `.mcp.json` for MobileBuildMCP.
- Sparkle 2 for updates; notarize with `notarytool`.

## Hard rules affected

All twelve depend on the stack for their enforcement point (table above). Rule 3 (dependency boundary), rule 4
(file-access layer) and rule 6 (binary verification) are the ones whose CI tests change shape with the choice.
