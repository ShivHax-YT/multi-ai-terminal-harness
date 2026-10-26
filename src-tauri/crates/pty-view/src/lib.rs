//! PTY view crate (hard rule 3).
//!
//! Spawns interactive CLI sessions for the human to watch and take over. Its write path is reachable only from the
//! app shell's `pty_write` command, which the UI calls from keyboard events in the terminal view. The core crate
//! (lead, scheduler, adapters) has no dependency on this crate, so the compiler forbids automation from reaching it.
//!
//! Empty for now: `portable-pty` (pinned; avoid 0.9.0 on macOS) arrives with the session brief.
