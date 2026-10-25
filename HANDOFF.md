# HANDOFF T-006

## Summary
Round 5 of T-006 (worker HANDOFF format and parser), the fix for the round 4 blockers on hard rule 4. The parser now requires --root and resolves the input in one perl process: every parent is lstat'ed, entered and identity-checked, and the leaf is opened with O_NOFOLLOW relative to the verified directory, which closes the parent-directory swap race.
Also: paths outside the root and '.', '..' or empty components are refused; Cf characters and noncharacters are refused explicitly and through perl's \p{Cf}; a reason made only of separators is refused on any line; QUIT exits 131; a failing tr, wc, awk or jq is exit 3.

## Files changed
- docs/spec/handoff.md - format spec: required --root and input rules, identity-checked walk, Cf and noncharacter table, usage and exit codes
- spike/handoff/parse.sh - parser: --root, one perl walk (lstat, chdir, identity check, leaf open), Cf and noncharacter refusal, confidence reason check, exit and signal fixes
- spike/tests/test_handoff.sh - offline checks: 750 passed (round 4 had 343), round 5 block, round 4 call sites now pass --root
- HANDOFF.md - this file

## Tests run
/bin/bash spike/tests/test_handoff.sh - 750 passed, 0 failed (3 runs, Linux, GNU bash 5.2, perl 5.38.2 with Unicode 15.0)
make -s check-fast - PASS (compliance-scan clean; no app stack yet)
bash -n spike/handoff/parse.sh and bash -n spike/tests/test_handoff.sh - clean
spike/handoff/parse.sh --root "$PWD" HANDOFF.md - parses with the new parser (checked after this file was written)
mutation checks on scratch copies, one protection removed per copy: no parent identity check (race test passes, deterministic test 4 failed); reason check back to any text (4 failed); no Cf class and no listed ranges (82 failed); Cf class kept without the listed ranges (0 failed, expected: \p{Cf} covers them on this perl); no explicit noncharacter expression (66 failed); no QUIT trap (2 failed); no pipefail (1 failed); no lstat link-count check (2 failed)
race probe on scratch copies, 1500 runs each: real parser 0 canary leaks, parser without the identity check 10 leaks
macOS /bin/bash 3.2 and macOS system perl: not run, human to run /bin/bash spike/tests/test_handoff.sh on macOS before merge

## Hard rules touched
- Rule 4 (never touch CLI credentials; the parser never opens a file outside --root) - round 5 block: "an absolute path outside the root is refused (rc 1)", "a relative path with .. is refused (rc 1)", "a parent swapped after its lstat is refused (rc 1)", "race: 200 runs against a swapped parent directory, none printed the outside canary", "hard link refused before open: the lstat message says so", "a relative FIFO is refused without blocking"; the canary text is checked in every refusal
- Security (ARCHITECTURE.md, worker output is untrusted) - injection tests unchanged (payloads verbatim, marker file never created); strict UTF-8; "every \p{Cf} code point of this perl is refused"; "noncharacter U+... is refused by the regular expression alone"; signal checks (INT, HUP, QUIT, TERM)
- Rule 9 (indirectly) - n/a in Phase 0

## Open risks / questions
- Parent-directory race: closed by the walk (see Round 5). The caller-side "no concurrent writer" precondition is removed from the spec as a security requirement and kept as advice. Residual: a directory renamed out of the root after its lstat can still be read through the directory the process holds, which then reads only a one-link regular file inside it. That needs write access to both places, so it adds no power an attacker with that access lacks. Lead to decide whether to accept.
- The root and its parents are trusted: the caller chooses --root, and it is resolved once with pwd -P.
- The race test is probabilistic and weak on its own (see Round 5). The deterministic identity test is the real guard for the identity check.
- Cf: the explicit list now includes the code points the brief lists, so refusal does not depend on the perl's Unicode version. \p{Cf} adds the rest of the set of the perl that runs the check.
- A signal during the final cat can still truncate stdout (documented; the exit status names the signal, so callers treat non-zero as failed).
- macOS /bin/bash 3.2, the BSD userland and macOS perl were not exercised this round. Human to run the suite on macOS before merge.
- No shared-file change is needed for this task.

