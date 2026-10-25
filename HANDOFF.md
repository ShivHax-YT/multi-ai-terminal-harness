# HANDOFF T-001

Branch T-001-round6, based on T-001 at a08a357. Round 6 fixes the four blockers from the round-4 review, as the lead decided.

## Summary
Round 6 closes the "checks one string, executes another" class. (1) A command is resolved ONCE, physically (`cd -P`, so a
`..` after a symlink resolves as the kernel resolves it; runs of `/` are collapsed), and the runner executes that resolved path
through `/usr/bin/env -i`, never a PATH re-search. (2) `spike_mark_verified <path> <cli>` runs the Mach-O magic check and the
pinned-signer check itself, so a non-Mach-O or unsigned or wrong-team copy is never registered. (3) Ungated `codesign` read-only
shapes accept only a path that resolves inside the private verify directory. (4) Preflight refuses paths inside the CLI home
directories before any `file`, magic read or `cp`, with one narrow exception (the provider binary itself, magic-checked only). It
also refuses an unsafe temporary directory, sweeps stale verify directories, and the runner's subshell replaces the inherited
traps first. Built for macOS `/bin/bash` 3.2; only GNU bash 5.2 on Linux was run here. macOS, real codesign and real CLIs were NOT run.

**HOST DAMAGE, needs a human before anything else: `/usr/bin/cp` and `/usr/bin/dd` on this machine are broken** (78-byte
wrapper scripts that exec themselves; any command that calls them hangs). See Open risks, first item.

## Files changed
- spike/lib/common.sh - rewritten for round 6: `readonly CODESIGN_BIN` (moved from preflight), `spike_resolve_path` (physical),
  `_spike_resolve_cmd`, `spike_run_timed` (moved), `spike_magic_ok`, `spike_under_cli_home`, `spike_set_verify_dir`,
  `spike_pinned_team`, `spike_verify_signer` (moved pinned-signer checks), `spike_mark_verified <path> <cli>`, `_spike_codesign_rooted`,
  runner entry points on the resolved path, `_spike_run_timeout_body` traps first.
- spike/preflight.sh - rewritten for round 6: parent-directory and private-directory safety, stale sweep, CLI-home refusal before
  reads, registration through `spike_mark_verified`.
- spike/tests/test_common.sh - round-6 assertions added; child shells use a sandbox copy of common.sh with a fake codesign.
- spike/tests/test_preflight.sh - Mach-O-headed fixtures; scenarios 8, 8b, 9, 10, 11 added; the codesign-constant checks moved to common.sh.
- spike/README.md - runner and verification rules, script index.
- HANDOFF.md - this file.
- spike/.gitignore - unchanged.

## Tests run
Environment: GNU bash 5.2.21 on Linux, root, no real provider CLI, no real codesign, no SPIKE_LIVE set by hand (the suites set it
themselves where they test the gate). `/usr/bin/cp` and `/usr/bin/dd` are broken on this host (see Open risks), so every suite run
here put TEST-ONLY shims on PATH (byte copy and `if=FILE bs=4 count=1`, kept in the scratchpad, not installed anywhere).
- `bash -n` on spike/lib/common.sh, spike/preflight.sh, spike/tests/test_common.sh, spike/tests/test_preflight.sh: clean.
- `/bin/bash spike/tests/test_common.sh`, three sequential runs: 445 passed, 0 failed in each (rc 0 each).
- `/bin/bash spike/tests/test_preflight.sh`: 113 passed, 0 failed (final run on the committed code).
- `make -s check-fast`: pass (compliance scan clean; no app stack yet, so no stack checks run). The spike suites are not wired into
  `make check-fast` yet (lead follow-up).
- NOT RUN: macOS `/bin/bash` 3.2 (human to run both suites and `spike/preflight.sh` on the Mac before merge), real codesign,
  real claude or codex, shellcheck (not installed), the mutation checks of round 5 (not repeated this round).

## Hard rules touched (rule numbers + the test that proves each)
- Rule 1: the gate is unchanged for every provider CLI: `denied` cases in test_common (env, sh -c, launchers, renamed copies,
  upper-case names, `spike_run_live` without the gate). The new resolver cannot widen it: `reviewer repro with a prompt is refused
  (rc 3)`, `a symlink named alias-true to a provider copy is not ungated (rc 3)`.
- Rule 2: no config-home variable is named anywhere in spike/ or this file (`make -s check-fast` compliance scan clean).
- Rule 3: children are headless (stdin /dev/null, outfile); no PTY code. Unchanged from round 4.
- Rule 4: `CLI home: ...` (test_common, 6 cases), `scenario 8: ...` and `scenario 8b: ...` (test_preflight), `codesign rooted: ...`
  (6 cases), `gate: codesign --verify on a canary under a fake home ...`, `gate: codesign --verify through a symlink into the fake home ...`.
