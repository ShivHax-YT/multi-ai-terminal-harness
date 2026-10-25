# HANDOFF T-001

Branch T-001-round7, based on T-001 at 26cbcb4. Round 7 is the structural round the lead decided after six patch rounds (items A to F of
the round-7 brief; lead commit 74e5bf9 added `spike/lib/runner.pl` to the owned files).

## Summary
Every earlier break came from bash reasoning about path strings or from a helper found on PATH. Round 7 removes both. ONE Perl
helper, `spike/lib/runner.pl`, is started only as `/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C SPIKE_IN_x=... /usr/bin/perl
runner.pl <subcommand> ...` (constant absolute paths; every argument follows the interpreter path, so `env` cannot read one as
`VAR=value`; shebangs are `#!/bin/bash`). In one process it resolves a command physically (lstat walk, no control characters
accepted or returned), compares (device, inode) of every directory and the file against the CLI homes of BOTH the
password-database home and an absolute `$HOME`, opens the file once (`O_NOFOLLOW`), copies from that descriptor into a private
0700 directory it creates itself, runs the fixed codesign on the copy, records the copy's sha256, re-hashes it before every
status run, and runs commands as a process-group leader whose in-group watchdog survives a SIGKILL to the caller's group.
`common.sh` keeps thin wrappers with the same public names and exit codes. The suites gained a structural sandbox guard.
Built for macOS `/bin/bash` 3.2 and the macOS system perl; only GNU bash 5.2 / perl 5.38 on Linux was run here.

## Files changed
- spike/lib/runner.pl - NEW. The helper: `resolve`, `magic`, `clihome`, `tool-path`, `gate`, `run`, `register`, `vdir-create`,
  `vdir-sweep`, `vdir-remove`. Core modules only (POSIX, Fcntl, Errno, Cwd, Digest::SHA). The codesign path and the pinned team ids
  now live here. Loaded with `require` (by a test) it only defines its functions.
- spike/lib/common.sh - rewritten tail: thin wrappers (`spike_resolve_path`, `spike_magic_ok`, `spike_under_cli_home`,
  `spike_run_timeout`, `spike_run_live`, `spike_run_status`, `spike_run_timed`, `spike_mark_verified`) plus new
  `spike_register_cli`, `spike_tool_path`, `spike_verify_init`, `spike_verify_dir`, `spike_verify_cleanup`. `spike_cleanup`
  refuses control characters and resolves through the helper. Removed: `spike_set_verify_dir`, `spike_verify_signer`,
  `spike_pinned_team`, `CODESIGN_BIN`, the `_spike_*` shape/identity/resolve functions, the bash watchdog.
- spike/preflight.sh - one `spike_register_cli` call per CLI; no `file`, `cp`, `mktemp`, `perl` or `dirname` on a security path; jq and git
  probed through the helper; TERM/INT/HUP end through `exit` so the EXIT trap removes the private directory.
- spike/tests/test_common.sh - rewritten for the new design, plus the sandbox guard and the regressions below.
- spike/tests/test_preflight.sh - rewritten likewise (wrapper scripts instead of symlinks, no `file` fake, new scenarios 8c, 12, 13, 14).
- spike/README.md - helper, process-group promise (now exact), identity checks, exit codes, fixtures note.
- HANDOFF.md - this file (stale HOST DAMAGE notes removed: the lead repaired the host with an apt reinstall; dpkg verify clean).
- spike/.gitignore - unchanged.

## Tests run
Environment: GNU bash 5.2.21, perl 5.38.2 (system), Linux, root, jq and git present, no real provider CLI, no real codesign, no
SPIKE_LIVE set by hand (the suites set it only for fixture runs of fake commands). PATH was pinned to `/usr/bin:/bin` in every probe
and in both suites (the real `claude` directory was never on it). The host-file hash
(`sha256sum /usr/bin/* /bin/* | sha256sum`) was recorded before the first run and compared after every suite run: unchanged each time.
- `bash -n` on the four shell files: clean. `/usr/bin/perl -c spike/lib/runner.pl`: syntax OK.
- `/bin/bash spike/tests/test_common.sh`, three sequential runs on the final code: 561 passed, 0 failed each (rc 0).
- `/bin/bash spike/tests/test_preflight.sh`: 141 passed, 0 failed (rc 0).
- `spike/preflight.sh` under `env -i PATH=/usr/bin:/bin` with a scratch HOME/TMPDIR: table printed, rc 0, nothing left in TMPDIR.
- `make -s check-fast`: pass (compliance scan clean; no app stack yet). The spike suites are not wired into it yet (lead follow-up).
- NOT RUN: macOS `/bin/bash` 3.2 and the macOS system perl (human to run both suites and `spike/preflight.sh` on the Mac before
  merge), real `codesign` on a real Mach-O, real claude or codex, shellcheck (not installed), mutation checks (an attempt to mutate
  the shipped checks in place was refused by the auto-mode classifier, so none were run this round).

