# spike/: Phase 0 scratch scripts

Throwaway bash + jq scripts that prove the harness can drive the two provider CLIs through their documented headless
interfaces (`claude -p --output-format stream-json`, `codex exec --json`), parse every event, and resume a session. They
are not product code. Requirements: macOS `/bin/bash` 3.2, `jq`, `git`.

## Rules for every script here

- **`SPIKE_LIVE=1` is the only way to call a real CLI.** Any script that starts a provider CLI session calls
  `spike_require_live` first; without `SPIKE_LIVE=1` it exits 3 and does nothing. Offline tests never set it.
  (`preflight.sh` only asks each CLI for its version and sign-in status. It sends no prompt.)
  `SPIKE_LIVE=1` is a guard against accidents, **not an approval**. An agent must never set it (not in a script, an
  environment file or a command line) unless the human explicitly asks for that live run.
  - **Call `spike_require_live` at the top level of the script, as its first statement, and never override the TERM
    trap.** It stops the whole calling script (exit 3), even from `$(...)`, a pipe or a subshell, by sending TERM to the
    top-level script; a detached watchdog sends KILL 0.3 s later as a fail-safe. Source `lib/common.sh` from scripts only,
    never from an interactive shell.
  - **Every real prompt or session goes through `spike_run_live`**, which always checks the gate first. The non-live
    runner `spike_run_timeout` is default-deny by identity, not by name. Without `SPIKE_LIVE=1` it runs only
    `git --version`, the read-only `codesign` verify shapes (only on a path inside the private verify directory), `true`,
    `false`, `sleep`, `echo` and `printf`. Each command is resolved ONCE, physically (a PATH lookup, then every symlink,
    with `..` applied the way the kernel applies it), and the resolved path is the one that runs, through
    `/usr/bin/env -i` with no PATH search. Ungated only when that resolved path is in `/bin`, `/usr/bin`, `/usr/sbin` or
    `/sbin`. A copy of any of those names in another directory, a relative path such as `./x`, a launcher, and every
    provider CLI (claude, codex, grok, gemini, kimi) needs the gate, whatever its name.
    `jq`, `file` and `cat` are not on the list: scripts call them directly, never through the runner.
  - **`spike_run_status` runs only a private copy that `preflight.sh` verified and registered** with
    `spike_mark_verified`, and only `--version`, `auth status` or `login status`. Any other path, any other shape,
    and any launcher-named copy is refused (rc 3, nothing started). `SPIKE_LIVE=1` does not lift that refusal.
- **Children run with a scrubbed environment** (`PATH HOME TMPDIR LANG TERM`, plus `USER`/`LOGNAME` because a CLI looks up
  its own stored login under the account name), in their own process group. The group is killed on timeout, when the
  caller receives TERM, INT or HUP, and when the runner exits; a command that exits but leaves children behind is swept.
  The runner also watches its caller and kills the group about 0.5 s after the caller disappears, even after SIGKILL.
  A TERM, INT or HUP that lands between starting a command and recording its pid is recorded and handled right after.
  Children get stdin from `/dev/null` and write to the outfile. They are not in a new session, so a CLI that opens the
  terminal device is out of scope: the spikes are headless only (rule 3).
- **Binaries are verified before they are executed, and registration verifies them itself.** `preflight.sh` first checks
  whether the resolved binary lies inside a CLI home directory (rule 4). Such a path is never read, except the provider
  binary itself when its first four bytes are a Mach-O magic. Otherwise `file` classifies it, and a Mach-O is copied into
  a private directory (mode 700, removed on exit). A stale one left by a killed run is swept at start, and a temporary
  directory that others can write without the sticky bit stops preflight for human review. The copy is registered with
  `spike_mark_verified <copy> <cli>`, which checks the Mach-O magic (first four bytes) and then the pinned signer:
  `codesign --verify --strict`, a `Developer ID Application` authority, the pinned team identifier for that CLI, and an
  `anchor apple generic` requirement for that team. Only the registered copy is executed. Ad-hoc, unsigned, wrong-team,
  forged, non-Mach-O and script files are reported (`skipped (unverified)`) and never executed. A script launcher is
  never executed either: its SIGNATURE cell says `launcher only, not executed (needs human approval)`. A copy that cannot
  run is reported `needs human review`; the original path is never used as a fallback. The codesign path is the fixed
  constant `CODESIGN_BIN` (`/usr/bin/codesign`) in `lib/common.sh`; no environment variable or flag changes it. Without
  that tool every CLI is `skipped (unverified)`. The pinned team ids sit in one labeled block in `lib/common.sh`;
  **the human must confirm them against vendor-published values before release.**