### Round 5
Each finding, its fix and the test that proves it. Test names are from spike/tests/test_handoff.sh (round 5 block unless noted).
- Parent-directory swap (reviewer repro, 9 in 300): the bash pwd check and the path open are replaced by one perl walk. Each parent is lstat'ed, refused if a symlink or not a directory, entered, and its (dev, ino) compared with the lstat. The leaf is lstat'ed (regular, one link), then opened with O_NOFOLLOW, O_NONBLOCK, O_NOCTTY relative to the verified directory. Tests: "race: 200 runs against a swapped parent directory, none printed the outside canary" (probabilistic); "a parent swapped after its lstat is refused (rc 1)" (deterministic: lstat overridden by a test-only module through PERL5OPT); round 4 "symlinked parent directory is refused (rc)" kept.
- Root required and input inside it: "--root is required (rc 2)", "--root that is not a directory is a usage error (rc 2)", "--root given twice is a usage error (rc 2)", "an absolute path outside the root is refused (rc 1)", "a file outside the root is refused (rc 1)", "/dev/null outside the root is refused (rc 1)", "a valid file inside the root passes (rc 0)", "a relative path is relative to the root, not the working directory (rc 0)".
- Dot and dot-dot components: "a relative path with .. is refused (rc 1)", "./-g.md is refused: a '.' component", "./-n.md is refused: a '.' component" (the ESC loop, round 4 name kept with the absolute path).
- Root given as a symlink, resolved once: "root given as a symlink: an input under its physical path passes (rc 0)", "root given as a symlink: an input under the logical path is outside the root (rc 1)", "root given as a symlink: a relative input resolves in the physical root (rc 0)".
- Hard link refused before the open: "hard link refused before open: the lstat message says so", "the lstat link-count check comes before the open in the source". Round 4 hard-link tests kept.
- FIFO by relative name: "a relative FIFO is refused without blocking (rc 1, not the alarm's 142)". A parent that is a regular file: "a parent that is a regular file is refused (rc 1)".
- Confidence reason of separators only on the next line (finding 4): fixed by reason_ok, which applies to the whole reason. Tests: "confidence: a next-line reason of '- .' is separators only", "... of ';' ...", "... of '-  ,' ...", "confidence: several separator-only lines are no reason"; accepted: "confidence: a next-line reason with a word is accepted".
- Format characters (finding 5): \p{Cf} is refused in the strict-decode step, plus the explicit list (which now includes the brief's 41 code points). Tests: "listed Cf code point U+... is refused" (41), "every \p{Cf} code point of this perl is refused: U+..." (170 on this perl), "the Cf sweep covered a real set". Spec table updated.
- Noncharacters (finding 6): an explicit expression for U+FDD0-U+FDEF and U+xFFFE, U+xFFFF in each plane. Tests: "noncharacter U+... is refused" (66), and "noncharacter U+... is refused by the regular expression alone" (66, with a lax Encode stub on PERL5LIB; the message names the expression, which proves the stub is in use), "with the lax stub a valid handoff still parses (rc 0)", near misses "U+FDCF (next to the noncharacters, not one) is accepted" and three more.
- Nits (finding 7): load_lines uses "local -a all" then "all=()" (bash 3.2 form). A failing tr or wc is exit 3: pipefail, every tool result checked. Tests: "a failing tr (NUL check) is exit 3, not a NUL refusal", "a failing wc (size check) is exit 3". QUIT is trapped like TERM and exits 131: "signal QUIT 131" and "QUIT is trapped like TERM (exit 131)". The final JSON is one cat of the prepared file: "stdout is written once, from the prepared file".
- Usage: "--root" is required; "two file arguments with --root is a usage error (rc 2)", "no file argument with --root is a usage error (rc 2)".
- Round 4 assertions were not weakened. Changed: the "./" tests (above), the description "symlink refused at open: the message comes from the open" (renamed "symlink refused before open: the message names the symbolic link"; same assertion), the source guard pattern for the open (now "sysopen($in, $leaf, ...)"), and the call sites, which now pass --root.

Decisions made in round 5 (lead to confirm):
- "./name" is refused as a '.' component, as the brief specifies, so the round 4 "./" assertions now assert the refusal. A dash-named file is still tested with "--" and with its absolute path.
- The 41 brief code points are in the explicit list too, not only in \p{Cf}. U+0890-U+0891 are Unicode 14 code points, so an older macOS perl would otherwise accept them.
- A missing or non-directory --root, and a repeated --root, are usage errors (exit 2).
- Relative inputs are relative to --root (round 4 used the shell's directory).
- The race test is probabilistic. A parser without the identity check leaked in 10 of 1500 runs, so N=200 would catch it about one time in four. The deterministic test is the guard. N=200 and the 30 s bound are kept as the brief asks.

Confidence: medium. The Linux suite passes three runs, each mutation above fails the test meant to catch it, and the real parser had no canary leak in 1500 race runs. macOS bash 3.2 and macOS perl are not run, the Cf set depends on the perl's Unicode version, and the race test alone is weak (the deterministic test is the guard).

## Confidence
medium, the Linux suite passes three runs, the mutation checks each fail the test meant to catch them, and the real parser shows no race leak in 1500 runs; macOS bash 3.2 and macOS perl are not exercised, and the probabilistic race test is weak on its own.
