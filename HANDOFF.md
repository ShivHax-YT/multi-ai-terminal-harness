# HANDOFF T-001

## Summary
Phase 0 spike scaffold under spike/, round 4 (branch T-001-round4, based on T-001 at 74e6d2c). The ungated runner is now
identity-based (an ungated command must resolve to a system directory; cat, jq and file are no longer ungated).
spike_run_status accepts only a private copy that preflight verified and registered. Preflight copies a Mach-O CLI into a
private 700 directory, verifies the copy against a readonly codesign path, and executes only that copy. The runner
watches its caller and kills the command's group when the caller disappears, including after SIGKILL. TERM, INT and HUP
that land between starting a command and recording its pid are handled. Built for macOS /bin/bash 3.2; only GNU bash 5.2
on Linux was run here. Known open problem: test_common.sh flaked twice in later runs (see Open risks, first item).

## Files changed
- spike/lib/common.sh - runner rewritten: identity check, codesign read-only shapes, spike_mark_verified, verified-only
  spike_run_status, caller watch, pending-signal handling on the runner and caller side
- spike/preflight.sh - readonly CODESIGN_BIN constant, private copy directory, copy-verify-run, direct calls (with a perl
  alarm timeout) for file, jq and git
- spike/tests/test_common.sh - round-4 assertions (see "Assertions changed in round 4")
- spike/tests/test_preflight.sh - runs a sandbox copy with only the codesign constant rewritten; scenarios 3b, 3c, 6, 7 added
- spike/README.md - rules, script index
- HANDOFF.md - this file
- spike/.gitignore - unchanged

## Tests run
Environment: GNU bash 5.2.21, Linux, no real provider CLI run, no SPIKE_LIVE set by hand (the suites set it themselves).
- `bash -n` on spike/lib/common.sh, spike/preflight.sh, spike/tests/test_common.sh, spike/tests/test_preflight.sh: clean.
- `/bin/bash spike/tests/test_preflight.sh`: 90 passed, 0 failed (one run on the committed code; 90/0 on every run of
  this round).
- `/bin/bash spike/tests/test_common.sh`, runs on the committed code: 387 passed, 0 failed (one run, the final run);
  earlier runs on the same code: 387/0, 387/0, 386 passed/1 failed (stress block, before the hardening below), 386/1
  (SIGHUP grandchild check, after the hardening). The two failures are the flake in "Open risks".
- `make -s check-fast`: pass (compliance scan clean; no app stack yet).
- Mutation checks (temporary edit of spike/lib/common.sh, suite run, original restored and diffed identical each time):
  - caller watch disabled: 2 failures ("orphan sweep: ... gone within 2 s" for the launcher and the grandchild).
  - system-path identity check bypassed: 21 failures (identity copies of printf, echo, true and codesign). cat and jq
    copies still refused, by the allowlist (second layer).
  - verified-copy registry accepts any path: 9 failures (spike_run_status with the original claude path and renamed copies).
- Signal probes outside the suite (scratch copies, not the suite): 60 TERM/HUP trials on the caller-grandchild check and
  about 1000 signal trials on the start-up stress path, no survivor found.
- NOT RUN: macOS /bin/bash 3.2 (not re-run, human to run both suites on the Mac before merge). shellcheck (not installed).

## Hard rules touched (rule numbers + the test that proves each)
- Rule 1: identity-based ungated list; every provider CLI needs SPIKE_LIVE=1 in spike_run_timeout. Tests:
  `identity: copy of <cat|printf|echo|true|codesign|jq> ...` (18), `identity: copy of codesign shadowing PATH, verify shape`,
  `gate: upper-case CLAUDE --version through spike_run_timeout`, `run_timeout refuses an unverified claude --version ...`.
- Rule 2: no config-home variable named anywhere in spike/ or this file (compliance scan, make check-fast).
- Rule 3: children headless (stdin /dev/null, output to the outfile); no PTY code. Documented: not a new session, so a CLI
  that opens the terminal device is out of scope.
- Rule 4: preflight reads a resolved binary only to classify it (file -b), copies it only when it is a Mach-O, and
  verifies the copy. Test: scenario 3 (script launcher not copied or run); scan.
- Rule 6: preflight tests scenarios 1, 2, 2b, 2c-2f, 3, 3b, 3c, 6, 7 (pinned signer, chain requirement, copy verified,
  only the copy run, codesign path not changeable by environment).

## Round 4: findings -> fix -> test
Status key: DONE = implemented and tested here on Linux bash 5.2. PARTIAL = implemented with a stated gap.