## Hard rules touched (rule numbers + the test that proves each)
- Rule 1: the gate is enforced twice (`gate` verdict, then again inside `run`): all `gate: ...` denied cases, the `identity: ...` shadow-copy
  cases, `reviewer repro ...`, `PATH TOCTOU ...`, `spike_run_timed refuses a provider CLI name / argument / shell`.
- Rule 2: no config-home variable is named anywhere in spike/ (`make -s check-fast`).
- Rule 3: children are headless (stdin /dev/null, outfile); no PTY code.
- Rule 4: `CLI home: ...` (each of the seven entries built from parts, symlink to HOME, `..` spelling, symlinked entry, hard link,
  unresolvable fails closed), `candidate homes ...` (the password-database home is kept when HOME is unset, relative, `/`, has a control
  character or points away), `scenario 8 / 8b / 8c` (canary through a symlink, the Mach-O exception, a hard link), `the helper refuses to create
  the verify directory inside a CLI home`, `spike_run_timed refuses file(1) on a canary / hard link`.
- Rule 6: `registration refused: ...` (six signer modes x three assertions, wrong CLI name, ELF, script, dash), `registered binary passes ...`,
  `a registered copy swapped after registration is refused`, `fake perl on PATH ...`, `scenario 2 / 2b / 2c-2f / 6 / 7 / 11 / 12`.

## Round 7 (structural): decision -> implementation -> tests
A. One perl helper, by absolute path.
   - Implementation: `runner.pl` (above). `common.sh` calls it only through `_spike_helper` / `_spike_exec`:
     `/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C "${_SPIKE_IN[@]}" /usr/bin/perl "$SPIKE_HELPER" <subcommand> "$@"`. The assignments all
     precede the constant interpreter path, so no later argument is parsed by env (documented; the `=` regression proves it). The caller's
     PATH/HOME/TMPDIR/LANG/TERM/USER/LOGNAME/SPIKE_LIVE arrive as `SPIKE_IN_*`; the helper copies them and clears %ENV. `@INC` is reduced to
     absolute entries before any `use`. Resolve: lstat walk, `readlink`, at most 40 links, `..` pops a physical stack, only the final component
     may be missing; a trailing slash, a final `.`/`..` or any control character (input, link target, output) is refused. Registration
     (`register`): open once, `fstat` regular, same (dev, ino) as the lstat, link count 1, first four bytes read from that descriptor, copy from
     that descriptor to `<vdir>/<cli>` (0700, O_EXCL), sha256, codesign on the copy (pipe capture, no temp file), re-hash, registry line
     `sha256 TAB cli TAB copy`. `gate` / `run` apply the ungated identity rules (system dirs, exact shapes, launcher list, provider names in
     arguments, codesign shape + rooted in the helper-made verify directory) on the resolved path.
   - Tests: `fake perl on PATH ...` (test_common) and scenario 12 (preflight), `a command path containing = runs ...`, `shebang is /bin/bash ...`,
     `common.sh starts no program named perl by name`, `no shipped script uses env to find an interpreter`.
