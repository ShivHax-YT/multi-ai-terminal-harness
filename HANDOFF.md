# HANDOFF T-006
## Summary
Round 6 of T-006 (worker HANDOFF format and parser), the fix for the round 5 blockers: the root is no longer trusted and resolved with pwd -P. perl walks it from / component by component (a symlink anywhere in it is refused), then walks the parents and the leaf with identity and working-directory checks, on one device, refusing provider CLI homes before any open.
Also: empty, blank, relative and '.' or '..' roots are usage errors (exit 2); perl runs with PERL5OPT, PERL5LIB, PERLLIB, PERL5DB and PERL_UNICODE removed; the test seams run from a sandbox copy; the temp dir is created with signals ignored; leading blanks before the confidence level are tolerated.
The spec states what is guaranteed and what is a residual (same-user relocation into the root; Phase 4 sandboxing is the control).

## Files changed
- docs/spec/handoff.md - round 6 spec: walked root, identity and working-directory checks, device rule, CLI homes, env scrub, residual risk
- spike/handoff/parse.sh - one perl walk from /, Cwd::getcwd checks, device and CLI home refusal, env scrub, root usage errors, mktemp signal window, blanks before the level
- spike/tests/test_handoff.sh - round 6 block, sandbox copy for the seams, root-symlink assertions changed, cat instead of cp in setup
- HANDOFF.md - this file

## Tests run
/bin/bash spike/tests/test_handoff.sh - 843 passed, 0 failed, three runs (Linux, GNU bash 5.2, perl 5.38.2)
make -s check-fast - PASS (compliance-scan clean; no app stack yet)
bash -n spike/handoff/parse.sh and bash -n spike/tests/test_handoff.sh - clean
spike/handoff/parse.sh --root "$(pwd -P)" HANDOFF.md - parses (checked after this file was written)
Not run: macOS /bin/bash 3.2, macOS perl and BSD env. Human to run /bin/bash spike/tests/test_handoff.sh on macOS before merge (macOS /tmp and /var are symlinks; the tests use physical paths).
Environment note: /usr/bin/cp on this VM is a shell wrapper that execs its own path, so every cp loops forever. The test setup uses cat with a redirect instead of cp (same content for regular files). The wrapper is not fixed here.

## Hard rules touched
- Rule 4 - a root or input under a provider CLI home is refused before any open: "the codex home itself as the root", "an input in the codex home, under a valid root (absolute)", "CLI home claude under a valid root", "the Claude JSON file, with HOME as the root", "HOME as a symlink: the resolved CLI home is refused (rc 1)", "a symlink into the codex home is refused (rc 1)"; canary text checked in each refusal
- Rule 4 - no directory on the walk is read outside the root: "a parent swapped after its lstat is refused (rc 1)", "move-out probe through the seam (lstat lied): refused (rc 1)", "root swap: an absolute input through a symlinked root is refused (rc 1)", "race: 200 runs against a swapped parent directory, none printed the outside canary"
- Security (ARCHITECTURE.md, worker output is untrusted) - injection fixture tests unchanged; strict UTF-8 and noncharacter tests; env scrub: "PERL5OPT and PERL5LIB: the stub module never ran (no marker file)"
- Rule 9 (indirectly) - n/a in Phase 0

## Open risks / questions
- Residual (spec, "Residual risk"): a same-user process that renames directories or moves files into the worktree can put data inside the root. No path check stops that. Phase 4 worker sandboxing is the control; until then the caller parses only after the worker's processes have exited.
- A directory moved out of the root between its last check and the open can make the open reach a file outside the root. Only the open happens: the working directory is checked again before the first read, so nothing outside the root is read. Lead to decide whether to accept.
- Decisions made in round 6 (lead to confirm): a relative --root is a usage error (exit 2), not resolved from the caller's directory; "/" is a valid root; trailing and doubled slashes are accepted; HOME unset or relative is an internal error (exit 3), because the CLI home check cannot be made.
- Decision: the mktemp window ignores INT, HUP, TERM and QUIT for a few milliseconds, so a Ctrl-C in that window is dropped instead of running the trap. The alternative leaked the temp dir.
- Not scrubbed: PERLIO and PERL_HASH_SEED (only the five variables the lead listed). The data path uses sysread and syswrite, which bypass PerlIO layers; stderr messages are the only exposure.
- The lead must still check that files_changed paths are inside the worker's owned files (spec, Files changed).
- No shared-file change is needed for this task.