1. Identity, not name (rule 1 blocker; rule 4 finding on symlinked provider files)
   - 1a DONE. Fix: `_spike_is_allowlisted` = git, codesign, true, false, sleep, echo, printf. cat, jq and file removed.
     Callers checked: only preflight used them; preflight now calls file, jq and git directly through `run_timed`.
     Tests: `denied "jq --version needs the gate ..."`, `identity: copy of <name> by absolute path, with a prompt (rc 3)`,
     `... by ./relative path ...`, `... shadowing PATH ...`, for all six names.
   - 1b DONE. Fix: `_spike_ungated_ok`. argv[0] must be a bare name or an absolute path (`./x` refused); `type -P`
     lookup; `spike_resolve_path` (every symlink); resolved path must be under /bin, /usr/bin, /usr/sbin or /sbin;
     basename must be allowlisted for argv[0] and for the resolved target; launcher names refused.
     Tests: the identity tests above, `identity: absolute /usr/bin/true is a system binary and runs`.
   - 1c DONE. Fix: `_spike_codesign_shape` accepts only the three read-only verify shapes, and the path argument may not
     start with a dash. Without a system codesign (Linux) the shapes need the gate, since identity cannot pass.
     Tests: `codesign --sign - x is not ungated (rc 3)`, `codesign --remove-signature is not ungated (rc 3)`,
     `codesign shape: ...` (8 cases), the conditional `codesign verify` okrun / denied pair.
   - 1d DONE. Fix: the provider-name exception is removed from spike_run_timeout; only spike_run_status runs the status
     shapes, for registered copies. Tests: `run_timeout refuses an unverified claude --version / auth status without
     SPIKE_LIVE`, `... codex login status ...`, `refused unverified status calls did not start the CLIs`.

2. spike_run_status (blocker): DONE. Fix: refuses any argv[0] not registered by `spike_mark_verified` (exact path,
   shell state, not environment); only the three status shapes; launcher-name check on the argv[0] and resolved basenames;
   refusal ends the caller with rc 3 whatever SPIKE_LIVE says. Tests: `spike_run_status with /bin/sh auth status is
   refused (rc 3)`, `... started nothing (no output in the outfile)`, `... refused even with SPIKE_LIVE=1 (rc 3)`,
   `gate: spike_run_status with the original (unregistered) claude --version (rc 3)` (and auth status),
   `spike_run_status refuses a registered copy whose name is a launcher (rc 3)`,
   `spike_run_status with a prompt is refused even for a registered copy and SPIKE_LIVE=1 (rc 3)`,
   `status runner runs registered verified copies ... (rc 0)`, `spike_mark_verified refuses a relative path / a symlink /
   a directory (rc 2)`.

3. Verify-then-execute TOCTOU and verifier shim (rule 6): DONE. Fix: preflight has `readonly CODESIGN_BIN="/usr/bin/codesign"`
   (no env var or flag changes it). Each CLI: resolve; file -b on the original; only a Mach-O is copied into
   `mktemp -d` (700, removed by the EXIT trap); the copy is classified and verified with the pinned-signer checks
   including the chain-to-Apple requirement; `spike_mark_verified` registers only the copy; only the copy runs for
   --version and the status command. Exit 126/127 from the copy is reported "needs human review", with no fallback.
   Tests: `scenario 1: the commands ran from the private copy directory`, `... the private copy directory is removed on
   exit`; `scenario 3b: codesign was asked about the private copy`, `... the private copy is what ran (version|status)`,
   `... the original was never executed`, `... mode 700`; `scenario 3c: a copy that cannot run is 'needs human review'`
   (version and sign-in), `... the original path was NOT used`; `scenario 6: the shipped script reports claude/codex as
   skipped (unverified)`, `... without /usr/bin/codesign ... codesign unavailable`, `... no CLI was executed`;
   `scenario 7: an exported codesign (PATH and env) is never called`; `the shipped script keeps the fixed codesign path`.
   Tests run a sandbox copy with only the constant line rewritten (sed). The shipped script has no override hook.

4. Orphans on caller SIGKILL (decision 4): DONE. Fix: the runner records the caller's `$$` at start; every 0.5 s
   (zombie-aware: kill -0 plus `ps -o stat=` not Z) it kills the command's group and reaps it when the caller is gone.
   Tests: `orphan sweep: the CLI launcher is gone within 2 s of kill -9 of its caller`, `... the grandchild is gone within
   2 s ...`, `orphan sweep: the killed caller ran no further statement`. Mutation check: watch disabled fails both gone
   assertions.

