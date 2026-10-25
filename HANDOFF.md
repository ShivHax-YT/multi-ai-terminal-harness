# HANDOFF T-006

## Summary
Round 4 of T-006 (worker HANDOFF format and parser). The input is opened once, by perl sysopen with O_NOFOLLOW and O_NONBLOCK; a symlink, a hard link, a FIFO or any non-regular file is refused at open and nothing is copied. Only the handle that was checked is copied, which closes the hard-link blocker and the check-then-read race.
UTF-8 is checked by perl's strict decoder (iconv is dropped), the invisible-character blocklist is wider, and INT, HUP and TERM remove the temp dir and print nothing. The round 3 behavior (exit 3 for internal errors, ASCII-only JSON) is unchanged.

## Files changed
- docs/spec/handoff.md - format spec: single no-follow open, parent-directory rule, remaining race, strict UTF-8, character table, exit codes
- spike/handoff/parse.sh - parser: perl sysopen with O_NOFOLLOW, perl strict UTF-8 and blocklist, cleanup and signal traps, output printed last
- spike/tests/test_handoff.sh - offline checks: 343 (round 3 had 260), new round 4 block, one source guard replaced by stronger checks
- HANDOFF.md - this file

## Tests run
/bin/bash spike/tests/test_handoff.sh - 343 passed, 0 failed (run 3 times, Linux, GNU bash 5.2)
/bin/bash spike/tests/test_handoff.sh on the round 3 tree, before any change - 260 passed, 0 failed
mutation check on scratch copies, one protection removed per copy: no O_NOFOLLOW (11 failed), no O_NONBLOCK (3 failed), no INT trap (1 failed), no link-count check (2 failed), no parent-directory check (5 failed), no strict decoder (12 failed), no FE00-FE0F range (4 failed), no E0000-E0FFF block (10 failed)
bash -n spike/handoff/parse.sh and bash -n spike/tests/test_handoff.sh - clean
make -s check-fast - PASS (compliance-scan clean; no app stack yet)
manual perl checks: the code point bytes for every new range, and the strict decoder on f5, f4, f8, c0, ed and f0 forms
macOS /bin/bash 3.2: not re-run this round, human to run

## Hard rules touched
- Rule 4 (never touch CLI credentials; the parser never reads outside the worktree) - round 4 block: "symlink as the last component is refused (rc)", "symlinked parent directory is refused (rc)", "hard-linked file outside the sandbox root is refused (rc)", "FIFO input is refused without blocking", "a '..' component in the input path is refused (rc)"; canary text never appears in output or in TMPDIR
- Security (ARCHITECTURE.md, worker output is untrusted) - injection tests unchanged (payloads verbatim, marker file never created); strict UTF-8 tests; invisible-character tests; signal checks (INT, HUP, TERM); source guards "input path is named in exactly one code line", "the input path is not a shell redirect", "the open is sysopen with O_NOFOLLOW and O_NONBLOCK"
- Rule 9 (indirectly) - n/a in Phase 0

## Open risks / questions
- Remaining race (documented in the spec, not closed): a process that can write to the worktree could swap a parent directory for a symlink between the directory check and the open. The caller must parse only after the worker's whole process tree has exited. The scheduler has to enforce that; this is a follow-up for the lead.
- A relative input is checked through the shell's logical working directory, so a parser run from a symlinked directory refuses relative paths. Callers pass absolute paths (documented in the spec).
- Encode's strict decoder also refuses noncharacters (U+FDD0-U+FDEF, U+xFFFE, U+xFFFF). That is stricter than RFC 3629 and is documented in the spec.
- perl is now a required tool (preinstalled on macOS and Linux). iconv is neither used nor required. No shared-file change is needed for this task.
- macOS /bin/bash 3.2 and the BSD userland were not exercised this round. Human to run `/bin/bash spike/tests/test_handoff.sh` on macOS before merge.
- The signal checks use a 2 s fake perl and take about 7 s in total.
- This file is written in the six-section format so the same parser can read it. The round 4 mapping is a `###` subsection below, because a `## Round 4` heading would be an unknown section.

### Round 4
Each finding, its fix and the test that proves it. Test names are from spike/tests/test_handoff.sh, round 4 block.
- Hard-link blocker (rule 4): a link count other than one is refused, checked on the open handle. Tests: "hard-linked file outside the sandbox root is refused (rc)", "a hard link whose other name is also inside the sandbox is refused (rc)".
- Check-then-read race: the separate -L and -f checks and the head read are replaced by one perl sysopen (O_NOFOLLOW, O_NONBLOCK, O_NOCTTY), an fstat of that handle, and a copy of at most 16385 bytes from it. Tests: "symlink as the last component is refused (rc)", "symlink refused at open: the message comes from the open", "dangling symlink is refused at open (rc)", "FIFO input is refused without blocking", "a directory is refused (rc)", "/dev/null is refused (rc)".
- Symlinked parent directories: pwd -L is compared with pwd -P before the open, and a '..' component is refused. Tests: "symlinked parent directory is refused (rc)", "relative path through a symlinked parent is refused (rc)", "a '..' component in the input path is refused (rc)".
- Remaining race on parent directories: documented in the spec (parse only after the worker's process tree has exited). "refused before any read" is now "refused at open; nothing is copied" in the spec, the parser messages and this file. Documentation change, no test.
- Strict UTF-8 (iconv dropped, perl Encode strict): tests "strict UTF-8: f5 80 80 80 (lead byte F5)", "strict UTF-8: f4 90 80 80 (above U+10FFFF)", "strict UTF-8: 5-byte form f8 88 80 80 80", "strict UTF-8: overlong c0 af", "strict UTF-8: surrogate ed a0 80", "strict UTF-8: overlong 4-byte f0 80 80 80", "iconv is no longer used by the parser".
- Invisible characters: FE00-FE0F, E0000-E0FFF, 180B-180F, 3164, 2800, FFA0, 115F, 1160, 17B4 and 17B5 are refused, one test per range (for example "U+FE00-VS1 (FE00-FE0F range) in Summary", "U+E0100-VS17 (E0000-E0FFF block) in Summary", "U+3164-HANGUL-FILLER in Summary", "U+17B5-KHMER-VOWEL-INHERENT-AA in Summary"). Near misses stay accepted: "U+FE10 (outside FE00-FE0F) is accepted", "U+E1000 (outside the E0000-E0FFF block) is accepted", "U+1F600 emoji is accepted".
- Signals and cleanup: the trap is installed before mktemp and the rm is guarded on WORK being non-empty; INT, HUP and TERM exit 130, 129 and 143 through the EXIT trap. Tests: the INT, HUP and TERM checks in the round 4 block (temp dir empty, stdout empty, marker reached).
- Exit 3 for more internal errors: "a failing jq (building the JSON) is exit 3", "a failing awk (line length check) is exit 3", "a failing perl open and copy is exit 3", "a failing perl character check is exit 3". Exit 2 for a missing tool: "perl missing is a missing-tool error (exit 2)", "jq missing is a missing-tool error (exit 2)".
- Output is built in a temp file and printed last, so an interrupt before that point leaves stdout empty. No separate test; the INT check covers the interrupt path.
- Source guard "parser opens the input path exactly once" (a count of the `<"$file"` redirect) is replaced by three checks: the input path is named in exactly one code line, that is not a redirect, and the open is sysopen with O_NOFOLLOW and O_NONBLOCK. The behavior tests above are the stronger check.

## Confidence
medium, the Linux suite passes three runs and each removed protection makes it fail, but macOS bash 3.2, the BSD userland and macOS perl were not exercised this round.
