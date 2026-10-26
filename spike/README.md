# spike/: Phase 0 scratch scripts

Throwaway bash + jq scripts that prove the harness can drive the two provider CLIs through their documented headless
interfaces (`claude -p --output-format stream-json`, `codex exec --json`), parse every event, and resume a session. They
are not product code. Requirements: macOS `/bin/bash` 3.2, `jq`, `git`, and the system `perl` at `/usr/bin/perl` (macOS and
most Linux have it; only core modules are used).

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
    `false`, `sleep`, `echo` and `printf`. Each command is resolved ONCE, physically (a PATH lookup inside the helper,
    then every symlink, with `..` applied the way the kernel applies it), and the resolved path is the one that runs.
    Ungated only when that resolved path is in `/bin`, `/usr/bin`, `/usr/sbin` or `/sbin`. A copy of any of those names in
    another directory, a relative path such as `./x`, a launcher, and every provider CLI (claude, codex, grok, gemini,
    kimi) needs the gate, whatever its name.
    `jq`, `file` and `cat` are not on the list. The words in the **arguments** of those ungated system commands (echo or
    printf text, a path under a directory called `claude`) are not examined: identity is enforced, so they cannot launch
    anything. A provider word in the **program name** (argv[0] or the resolved target) is never ungated.
  - **`spike_run_timed` runs exactly `jq --version` or `git --version` and nothing else** (no other argument at all; `file`
    is gone). The tool must be a native executable (not a `#!` script), owned by you or root and not group/world writable,
    in `/bin /usr/bin /usr/sbin /sbin /usr/local /opt/homebrew`. A wrapper or copy first on `PATH` is refused and never run
    (preflight then reports the tool MISSING and exits 1). The closed environment and watchdog are the same as for every run.
  - **`spike_run_live_split` (T-008)** is `spike_run_live` with stdout and stderr in separate files. Same gate,
    verified-copy rule, environment, watchdog and signals. The errfile gets the outfile policy (O_NOFOLLOW, 0600; no
    symlink, hard link, FIFO or CLI-home parent), and an errfile that resolves to the outfile is refused.
  - **A pinned CLI name runs live only as the registered copy.** `spike_run_live` (and `spike_run_timeout` after its gate)
    refuses, rc 3 and the script stops, a command whose basename or resolved basename is `claude` or `codex` (also
    `claude.exe`, `claude-real`) unless it is the current registered, hash-verified copy (`$SPIKE_VERIFIED_COPY`).
    `SPIKE_LIVE=1` does not lift that (rule 6). A renamed copy under another name cannot be recognised by name, and neither can a launcher (`env claude`, `sh -c`, a version-number basename such as `2.1.0`): names are not identity. The Phase 1 runner (T-115/T-119) decides by identity.
  - **A run needs `HOME` to be the account home.** The child's `HOME` is always the password-database home. If the caller's
    `HOME` is set and is not that directory (same device and inode) the run is refused with rc 125 and nothing starts.
  - **The output file is opened `O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW`, mode 0600.** A symlink, a hard-linked file, a
    non-regular file (a FIFO, a directory; only `/dev/null` is accepted), a CLI home entry, and any file whose parent
    resolves inside a CLI home are refused with rc 125 before the command starts.
  - **Exit-code collisions.** The helper's own codes share numbers with a command's own exit status: 121 the CLI-home
    denylist is unusable (nothing runs), 124 timeout, 125 refused at exec time (HOME, outfile or policy), 126 cannot
    execute, 127 not found, 143/130/129 stopped by TERM/INT/HUP, 3 refused by the gate (the calling script is stopped), 2
    usage. A command that itself exits with one of those numbers is indistinguishable by status alone; callers that must
    tell them apart check the output file. These codes are kept on purpose.
  - **`spike_run_status` runs only the private copy that registration produced** (`$SPIKE_VERIFIED_COPY`), only while its
    content still has the sha256 recorded at registration, and only `--version`, `auth status` or `login status`. Any other
    path, a changed copy, and any other shape is refused (rc 3, nothing started). `SPIKE_LIVE=1` does not lift that refusal.