5. Signal race (decision 5): DONE for the handling; PARTIAL for "detached from the TTY". Fix: the runner's TERM/INT/HUP
   trap records `_SPIKE_PENDING` when the pid is not yet known and acts right after `_SPIKE_CHILD_PID=$!`; the caller
   (`_spike_forward`) does the same with `_SPIKE_BG_PENDING` after `_SPIKE_BG=$!`. Tests: `signal before the pid is known:
   the handler does not exit (rc)`, `... recorded for the handoff`, `... execution continues to the handoff`; `signal after
   the pid is known: exits with the signal status (rc)`, `... nothing runs after the handler`, `... the command is gone`;
   `caller: a signal before the runner exists is recorded for the handoff`; `stress: no command survives a TERM or HUP sent
   right after the start` (10 runs; exercises the path, does not prove the few-microsecond window is hit).
   Documented: stdin /dev/null; own process group; NOT a new session (see decision 7). A CLI that opens the terminal device
   is out of scope (headless only).

6. Tests (decision 6): DONE for all listed cases; bash 3.2 compatibility NOT VERIFIED (code uses only 3.2 features, but no
   3.2 run). Copies of cat, printf, echo, true, codesign and jq: absolute path, ./relative and PATH shadowing, each with
   a prompt: rc 3, marker absent (18 tests + codesign shadow). `codesign --sign - x` and `--remove-signature`: rc 3.
   `spike_run_timeout` with an unverified claude/codex `--version`: rc 3. `spike_run_status` with /bin/sh and with the
   original path: rc 3. Preflight executes the private copy (3b). Codesign constant not changeable by env (scenario 7).
   Caller kill -9 cleanup (orphan sweep). Linux without codesign: skipped (unverified) (scenario 6).

7. HANDOFF (decision 7): DONE (this section).

### Round 5
Fixed post-signal sleeps replaced by a bounded poll (test file only; `spike/lib/common.sh` unchanged). New helper
`gone_within <tenths> <pid>...` polls `alive()` every 0.1 s and passes as soon as no pid is alive (zombies and empty pids
count as gone). With a pid still alive at the deadline it fails and prints one `ps -o pid=,ppid=,pgid=,stat=,etime=,args=`
line per survivor. Used in the TERM/HUP caller checks, the grandchild and leftover sweep checks, the orphan-sweep kill -9
checks, the signal-after-pid check, and the stress loop (which now polls `ours()` for 3.0 s, not 2.0 s). Removed sleeps:
0.3 s (grandchild, leftover, signal-after-pid, stress) and 0.8 s (TERM/HUP). Deadline change: the orphan-sweep gone checks
moved from 2 s to 3 s, as the lead decided. A genuine orphan still fails. The zombie fixture's 0.3 s precondition sleep is
unchanged (residual risk under load). The "default capture root" assertion is unchanged; a comment above it says the
suite must not run concurrently in one worktree (shared spike/captures). Negative check: a live survivor makes
`gone_within` return 1 with the diagnostic line; exited and empty pids return 0. Results: 5 sequential runs of
`/bin/bash spike/tests/test_common.sh` gave 387 passed, 0 failed each; 3 rounds of 4 parallel copies (each a `cp -a`
clone of the worktree) gave 12 of 12 runs at 387 passed, 0 failed. Linux bash 5.2 only; bash 3.2 not run.

## Assertions changed in round 4 (none deleted; each change follows a decision above)
test_common.sh:
- "run_timeout allows claude --version / claude auth status / codex login status without SPIKE_LIVE" (3 assertions) ->
  "run_timeout refuses an unverified ..." (rc 3). Positive case kept as "status runner runs registered verified copies ... (rc 0)"
  (decision 1d).
- "allowed calls did start the CLIs" (3) -> "refused unverified status calls did not start the CLIs" (0), then
  "allowed status calls did start the verified copies" (3).
- "okrun jq --version" -> "denied jq --version needs the gate" (decision 1a).
- "okrun codesign --verify --strict / -dv --verbose=2 <provider path>" -> same okruns when /usr/bin/codesign exists;
  otherwise a denied assertion (decision 1c; Linux has no system codesign).
- "okrun spike_run_status of a renamed binary with --version / login status" -> same labels plus
  "(registered as a verified copy first)" (decision 2).
- "okrun upper-case CLAUDE with --version" -> "denied upper-case CLAUDE --version through spike_run_timeout" (decision 1d).
- Added `rm -f "$FAKE"/ran-*` before one denial and reset of `SL`/`SG` in the stress block (test hygiene).
test_preflight.sh:
- "scenario 3b: codesign was asked about the resolved path" -> "...about the private copy (verify the copy, not the original)".
- "scenario 3b: the resolved binary is what ran (version/status)" -> "the private copy is what ran (version/status)".
- scenario 2 (adhoc, wrongteam, forged) "reported as ..." assertions moved into the loop, same expectations and names.
- Codesign fakes are now one file at the constant's sandbox path (not one per bin directory).

