# spike/: Phase 0 scratch scripts

Throwaway bash + jq scripts that prove the harness can drive the two provider CLIs through their documented headless
interfaces (`claude -p --output-format stream-json`, `codex exec --json`), parse every event, and resume a session. They
are not product code. Requirements: macOS `/bin/bash` 3.2, `jq`, `git`.

## Rules for every script here

- **`SPIKE_LIVE=1` is the only way to call a real CLI.** Any script that starts a provider CLI session calls
  `spike_require_live` first; without `SPIKE_LIVE=1` it exits 3 and does nothing. Offline tests never set it.
  (`preflight.sh` only asks each CLI for its version and sign-in status. It sends no prompt.)
  `SPIKE_LIVE=1` is a guard against accidents, **not an approval**. An agent must never set it (not in a script, an
  environment file or a command line) unless the human explicitly asks for that live run. `spike_require_live` stops the
  whole calling script (exit 3), even when called inside `$(...)`, a pipe or a subshell, and `spike_run_timeout`
  applies it itself to any provider CLI (claude, codex, grok, gemini, kimi) except for `--version`, `auth status` and
  `login status`.
- **Children run with a scrubbed environment** (`PATH HOME TMPDIR LANG TERM`, plus `USER`/`LOGNAME` because a CLI looks up
  its own stored login under the account name), in their own process group that is killed on timeout.
- **Binaries are verified before they are executed.** `preflight.sh` checks the code signature of the resolved binary
  first and never runs a Mach-O whose signature does not verify (`skipped (unverified)`). A script launcher is run, and
  its SIGNATURE cell says `launcher only` because the signature then covers the launcher, not the program it starts.
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
| `lib/common.sh` | done (T-001) | sourced helpers: `spike_scratch_repo`, `spike_worktree_add`, `spike_cleanup`, `spike_require_live`, `spike_capture_dir`, `spike_redact`, `spike_resolve_path`, `spike_run_timeout` |
| `preflight.sh` | done (T-001) | table of install path, version, code-signature result and sign-in state for each CLI |
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
`jq` or `git` is missing. Its `SIGNATURE` column comes from `codesign --verify --strict` on the resolved binary, plus the
signer (first Authority line) and team id from `codesign -dv`. In the PATH column the home directory is shown as `~` and
any at-sign in a path is shown as `%` (scoped package directories contain one); this is display only, and the report
footer says so. Version text is filtered to printable characters so a CLI cannot inject terminal escape sequences.