- **One helper makes every security decision: `lib/runner.pl`.** `lib/common.sh` starts it only as
  `/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C SPIKE_IN_*=... /usr/bin/perl lib/runner.pl <subcommand> ...`: the
  interpreter, `env` and the helper are constant absolute paths, so no `perl`, `env` or `bash` found on `PATH` can stand in
  for them, and the caller's `PERL*` variables are dropped. Every argument comes after the interpreter path, so `env` can
  never read an argument (a command path that contains `=`, for example) as a `VAR=value` assignment. The caller's `PATH`,
  `HOME`, `TMPDIR`, `LANG`, `TERM`, `USER`, `LOGNAME` and `SPIKE_LIVE` reach the helper as `SPIKE_IN_*` values. The helper
  refuses any control character (newline included) in a path it is given, reads or returns, so a `$(...)` in the caller can
  never strip or add bytes. Shebangs are `#!/bin/bash`.
- **Children run with a scrubbed environment** (`PATH HOME TMPDIR LANG TERM`, plus `USER`/`LOGNAME` because a CLI looks up
  its own stored login under the account name), built inside the helper, in their own process group. The helper leads that
  new group, forks the command into it, and watches it: it kills the whole group (TERM, 0.3 s, KILL) on timeout, on
  TERM/INT/HUP to the helper, and when the caller disappears (the helper's parent pid changes; polled every 50 ms). Because
  the watchdog is in the command's group and not in the caller's, **a SIGKILL to the caller, or to the caller's whole process
  group, cannot orphan the command**, and a SIGKILL to the helper's own group kills the command with it. The one case that
  can leave a command running is a SIGKILL sent to the helper process alone, by its pid (nothing is left to sweep): do not
  do that. The `codesign` the helper starts for registration is watched the same way: TERM/INT/HUP to the helper, or the death of its direct parent, kills its group; a SIGKILL to the caller's whole process group can still orphan the `codesign` (see HANDOFF). A command that exits but leaves children behind is swept. Timeouts are digits only, read as decimal (`08` and
  `010` are 8 and 10, never octal), 1 to 3600. Children get stdin from `/dev/null` and write to the outfile. They are not
  in a new session, so a CLI that opens the terminal device is out of scope: the spikes are headless only (rule 3).
