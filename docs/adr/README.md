# Architecture decision records

One file per decision: `NNNN-short-title.md` with Context, Decision, Consequences, Hard rules affected.

**First ADR required before any app code:** `0001-stack.md`, choosing Tauri 2 (Rust + web UI) or native Swift/SwiftUI.
See CLAUDE.md "Stack decision". After it lands, update `compliance/pty-boundary.conf`, the Makefile stack targets
and `.github/workflows/ci.yml`.
