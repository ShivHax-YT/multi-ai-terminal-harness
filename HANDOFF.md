# HANDOFF T-001
## Summary
Phase 0 spike scaffold under spike/: sourced bash helpers (scratch repo outside this repo, worktree add, guarded cleanup,
`SPIKE_LIVE=1` gate, capture dir, redaction, symlink resolver, a default-deny command runner), a preflight that runs a
CLI only after its signature verifies as the pinned vendor signer, offline tests, and a README. This is the second fix
round after the compliance gate: the live gate is now default-deny, preflight pins signer identities, signals no longer
orphan children, and the environment is tested as a closed set. Runs on macOS /bin/bash 3.2.

## Files changed
- spike/lib/common.sh - helpers; default-deny runner (spike_run_timeout / spike_run_live / spike_run_status), signal-safe process-group handling, spike_require_live with watchdog
- spike/preflight.sh - verify-then-execute table; pinned team ids block; chain-to-Apple requirement check
- spike/tests/test_common.sh - 273 offline assertions (round 3: zombie-aware `alive()` plus 4 control assertions)
- spike/tests/test_preflight.sh - 73 offline assertions with fake CLIs/codesign/file on a private PATH
- spike/README.md - rules, wave order, script index
- spike/.gitignore - ignores captures/

## Tests run
- `make check-fast` - PASS (compliance scan clean; no app stack yet)
- `/bin/bash spike/tests/test_common.sh` - 273 passed, 0 failed (round 3: 3 runs on GNU bash 5.2.21, Linux, all 273/0)
- `/bin/bash spike/tests/test_preflight.sh` - 73 passed, 0 failed (round 3: Linux, GNU bash 5.2.21)
- `/bin/bash -n` on all four scripts - clean
- `/bin/bash spike/preflight.sh` on this Mac - exit 0; claude and codex both "valid; Developer ID Application ...; team <pinned>", signed in; `| grep -c @` is 0
- Manual: a real ad-hoc-signed copy of /usr/bin/true named `codex` first on PATH is reported UNTRUSTED and not executed
- shellcheck: not installed, not run

## Round 2 gate items
1. Rule 1, default-deny. `spike_run_live` (always calls spike_require_live) is the entry point for every real prompt (T-002/T-003/T-007). `spike_run_timeout` without SPIKE_LIVE runs only: git (exactly `--version`), jq, codesign (exact read-only verify shapes), file, true, false, sleep, echo, cat, printf (lower-cased basename, and the resolved target must not be a shell/env/xargs/interpreter), plus a provider CLI with exactly `--version` / `auth status` / `login status`. Everything else needs the gate, and any argument containing claude|codex|grok|gemini|kimi as a whole word (any case) needs it too, except the codesign shapes. `spike_run_status` is for preflight's already-verified binary: any file name, only the three status shapes. Tests (rc 3, caller stopped, fake CLI never started) for: `env claude`, `/usr/bin/env claude`, `sh -c`, `bash -c`, `/bin/bash -c <path>`, a renamed copy (with a prompt and with --version), an unknown name, `CLAUDE` and `Codex` upper-case paths, provider names in echo/cat args, git alias, git status, zsh dash ksh xargs nohup command exec time nice perl python python3 node ruby script expect osascript open, spike_run_live without the gate, spike_run_status with a prompt. Harmless shapes are tested to still run.
   Deviation to note: git is allowed only as `git --version` (a git alias or pager can run any program); use spike_run_live or call git directly for other git work.
2. Rule 6. A CLI runs only if `codesign --verify --strict` passes, the first Authority starts with `Developer ID Application`, TeamIdentifier equals the pinned value, AND `codesign --verify --strict -R="anchor apple generic and certificate leaf[subject.OU] = <team>"` passes (the text of -dv can be forged with a self-made certificate; the requirement check validates the chain to Apple). Pins (one labeled block at the top of preflight.sh): claude Q6L2SF6YDW (Anthropic PBC), codex 2DC432GLL2 (OpenAI). THE HUMAN MUST CONFIRM THEM AGAINST VENDOR-PUBLISHED VALUES BEFORE RELEASE. Ad-hoc, no authority, not Developer ID, wrong team, forged chain, unsigned, other codesign failures: "skipped (unverified)", not executed. Script launchers: not executed ("launcher only, not executed (needs human approval)"). Tests assert a marker file stays absent for unsigned, weird-failure, ad-hoc, wrong-team, notdev, forged and script cases, that the resolved (not symlink) path is verified and executed, and that the chain requirement is requested.
3. Signals. The runner subshell traps TERM/INT/HUP (exit 143/130/129) and EXIT, and kills the child's process group (TERM, 0.3 s, KILL). The caller side traps TERM/INT/HUP while waiting, forwards TERM to the runner, waits for it, then exits; the caller's own INT/TERM/HUP traps are restored afterwards. Tests: TERM and HUP sent to a running caller leave no launcher or grandchild, the caller exits with a signal status and never runs the next statement; the caller's TERM trap is restored. (INT cannot be sent to a background job in a non-interactive shell, so it is not tested; its handler is the same code path.)
4. require_live with a custom TERM trap. Header says source from scripts only; README says call at top level as the first statement and never override TERM. Fail-safe: a detached watchdog (`sleep 0.3`, then KILL the top-level script if still alive). This is a variation on the suggested `sleep 0.2; kill -s KILL "$$"`: killing inline would make a normal `$(...)`/pipe/subshell call exit 137 instead of 3, because the parent only runs its exit-3 trap after the subshell ends. Tests: documented top-level use (rc 3, nothing printed after; continues with SPIKE_LIVE=1), a caller with `trap "" TERM` and one with its own TERM trap are both killed before the following statement completes. Limitation: a caller that ignores TERM can still run statements for up to 0.3 s after a subshell call; the fail-safe bounds it, it does not make it impossible.
5. Env closed set. Test exports generic probes (FOO_API_KEY, FOO_HOME, FOO_CONFIG_DIR, BAR_TOKEN, HTTPS_PROXY, SSH_AUTH_SOCK, XDG_CONFIG_HOME), runs `env`, `sh -c env` and `bash -c env` through spike_run_live, and fails on any variable outside HOME LANG LOGNAME PATH TERM TMPDIR USER (plus PWD SHLVL _).