## Decisions I made myself
1. Branch and location: the harness refused this agent access to the T-001 worktree. Work was done in this worktree on
   branch T-001-round4, created at T-001's 74e6d2c. T-001 and its worktree were not touched. Lead: fast-forward T-001 to
   this commit, or re-place the agent.
2. preflight calls file, jq and git directly through `run_timed` (perl alarm timeout), not through the runner. The identity
   rule would make a Homebrew git or jq (outside system directories) abort preflight with rc 3, and preflight must report.
   Codesign has no runner route: the sandbox shim is outside system directories.
3. Only a Mach-O is copied. file -b runs on the resolved original first; a non-binary (for example a symlink to a data
   file) is never copied. The copy is classified again before verification.
4. The caller is the top-level script's `$$`. A runner started inside `$(...)` or a pipe watches the top-level script,
   not the subshell (`$PPID` is fixed in subshells and cannot be used).
5. Interpreter check: the resolved target's basename must not be a launcher name. No shebang-content check: preflight
   registers only Mach-O copies, and a shebang check would refuse the test fixtures without a security gain.
6. spike_run_status refusals end the caller with rc 3 even with SPIKE_LIVE=1 (not a gate: refusals the gate cannot lift).
7. No setsid: children are not put in a new session. That would change the session semantics the Mac sign-in check depends
   on, and it cannot be tested here. So "detached from the TTY" is documented as own process group, stdin /dev/null,
   and /dev/tty out of scope. This is a deviation from the brief wording.
8. `ps` is required by `_spike_exec` (rc 2 if missing) rather than running without the caller watch.

## Open risks / questions
- FLAKE, OPEN (highest priority): test_common.sh failed twice in later runs of this round, once in the signal stress
  block (before hardening) and once in the existing "SIGHUP to the caller: grandchild is gone" check (after hardening).
  Both mean a `sleep 33` process outlived the runner's group kill as seen by the test. Reproduction outside the suite: 60
  caller-signal trials, about 240 start-up-window trials and 400 immediate-signal trials found no survivor. Root cause NOT
  found. The design argument (group KILL after TERM, runner exits only after KILL, zombies counted as gone) says a survivor
  is not possible, so either the test's 0.3 s / 0.8 s waits are too short under load or there is a path I have not seen.
  Lead must decide whether to merge before this is run to ground (for example, a repeated-run loop on the Mac).
- Pinned team ids Q6L2SF6YDW (claude) and 2DC432GLL2 (codex) are taken from this Mac's installed binaries and are NOT
  confirmed against vendor-published values. HUMAN ACTION before release. A vendor re-sign under another team fails
  closed (UNTRUSTED).
- A CLI that finds its own resources relative to its installed location may not run from the private copy. The row then
  says "needs human review" (never a fallback). Must be checked on the Mac with the real claude and codex. Not run here.
- Preflight still reads the resolved binary (file -b, cp for a Mach-O, codesign). For codex the resolved path may sit under
  its CLI home directory; the file-access allowlist the lead tracks is still needed.
- spike_mark_verified is a trust point. Only preflight calls it (grep); a future caller must verify first.
- Caller watch uses the top-level `$$` (decision 4). A subshell-only death is not detected.
- Not a new session (decision 7): a CLI that opens /dev/tty is out of scope.
- macOS /bin/bash 3.2 not run; `type -P`, the `[[:cntrl:]]` case class and `read` behaviour are assumed to match on 3.2.
- shellcheck not run.
- The killed-caller test prints a "Killed" notice from the test shell (cosmetic).

## Confidence
Medium. High that the identity, registry, pending-signal and caller-watch logic does what the tests say on GNU bash 5.2 /
Linux: each guard was removed in turn and the suite caught it (mutation checks above). Lower confidence on timing: the
suite flaked twice in later runs and the root cause is open, so the suite is not yet a reliable merge gate. Medium-low on
the Mac (3.2, real CLIs, real codesign): not run.

## Follow-ups for shared files (lead)
- Makefile: add a `spike-test` target running `/bin/bash` on each `spike/tests/*.sh` and include it in `check-fast`.
- .github/workflows/ci.yml: extend the shellcheck step to spike/ (`shellcheck -S warning spike/lib/common.sh spike/preflight.sh spike/tests/*.sh`).
- Later briefs (T-002, T-003, T-007) must start provider CLIs with `spike_run_live` and call `spike_require_live` first at top level.

## Round 2 and Round 3 (history; partly superseded by Round 4)
- Round 2: default-deny runner, pinned signer checks, signal-safe process groups, env closed-set test. The allowlist
  described there (cat, jq, file, provider status shapes) is superseded by Round 4 items 1a and 1d.
- Round 3: zombie-aware `alive()` in the test suite. Kept; Round 4 adds `ours()` (command-line match) for the stress block.