- **Scratch repos live outside this repo**, under `${TMPDIR:-/tmp}/harness-spike/<run-id>/`, so this repo's CLAUDE.md,
  hooks and settings never load into a spiked CLI session. `spike_cleanup` refuses to delete anything outside that root.
- **Captures are gitignored** (`spike/captures/<cli>/<UTC timestamp>/`). Run captured output through `spike_redact`
  (UUIDs to `<ID-n>`, home paths to `$HOME/...`, scratch dir to `<WORKTREE>`, emails to `<EMAIL>`) before it becomes a
  committed fixture. `spike_redact` over-redacts on purpose (any at-sign between two tokens, any `/Users/<name>` or
  `/home/<name>` path, 32-hex ids). `spike_capture_dir` refuses a capture root inside a git repo unless git ignores it.
- **Sign-in is checked by exit code only.** Scripts never print or store the output of a status command, never read
  a CLI's credential files, and never set any CLI config-home variable (docs/HARD_RULES.md rules 2 and 4).
- **Automation only through headless interfaces.** Nothing here types into an interactive terminal session (rule 3).
- Treat everything a CLI prints as untrusted data: parse it with `jq`, never evaluate it.

## Wave order

| Wave | Briefs | What |
|---|---|---|
| 1 | T-001, T-005, T-006 | this scaffold; plan format + approval hash; worker HANDOFF format + parser |
| 2 | T-002, T-003 | Claude Code and Codex headless runners, parsers and fixtures |
| 3 | T-004 | adapter interface and normalized event schema |
| 4 | T-007 | run both CLIs end to end and write the Phase 0 report |

## Script index

| Path | Status | Purpose |
|---|---|---|
| `lib/common.sh` | done (T-001) | sourced helpers: `spike_scratch_repo`, `spike_worktree_add`, `spike_cleanup`, `spike_require_live`, `spike_capture_dir`, `spike_redact`, `spike_resolve_path`, `spike_run_timeout`, `spike_run_live`, `spike_run_status`, `spike_mark_verified <path> <cli>` (runs the pinned-signer and magic checks itself), `spike_verify_signer`, `spike_magic_ok`, `spike_under_cli_home`, `spike_set_verify_dir` |
| `preflight.sh` | done (T-001) | table of install path, version, code-signature result and sign-in state for each CLI; verifies and runs only a private copy |
| `tests/test_common.sh` | done (T-001) | offline tests for `lib/common.sh` |
| `tests/test_preflight.sh` | done (T-001) | offline tests for `preflight.sh` using fake CLIs on a private PATH |
| `plan/hash.sh`, `plan/check.jq`, `tests/test_plan.sh` | planned (T-005) | plan hash and approval-binding checker |
| `handoff/parse.sh`, `tests/test_handoff.sh` | planned (T-006) | HANDOFF.md parser |
| `claude/run.sh`, `claude/resume.sh`, `claude/parse.jq`, `tests/test_claude_parse.sh` | planned (T-002) | Claude Code headless spike |
| `codex/run.sh`, `codex/resume.sh`, `codex/parse.jq`, `tests/test_codex_parse.sh` | planned (T-003) | Codex headless spike |
| `normalize/claude.jq`, `normalize/codex.jq`, `tests/test_normalize.sh` | planned (T-004) | normalized event mapping |
| `run-both.sh` | planned (T-007) | end-to-end run of both CLIs (`--dry-run` supported) |

## Running the offline tests

```
/bin/bash spike/tests/test_common.sh
/bin/bash spike/tests/test_preflight.sh
spike/preflight.sh
```

`preflight.sh` exits 0 when it printed a report (a missing or signed-out CLI is reported, not an error) and 1 only when
`jq` or `git` is missing. Its `SIGNATURE` column comes from `codesign --verify --strict` on the private copy of the
resolved binary, plus the signer (first Authority line) and team id from `codesign -dv` on that same copy. In the PATH column the home directory is shown as `~` and
any at-sign in a path is shown as `%` (scoped package directories contain one); this is display only, and the report
footer says so. Version text is filtered to printable characters so a CLI cannot inject terminal escape sequences.