## Round 3 (final fix round: process-group kill on Linux)
- Symptom: on GNU bash 5.2.21 (Linux, procps-ng ps 4.0.4) `/bin/bash spike/tests/test_common.sh` gave 265 passed, 4 failed: "grandchild was killed with the launcher", "leftover background child was swept", "SIGTERM/SIGHUP to the caller: grandchild is gone". macOS /bin/bash 3.2 passed all.
- Root cause: the kill works. `perl setpgrp` plus `kill -- -PGID` (TERM, 0.3 s, KILL) does kill the grandchild, but it is left as a zombie (state Z) re-parented to PID 1 once its launcher is gone. The test's "gone" check was `kill -0`, which succeeds on a zombie. This VM's PID 1 reaps orphans lazily (a measured zombie lasted about 1.6 s, and the tests waited 0.8 s or less). launchd on macOS reaps orphans at once, which fits the all-pass macOS run (not re-checked on a Mac in this round).
- Fix: `alive()` in spike/tests/test_common.sh now says a process is alive only if `kill -0` succeeds and `ps -o stat=` does not report Z. If ps gives no state, the process still counts as alive (fail closed). All other assertions are unchanged, and a running process still fails them. Four new control assertions prove the predicate: a running process is alive, a zombie fixture is in state Z, and a zombie is not alive. spike/lib/common.sh is unchanged. A longer sleep was rejected because the reap time belongs to PID 1, not to the runner.
- Not done in code: the runner cannot reap an orphaned grandchild (it is not the parent). The only code-side option is making the runner a Linux child subreaper with prctl through perl. That is architecture-specific and changes the process tree, so it was not done in this round.
- Tested: GNU bash 5.2.21 on Linux (procps-ng ps 4.0.4). test_common.sh 3 runs, each 273 passed / 0 failed. test_preflight.sh 73 / 0. `make -s check-fast` passes. `bash -n` clean on all four scripts. Not run: macOS /bin/bash 3.2 (no Mac in this session) and shellcheck. The new code uses only bash 3.2 features (`local`, `case`, `$(( ))`, no arrays).

## Hard rules touched (rule numbers + the test that proves each)
- 1: test_common.sh "gate:" cases, require_live cases, signal tests
- 2: no config-home variable named in spike/ (compliance scan); closed-set environment test
- 4: sign-in by exit code only, output discarded (test_preflight.sh scenario 1); no credential paths in code (scan)
- 6: test_preflight.sh scenarios 1-3b (pinned signer, nothing unverified executed, resolved binary executed)

## Open risks / questions
- Pinned team ids come from the binaries installed on this Mac, not from vendor publications; the human must confirm them. A legitimate vendor re-signing under another team would show as UNTRUSTED (fail closed).
- Script-launcher installs (for example an npm shim) are never executed by preflight; the human must approve explicitly. On this Mac both CLIs resolve to Mach-O binaries, so the report is complete.
- Redaction over-redacts by design (see round 1 notes). The earlier changed test (lookalike home prefix) stays changed.
- `spike_require_live` installs a TERM trap on source unless the caller already has one; it would terminate an interactive shell that sources common.sh and calls it.
- Needs perl (present on macOS) for the process-group start.
- The codex binary resolves under its CLI home directory (the lead is recording that the file-access layer needs a narrow allowlist for installed binaries there). Preflight displays that path as `~/...` and, after verification, executes the binary; it does not read the directory.
- Preflight runs `--version` and the status command without SPIKE_LIVE, only for binaries that passed the pinned-signer check, and only via spike_run_status's exact shapes.

## Follow-ups for shared files (lead)
- Makefile: add a `spike-test` target running `/bin/bash` on each `spike/tests/*.sh` and include it in `check-fast`.
- .github/workflows/ci.yml: extend the shellcheck step to spike/ (`shellcheck -S warning spike/lib/common.sh spike/preflight.sh spike/tests/*.sh`). SC2059 (printf with a format variable) is info level only.
- Later briefs (T-002, T-003, T-007) must start provider CLIs with `spike_run_live` and call `spike_require_live` first at top level.

## Confidence
High on behaviour on GNU bash 5.2 / Linux (273 + 73 pass, repeated runs). Medium overall: bash 3.2 on macOS was last run in round 2 (342 assertions) and not re-run after round 3, and shellcheck was not run. The round 3 change is in a test predicate, so the lead should re-run both suites on the Mac before merge.