- Rule 6: `registration refused: ...` (test_common, 13 cases incl. rc 3 from spike_run_status and nothing ran),
  `registration accepts a Mach-O copy that passes the pinned signer (rc 0)`, `registered binary passes the identity check ...`,
  `scenario 2 ...`, `scenario 11: ...`, `scenario 9: ...` (unsafe temporary directory), `scenario 10: ...` (stale sweep).

## Round 6: findings -> fix -> test
Status: DONE = implemented and tested here on Linux bash 5.2. PARTIAL = implemented with a stated gap.

1. Physical resolution, execute the resolved path (rules 1, 6; blocker). DONE.
   - Fix: `spike_resolve_path` uses `cd -P` on each directory, follows each symlink, collapses `//`, refuses a final `.`, `..`
     or trailing slash, max 40 links. `_spike_resolve_cmd` does the one PATH lookup (`type -P`). Every entry point executes the
     resolved path through `/usr/bin/env -i` (no PATH search by env).
   - Tests: `reviewer repro resolves to the physical target, not /usr/bin/printf`, `reviewer repro with a prompt is refused (rc 3)`,
     `reviewer repro: the fake printf under the physical target never ran`, `reviewer repro without a prompt is refused too (rc 3)`,
     `reviewer repro (no prompt): the fake printf never ran`, `//usr//bin/printf runs the real printf (rc 0)`,
     `//usr//bin/printf resolves to /usr/bin/printf`, `PATH TOCTOU: the swapped printf never ran in 25 trials (bad runs)`,
     `PATH TOCTOU: every trial ran the resolved printf or refused (rc 0 or 3)`.
2. Registration verifies (rule 6; blocker). DONE.
   - Fix: `spike_mark_verified <path> <cli>` refuses symlinks, then resolves, then requires the Mach-O magic (first four bytes, `dd`
     + `od`: cf fa ed fe, fe ed fa cf, ce fa ed fe, fe ed fa ce, ca fe ba be, be ba fe ca), then requires a pinned team for `<cli>`,
     then runs `spike_verify_signer` (codesign verify, Developer ID authority, pinned team, chain-to-Apple requirement). Preflight
     calls it on the private copy. The codesign constant moved to common.sh.
   - Tests: the thirteen `registration refused:` cases (unsigned, wrong team, ad-hoc, forged, Apple Development, codesign rc 3,
     a Claude-team copy under the codex name, ELF header named claude, shell script with a Mach-O name, a copy of dash named claude),
     each with `so spike_run_status refuses it (rc 3)` and `and nothing ran`; `registration accepts ... (rc 0)`;
     `registration asked codesign about the copy path (verify)`; `registration checked the chain-to-Apple requirement`;
     `registered binary passes the identity check and runs through spike_run_status (rc 0)`.
   - PARTIAL (test-only): on Linux the positive run goes through execvp's ENOEXEC fallback to `/bin/sh` (see Decisions 2). Real
     Mach-O runs are not exercised here.