### Round 6
Each finding, its fix and the test that proves it. Names are from spike/tests/test_handoff.sh (round 6 block at the end of the file unless noted).
- 1 Blocker, root trusted and resolved once with pwd -P: the root is walked from / (lstat, refuse symlink or non-directory, chdir, device and inode compared, getcwd checked). Tests: "root swap: a relative input through a symlinked root is refused (rc 1)", "root swap: an absolute input through a symlinked root is refused (rc 1)", "root swap: the input through the replaced path is outside the moved root (rc 1)", "a symlink in the middle of the root path is refused (rc 1)", "root given as a symlink: an input under the logical path is refused (rc 1)".
- 2 Move-out probe (reviewer): a directory moved out with a symlink at its old name. The physical working directory must be the expected one after every step and after the open, and outside every CLI home. Tests: "move-out probe through the seam (lstat lied): refused (rc 1)" (message input path changed), "move-out probe, honest lstat: refused (rc 1)".
- 3 Empty root: "--root \"\" is a usage error (rc 2)", "a whitespace-only --root is a usage error (rc 2)"; relative and dot roots: "a relative --root is a usage error (rc 2)", "a '.' component in --root is a usage error (rc 2)", "a '..' component in --root is a usage error (rc 2)".
- 4 Same device: the root's final directory records its device; later directories and the leaf must match ("crosses a mount"). Tests: "/proc under --root / is refused (rc 1)" (Linux; a printed note otherwise), "/ as the root: an input on the same device passes (rc 0)" (or the refusal branch, with a printed note, when /tmp is on another device).
- 5 CLI homes (hard rule 4): the root and input strings are checked against the CLI homes under HOME, as typed and as resolved, before any open; the physical path is checked after each step and before the open. Names are built from parts, so the compliance scan stays clean. Tests: the home_refused block (six names, as root and under a valid root), "a near miss of a CLI home name (dot name with a suffix) is not refused (rc 0)".
- 6 Perl environment: every perl call runs as env -u PERL5OPT -u PERL5LIB -u PERLLIB -u PERL5DB -u PERL_UNICODE perl. The seams (lax Encode stub, lstat override) run from a sandbox copy with only that prefix removed. Tests: "PERL5OPT and PERL5LIB with a lax Encode stub: the real parser still refuses the noncharacter (rc 1)", "PERL5OPT and PERL5LIB: the stub module never ran (no marker file)", "control: the sandbox copy (scrub prefix removed) does load the stub", "every perl call in the parser carries the scrub prefix", "the sandbox copy changes exactly the scrubbed lines".
- 7 Nits: the temp dir is created with INT, HUP, TERM and QUIT ignored, and the traps are restored after mktemp (test "the temp dir is created with the signals ignored (ignore, then mktemp, then restore)"). Blanks before the confidence level are tolerated (tests "confidence: leading spaces before the level are tolerated", "confidence: a leading tab is tolerated", "confidence: leading spaces then 'highly' is still a bad level").
- 8 Spec honesty: "the spec no longer says the root is resolved once or trusted", "the parser does not resolve the root with pwd -P", "no chdir to the root by string".
- 9 Walk branches: "a missing parent directory is refused (rc 1)" (missing or cannot be read); "a parent the lstat shows as a directory but that cannot be entered is refused (rc 1)" (through the seam, since root bypasses chmod).
Changed assertions, all listed: (a) round 5 "root given as a symlink" (three assertions, rc 0 and outside root) now assert the walk refusal (rc 1, symlink not allowed), and the physical-path input gives outside root; (b) the lax-stub and lstat-override tests run the sandbox copy instead of the real parser (same assertions; the real parser now ignores PERL5OPT and PERL5LIB, by design); (c) eight setup cp calls became cat with a redirect (same content; environment issue above). No other assertion was changed or deleted.

## Confidence
medium: the Linux suite passes three runs with 843 checks, the round 6 block covers each lead item, and the compliance scan is clean. macOS bash 3.2, macOS perl and BSD env are not run, the mount probe depends on /proc or on /tmp sharing the root's device, and the same-user residual is accepted in the spec, not fixed.