- **Binaries are verified before they are executed; registration checks identity, not strings.** `preflight.sh` asks the
  helper to look the CLI up on `PATH` and resolve it once, physically. The helper compares the **device and inode** of every
  directory on the path and of the file against the CLI homes of both the account's
  password-database home and an absolute `$HOME`, so a symlink, a `..` spelling, a hard link, a case-insensitive spelling or a
  firmlink cannot hide a home, and an `HOME` pointed away never lifts the check. **The list of CLI homes is the lead-owned
  `compliance/denylist.txt`**, read at run time by `lib/runner.pl` (found from its own physical path, opened `O_NOFOLLOW`,
  regular file; one `^\.[A-Za-z0-9._-]+$` entry per line, `#` comments, blank lines). If it is missing, empty or malformed
  every operation is refused with rc 121 and one fixed message (fail closed). A path inside a CLI home is never read,
  except the provider binary itself (the ratified narrow exception): it is lstat-ed first and must be a regular file with
  the owner-execute bit and at least 1 MiB (credential files are small and 0600), else it is refused without being opened;
  then the helper reads the magic, and for a Mach-O copies the whole binary (it IS the vendor binary) for verification.
  Capture roots, scratch roots and the verify-directory parent inside a CLI home (also one that does not exist yet) are refused.
  A hard-linked file is refused before any read. The file is opened **once** (`O_NOFOLLOW`), checked with `fstat`, and a
  Mach-O is copied **from that descriptor** into a private directory (mode 700, `spike-verify.<id>` under the temporary
  directory, removed on exit) that the helper itself creates; `spike_verify_dir` only reads its name, nothing can point it
  elsewhere, and the helper re-validates it (owner, mode, name, not inside a CLI home) on every use. A stale one left by a
  killed run is swept at start. A temporary directory that others can write without the sticky bit, or that lies inside a CLI
  home, stops preflight (exit 1, needs human review). The COPY is checked with the fixed `codesign` (`--verify --strict`,
  a `Developer ID Application` authority, the pinned team identifier for that CLI, and an `anchor apple generic` requirement that also demands the Developer ID Application leaf OID `1.2.840.113635.100.6.1.13` (Apple-documented; not run against a real `codesign` in this Linux sandbox)
  for that team); its sha256 is recorded, and `spike_run_status` re-hashes it before it executes it. Ad-hoc, unsigned,
  wrong-team, forged, non-Mach-O and script files are reported (`skipped (unverified)`) and never executed. A script
  launcher is never executed either: its SIGNATURE cell says `launcher only, not executed (needs human approval)`. A copy that
  cannot run is reported `needs human review`; the original path is never used as a fallback. The codesign path is the fixed
  constant `CODESIGN_BIN` (`/usr/bin/codesign`) inside `lib/runner.pl`; no environment variable or flag changes it. Without
  that tool every CLI is `skipped (unverified)`. The pinned team ids sit in one labeled block in `lib/runner.pl`;
  **the human must confirm them against vendor-published values before release.** A process of the same account that can
  write the private directory or the install directory is outside this threat model.
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
| `lib/common.sh` | done (T-001) | sourced helpers: `spike_scratch_repo`, `spike_worktree_add`, `spike_cleanup`, `spike_require_live`, `spike_capture_dir`, `spike_redact`, `spike_resolve_path`, `spike_run_timeout`, `spike_run_live`, `spike_run_live_split <seconds> <outfile> <errfile> <cmd> ...` (T-008: stderr to its own file under the outfile policy), `spike_run_status <seconds> <out> "$SPIKE_VERIFIED_COPY" ...`, `spike_run_timed`, `spike_mark_verified <path> <cli>`, `spike_register_cli <name>`, `spike_under_cli_home`, `spike_verify_init`, `spike_verify_dir`, `spike_verify_cleanup`, `spike_tool_path` |
| `lib/runner.pl` | done (T-001) | the one Perl helper behind `common.sh` (resolve, CLI-home identity check, registration, gate, run with an in-group watchdog); not called directly |
| `preflight.sh` | done (T-001) | table of install path, version, code-signature result and sign-in state for each CLI; verifies and runs only a private copy |
| `tests/test_common.sh` | done (T-001) | offline tests for `lib/common.sh` and `lib/runner.pl` |
| `tests/test_preflight.sh` | done (T-001) | offline tests for `preflight.sh` using fake CLIs on a private PATH |
| `plan/hash.sh`, `plan/check.jq`, `tests/test_plan.sh` | planned (T-005) | plan hash and approval-binding checker |
| `handoff/parse.sh`, `tests/test_handoff.sh` | done (T-006, merged) | HANDOFF.md parser |
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

The suites run in a sandbox directory under `$TMPDIR`. They create **fake CLI-home directories** (named like the real ones,
with canary files in them) **inside that sandbox only**, point `HOME` at the sandbox when they need one, and never read or
write the real ones. Their fixtures are written through a guard that refuses a relative path, a physical parent outside the
sandbox, a symlink and a multiply linked file; tool wrappers are small scripts, not symlinks to host tools; and an exit check
compares the hashes of the host tools they ran. They never set `SPIKE_LIVE=1` outside a fixture run of a fake command, and
they never run a real provider CLI or the real `codesign` (a fake is substituted by rewriting one constant in a sandbox copy
of `lib/runner.pl`).

`preflight.sh` exits 0 when it printed a report (a missing or signed-out CLI is reported, not an error) and 1 when `jq` or
`git` is missing, or when the temporary directory is unsafe for the private verify directory (writable by others without the
sticky bit, or inside a CLI home): that is a "needs human review" stop. Its `SIGNATURE` column comes from
`codesign --verify --strict` on the private copy of the resolved binary, plus the signer (first Authority line) and team id
from `codesign -dv` on that same copy. In the PATH column the home directory is shown as `~` and any at-sign in a path is
shown as `%` (scoped package directories contain one); this is display only, and the report footer says so. Version text is
filtered to printable characters so a CLI cannot inject terminal escape sequences.