3. Codesign rooted (rule 4). DONE.
   - Fix: the ungated codesign shapes also require `_spike_codesign_rooted`: the last argument must resolve physically inside the
     directory `spike_set_verify_dir` recorded (preflight's private directory). With no directory set, nothing is rooted.
   - Tests: `codesign rooted: a path inside the verify directory` (1), `...the verify directory itself...` (0), `...a canary path
     under a fake home` (0), `...a symlink in the verify directory that leads to the canary` (0), `...a .. escape out of the verify
     directory` (0), `...no verify directory set` (0); `gate: codesign --verify on a canary under a fake home ...`; `gate: codesign
     --verify through a symlink into the fake home ...`; `the canary was never copied or read into a verify output`.
   - PARTIAL: the positive ungated codesign run (identity check plus rooting) needs a system codesign, so it runs on macOS only; the
     Linux suite proves the rooting function and the denials.
4. Denylist before read (rule 4). DONE, with a deliberate superset (Decision 1).
   - Fix: `spike_under_cli_home` runs before `file`, the magic read and `cp`. A path inside any dot-entry directly under the
     physical HOME, or inside the physical target of such an entry, is refused. The one exception: the PATH-resolved provider binary
     itself, when its first four bytes are a Mach-O magic (`dd bs=4 count=1`); nothing else is read. HOME unset, `/` or unresolvable
     fails closed.
   - Tests: `CLI home: a file under a dot-directory of HOME is refused`, `...any other dot-directory...`, `...an ordinary path under
     HOME is not refused`, `...a dot-entry symlinked to an outside directory...`, `...an outside path is not refused`, `...HOME unset
     fails closed`; `scenario 8: the canary provider path is refused by the CLI-home rule`, `...the canary text never appears in the
     report`, `...no file(1) call names the canary`, `...no cp call names the canary`, `...the only dd call that touches the canary
     reads four bytes`, `...the canary was not copied`; `scenario 8b: the Mach-O provider binary inside a CLI home is allowed`.
5. Private directory safety (rule 6). DONE.
   - Fix: the parent of the private directory must be sticky, or owned by this user and not group- or world-writable; otherwise
     preflight prints `needs human review` and exits 1 before creating anything. The private directory itself must be owned by this
     user with mode 700. Stale `spike-preflight-verify.*` directories owned by this user, real directories, whose `.owner` pid is dead
     are removed at start.
   - Tests: `scenario 9: a world-writable temporary directory without the sticky bit -> exit 1`, `...the refusal says needs human
     review`, `...no CLI ran in the unsafe directory`, `scenario 9: a sticky temporary directory is accepted (exit 0)`;
     `scenario 10: the stale directory (dead owner) was swept`, `...a directory whose owner is alive is left alone`, `...the run's
     own private directory is removed on exit`.
6. Subshell trap window (decision 6). DONE, structurally proven only.
   - Fix: the first statement of `_spike_run_timeout_body` installs the runner's TERM, INT, HUP and EXIT traps. The caller resets
     `_SPIKE_PENDING` before forking the subshell, so the subshell never clears a signal it recorded.
   - Test: `item 6: the runner body's first statement replaces the TERM trap` (reads `declare -f`). A behavioural test of the
     few-microsecond window is not deterministic; the stress block exercises the path, as in round 4.

## Assertions changed in round 6 (none deleted; each change is forced by items 1 to 6)
test_common.sh:
- The registered copies behind `status runner runs registered verified copies ... (rc 0)`, `allowed status calls did start the
  verified copies` (3), `spike_run_status refuses a registered copy whose name is a launcher (rc 3)`, `spike_run_status with a
  prompt is refused even for a registered copy ... (rc 3)`, and the two `spike_run_status of a renamed binary ...` okruns are now
  Mach-O-headed fixtures registered with `spike_mark_verified <path> <cli>` (the signature changed from `<path>` to `<path> <cli>`).
  Same expectations, same names.
- `codesign --verify --strict <provider path> (system codesign)` and `codesign -dv --verbose=2 <provider path> (system codesign)`
  are now `... <path inside the verify dir> ...` and run after `spike_set_verify_dir`. They run only where /usr/bin/codesign exists.
- `spike_mark_verified refuses a relative path / a symlink / a directory (rc 2)`: same expectations; the call now passes a `<cli>`.
New assertions (not replacing any): the registration, rooted, reviewer-repro, TOCTOU, `//usr//bin/printf`, CLI-home and item-6 blocks.

test_preflight.sh:
- `scenario 1: version is shown` is replaced by `scenario 1: the version run reached the fixture body (its log line; ...)`.
  Reason: on Linux the `/bin/sh` fallback that runs a Mach-O-headed fixture writes one "not found" line for the magic bytes before the
  body, so the fixture's first output line is not its version. Real Mach-O CLIs have no such line.
- `scenario 8b: the copy runs and reports its version` is replaced by `scenario 8b: the copy runs (its body wrote the log ...)`. Same reason.
- `the shipped script keeps the fixed codesign path` now checks spike/lib/common.sh (the constant moved there); a new assertion checks
  that preflight.sh defines no codesign constant of its own, and that the sandbox copy differs from the shipped common.sh only in the
  codesign line.
- Fixtures of scenarios 1, 2, 2b, 2c-2f, 3b, 3c, 6, 7: Mach-O-headed. Scenario 3c's bodies now `exec /nonexistent/interpreter`
  (exit 127, `needs human review`), the same outcome as before.

## Decisions I made myself
1. Denylist superset, and the list is NOT in spike/. The compliance scan forbids the CLI home names in any file outside its allowlist
   (spike/ is not allowlisted), so spike/lib and tests name none of them. The denylist is therefore: any dot-entry directly under the
   physical HOME, and the physical target of any dot-entry symlink. This refuses every home that rule 4 lists, and more. The explicit
   list belongs in compliance/ (follow-up for the lead, shared file). Cost: a script launcher inside a dot-directory is refused instead
   of classified.
2. The positive run tests use fixtures whose first four bytes are a Mach-O magic followed by a shell body. On Linux, `env` (execvp)
   hands such a file to `/bin/sh`, which prints one "not found" line and then runs the body. This is test-only. It is the same
   fallback on macOS, but that was not run here. Production never executes a non-Mach-O: registration refuses it first.
3. `spike_mark_verified` takes the CLI name as its second argument, because the pinned team depends on it.
4. `env` is invoked as the absolute `/usr/bin/env` (no PATH search by env). `perl` is still found on PATH (trusted tool, not a provider).
5. Preflight exits 1 (`needs human review`) if the temporary directory is writable by others without the sticky bit. That is the
   human-review route the brief asks for.
6. The stale sweep only removes directories whose `.owner` record names a dead pid. A directory without that record is left alone.
   A SIGKILL between `mktemp` and writing the record leaves a directory behind (rare, documented).
7. `spike_verify_signer` is the shared pinned-signer check; `spike_mark_verified` calls it, and preflight reads the signature column
   from `SPIKE_SIG_TEXT` set by it.
8. `spike_under_cli_home` fails closed when HOME is unset, `/`, or cannot be resolved.

## Open risks / questions
- HOST DAMAGE (highest priority, human action needed): `/usr/bin/cp` and `/usr/bin/dd` on this machine were overwritten by a
  test-fixture bug in round 6 (scenario 8 wrote logging wrappers through symlinks that `mkbin` had created to the system binaries).
  The fixture is fixed (it removes those links before writing). The two files are now 78-byte shell wrappers that exec themselves
  and hang. An attempt by this agent to write the originals back was denied by the auto-mode safety check, and I did not try
  another route. The original binaries from the package (coreutils 9.4-3ubuntu6.3) are extracted, not installed, at
  `/tmp/claude-0/-home-user/7e5d6d3f-e3ee-5774-9d97-7557dc926aa7/scratchpad/restore/x/usr/bin/cp` and
  `/tmp/claude-0/-home-user/7e5d6d3f-e3ee-5774-9d97-7557dc926aa7/scratchpad/restore/x/usr/bin/dd`. Human restore, for example:
  `sudo install -m 0755 <that cp> /usr/bin/cp` and the same for dd, or `sudo apt-get install --reinstall coreutils`; then
  `dpkg --verify coreutils` should be clean. I also ran `apt-get update` to fetch the package. The suites above passed only with
  TEST-ONLY shims on PATH.
- Pinned team ids Q6L2SF6YDW (claude) and 2DC432GLL2 (codex) are taken from this Mac's installed binaries and are NOT confirmed against
  vendor-published values. HUMAN ACTION before release. A vendor re-sign under another team fails closed (UNTRUSTED).
- A CLI that finds its own resources relative to its installed location may not run from the private copy. The row then says
  "needs human review" (never a fallback). Must be checked on the Mac with the real claude and codex.
- Residual race in preflight: between the CLI-home check and `cp`, the provider path could be swapped by a process that already
  has write access to the provider's install directory (the same user). Not closed here; documented.
- The denylist is a superset and lives in code, not in compliance/ (Decision 1). The explicit list should move there.
- The stress block and the signal tests have a timing history: a flake was seen in round 4 and not reproduced in round 5 or in
  this round's three runs. The root cause is still open. The three-run result above is the evidence for this round only.
- macOS `/bin/bash` 3.2 not run. Assumed behaviours to check there: `type -P`, `cd -P`, `readlink` without `-f`, `declare -f` layout
  (used by the item-6 test), `dd bs=4 count=1`, `od -An -tx1`, `mktemp -d`, `perl stat`.
- shellcheck not run.
- The `file` and `codesign` checks on a real Mach-O are not exercised anywhere in this round.

## Confidence
Medium-high for the logic on GNU bash 5.2 / Linux: every new check has a test that fails on the old behaviour (reasoned from the
probes: default `cd` gives /usr/bin where the kernel runs the fake; `cd -P` matches the kernel). Medium-low on the Mac (3.2, real
CLIs, real codesign): not run. The host's `cp` and `dd` must be restored before any further run of these suites.

## Follow-ups for shared files (lead)
- Makefile: add a `spike-test` target running `/bin/bash` on each `spike/tests/*.sh`, and include it in `check-fast`.
- .github/workflows/ci.yml: extend the shellcheck step to spike/ (`shellcheck -S warning spike/lib/common.sh spike/preflight.sh spike/tests/*.sh`).
- compliance/: add a denylist file with the explicit CLI home list (rule 4), and have spike read it instead of the superset in code.
- Host: restore /usr/bin/cp and /usr/bin/dd (see Open risks). This is outside the repo and needs a human.
- Later briefs (T-002, T-003, T-007) must start provider CLIs with `spike_run_live` and call `spike_require_live` first at top level.