B. In-group watchdog.
   - Implementation: `run` does `setpgid(0,0)`, blocks TERM/INT/HUP, installs handlers, forks the command into that group, then polls every 50 ms
     for exit, timeout (POSIX::times ticks; 1..3600, decimal), TERM/INT/HUP and a changed parent pid (the caller died). Sweep: ignore the
     signals, TERM the group, move the helper into a throwaway group (`leave_group`, so the final KILL cannot hit it), 0.3 s, KILL the group;
     status 124 / 143 / 130 / 129, or the command's own. `_spike_exec` starts the helper as a plain background command so its parent is the
     calling shell, forwards TERM/INT/HUP, and restores the caller's traps.
   - Tests: `process group: ...` (setsid caller, `kill -9 -- -PGID`, launcher and grandchild gone within 3 s; the command is not in the caller's
     group; SIGKILL to the helper's group kills the command), plus the retained SIGTERM/SIGHUP, orphan (kill -9 caller), leaver, timeout,
     closed-set and stress blocks.
C. Test sandbox guard.
   - Implementation: `set -o noclobber`; `sbx_put` (refuses a relative path, a physical parent outside `$SANDBOX`, an existing symlink, a link count
     above 1; refusals are logged to a file because writers run in pipelines, and the suite then fails), `sbx_ln` (`ln -sfn`), `sbx_cp`,
     `sbx_mkdir`; `mkbin` writes wrapper scripts (`exec /usr/bin/X "$@"`); an EXIT tripwire hashes the host tools (test_preflight: every tool
     mkbin wraps and the ones it runs; test_common: a fixed list of the host tools it runs); `spike_cleanup` on `/` and the real `$HOME` runs with
     `rm` shadowed by a recorder, plus decoy-home variants inside the sandbox. Fake codesign fixtures decide the team from the basename of the LAST
     argument (and, in test_common, a `signer:` marker in the target's content), never from the whole command line.
D. Regressions: Opus 1 `fake perl on PATH`; 2 `process group`; 3 `trailing newline` (resolver, run_live, mark_verified, registry-line injection,
   cleanup); 4 `containing =`; 5 `hard link` (CLI-home test, registration, preflight scenario 8c, probe arguments); 6 `verify directory` (variable
   pointed at a CLI home, look-alike inside a home, TMPDIR inside a home, world-writable TMPDIR, `spike_set_verify_dir` gone); 7 the guard itself;
   8 `timeout 08 / 010 / 0005 / 0 / 3601 / ...`; 9 `TERM during a registration` (test_common) and `scenario 13` (preflight TERM: no `spike-verify.*`,
   no scratch file, the command is gone); 10 `scenario 14` and the `spike_run_timed` closed-environment tests. Sonnet: `candidate homes` tests,
   `a registered copy swapped after registration is refused`, fake codesign basename matching.
E. bash 3.2 / macOS perl: only syntax and builtins that 3.2 has (no `+=`, no associative arrays, no `${!x}`, arrays never expanded empty); the perl
   code avoids post-5.18 features (`/r`, `say`, postfix deref). Not run on a Mac.

## Assertions changed or removed in round 7: 34 names gone or renamed (24 in test_common, 10 in test_preflight), none weakened without a reason
Found by comparing assertion names with 26cbcb4. Removed because the code they probed is gone (11):
- 6 direct tests of `_spike_signal` (`signal before/after the pid is known ...`): the bash watchdog is replaced by the helper's handler, installed
  before the fork, so there is no pid-recording window; behavior is covered by the stress block and `process group`.
- `item 6: the runner body's first statement replaces the TERM trap` (2 names): there is no runner body in bash any more.
- `spike_run_status refuses a registered copy whose name is a launcher` (3 names): a copy is named after the CLI, never after the source, so a
  launcher name cannot be registered. Replaced by `spike_run_status refuses the launcher-named ORIGINAL even after it was registered` (3 names).
Changed meaning or renamed (23):
- `CLI home: any other dot-directory of HOME is refused too (superset of the list)`, `a file under a dot-directory of HOME is refused`,
  `a dot-entry symlinked to an outside directory refuses that directory` (3 names): now exact-list assertions (round 6 refused every
  dot-directory; the list is the seven entries, so `~/.local/bin/claude` is now allowed). The symlinked-entry case is kept for a listed entry.
- `CLI home: HOME unset fails closed (refused)`: now `HOME unset: an unrelated path is judged by the account home` plus the `candidate homes ...`
  tests (the password-database home is always checked).
- `cleanup refuses / (rc)` and `cleanup refuses \$HOME (rc)`: merged into one assertion run with `rm` shadowed, plus a decoy-home variant.
- `jq --version needs the gate (jq left the ungated list, rule 1)`: renamed, same assertion.
- `caller: a signal before the runner exists is recorded for the handoff`: renamed `... before the helper exists ...`, same assertion.
- `gate: spike_run_status with a prompt` / `... with --version and extra args`: renamed `... (unregistered path)`; registered-copy variants added.
- Codesign-constant assertions (`the shipped common.sh keeps the fixed codesign path`, `sandbox copy points the codesign constant at the fake`,
  `the sandbox copy differs from the shipped common.sh only in the codesign constant`; 4 names across the two suites): now about `runner.pl`.
- `registration asked codesign about the copy path (verify)`: now checks the helper-made copy path `<vdir>/claude`; a new assertion checks the
  original path was never given to codesign.
- scenario 8: `no file(1) call names the canary`, `no cp call names the canary`, `the canary was not copied into the private directory`,
  `the only dd call that touches the canary reads four bytes` (4 names): replaced by `no file, dd or cp call was made at all` (preflight no
  longer calls any of them; the helper reads four bytes from the descriptor).
- scenario 1 and 8b: two log-line assertions renamed (wording only: the "round 6 note" became a header note).
- scenario 11: `a shell script named codex is NOT VERIFIED (not a Mach-O file)` is now `... is a launcher, not executed` (the helper classifies by `#!`,
  as scenario 3 always did; the fake `file` that said Mach-O is gone). The ELF assertion is unchanged.
Same name, different fixture or call (not listed one by one): every `spike_run_status` call passes `$SPIKE_VERIFIED_COPY`; `codesign rooted` uses a
verify directory made by the helper; the codesign shape tests call `codesign_shape` from the helper loaded as a library; scenario 3 no longer uses
the real `file`; the sweep scenario uses `spike-verify.*` names; all symlinks are made with `ln -sfn`.
Added: roughly 100 names in test_common and 28 in test_preflight (see D).

## Decisions I made myself
1. The copy path is `<vdir>/<cli>` (`<cli>.N` if taken) and `spike_run_status` accepts only that path; `spike_mark_verified` therefore sets
   `SPIKE_VERIFIED_COPY` and callers pass it on. The original path is never accepted.
2. Two-step command start: `gate` (verdict and resolved path; rc 0 ok / 1 needs live / 2 unresolved / 3 refuse) then `run` on the exact physical
   path, which re-enforces the policy in the executing process. A refusal at exec time returns 125, so helper-internal codes never collide with the
   gate's rc 3 that stops the script.
3. The CLI-home list is exact (the seven names, built from parts). A hard-linked regular file is refused wherever it lies (registration,
   `spike_under_cli_home`, probe arguments): a link count cannot show where a link leads, and enumerating a credential directory to find the target
   would itself touch it.
4. `spike_run_timed` is now a probe for `jq`, `git` and `file` only (closed environment, same watchdog, no provider names, no CLI-home arguments).
   It used to run any fixed tool by PATH name.
5. `file(1)` is no longer used by preflight; classification is a `#!` or Mach-O magic read from the opened descriptor.
6. A path that cannot be resolved fails closed in `spike_under_cli_home` (it used to be judged by string).
7. `exit(main(@ARGV)) unless caller;` lets tests load `runner.pl` as a library to unit-test pure functions (`candidate_homes`, `codesign_shape`,
   `codesign_rooted`); running it as a script is unchanged.
8. PATH is pinned to `/usr/bin:/bin` plus jq's directory in both suites.

## Open risks / questions
- Pinned team ids Q6L2SF6YDW (claude) and 2DC432GLL2 (codex) are taken from this Mac's installed binaries and are NOT confirmed against
  vendor-published values. HUMAN ACTION before release. A vendor re-sign under another team fails closed (UNTRUSTED).
- A SIGKILL sent to the helper process ALONE (by pid) can leave the command running; a SIGKILL to the helper's group or to the caller's group
  cannot. The README says so. A same-account process that can write the private directory, the install directory or the registry is outside the model.
- Residual race: between the hash check and the exec of a status run there is a few-millisecond window inside a 0700 directory of the same account.
- A CLI that finds its own resources relative to its installed location may not run from the private copy. The row then says "needs human review"
  (never a fallback). Must be checked on the Mac with the real claude and codex.
- Case-insensitive and firmlink spellings are handled by (dev, ino) but could not be exercised on Linux; the human should run both suites on the Mac.
- The explicit CLI-home list still lives in code (built from parts); the list belongs in compliance/ (follow-up for the lead, shared file).
- The stress and signal tests have a timing history; they passed in every run of this round.
- shellcheck not run; macOS bash 3.2 and macOS system perl 5.18 not run; real codesign on a real Mach-O not exercised; no mutation checks.

## Confidence
Medium-high for the logic on GNU bash 5.2 / perl 5.38 / Linux: each Opus finding has a regression that fails on the 26cbcb4 behavior by design (fake
perl, group SIGKILL, newline, `=`, hard link, verify directory, octal timeout, TERM leak, env), though I did not run mutations to prove it. Medium-low on
the Mac (bash 3.2, perl 5.18, real codesign, real CLIs): not run.

## Follow-ups for shared files (lead)
- Makefile: add a `spike-test` target running `/bin/bash` on each `spike/tests/*.sh`, and include it in `check-fast`.
- .github/workflows/ci.yml: extend the shellcheck step to spike/ (`shellcheck -S warning spike/lib/common.sh spike/preflight.sh spike/tests/*.sh`);
  `spike/lib/runner.pl` can be checked with `perl -c`.
- compliance/: add a denylist file with the explicit CLI home list (rule 4) for the helper to read instead of the parts-built list. The scan's
  `TEXT_EXT_RE` does not include `.pl`, so `runner.pl` is not scanned at all; add `pl`.
- Later briefs (T-002, T-003, T-007) must start provider CLIs with `spike_run_live`, call `spike_require_live` first at top level, and (if they
  register) pass `$SPIKE_VERIFIED_COPY` to `spike_run_status`.
