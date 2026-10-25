# HANDOFF T-006

## Summary
T-006 (worker HANDOFF format and parser), round 8 (final polish) on top of the round 7 structure: `parse.sh --root <worktree>` reads exactly <root>/HANDOFF.md in ONE perl process (env -i, walk from /, one open, in-memory checks, JSON printed once at the end).
Round 8 changes: the provider CLI home names now come from compliance/denylist.txt, read by perl at run time (fail closed with exit 3 if missing, empty or malformed; no names built from parts any more); a CLI home is refused by identity BEFORE the chdir into it; the spec no longer over-claims on mounts; the wrapper runs in bash privileged mode and perl runs with -f.
New tests cover each change (counts below); this file says plainly which checks are defence in depth only.

## Files changed
- docs/spec/handoff.md - round 8 spec: denylist file rule, check before chdir, honest mount section (two out-of-scope cases), all worker processes (setsid descendants included), defence-in-depth list, shebang and perl -f
- spike/handoff/parse.sh - denylist loader, CLI check before chdir, perl -f, bash -p shebang, symlink-to-script refusal, __DIE__ re-throws inside eval
- spike/tests/test_handoff.sh - names iterated from the denylist; chdir logger, strace, leaf-identity mount, O_NOFOLLOW seam, exit-3 seam, denylist failure matrix, wrapper hardening tests
- HANDOFF.md - this file

## Tests run
/bin/bash spike/tests/test_handoff.sh - 1039 passed, 0 failed, three runs of about 42 s each (Linux, GNU bash 5.2, perl 5.38.2, root; mount, mknod and strace usable, so nothing was skipped)
make -s check-fast - PASS (compliance-scan clean; no app stack yet)
scripts/ci/compliance-scan.sh - clean
bash -n spike/handoff/parse.sh and bash -n spike/tests/test_handoff.sh - clean
spike/handoff/parse.sh --root "$(pwd -P)" - parses this file (checked after it was written)
Mutation check (scratchpad copies, not committed), each applied alone: removing the check before the chdir, O_NOFOLLOW on the leaf, the lstat/open identity check, O_NOFOLLOW on the denylist, the "no entry" check of the denylist, perl -f, or the die @_ if $^S rethrow each made the suite fail.
Mutants that SURVIVE (no test fails): the post-open fstat regular-file check, the post-open fstat link-count check, the CLI identity check after the chdir, the getcwd check after the leaf lstat checks, and the post-read consistency check. They are defence in depth (see Open risks).
Not run: macOS /bin/bash 3.2, macOS system perl, BSD tools; mount, mknod and strace tests print a NOTE and skip where not usable. Human to run /bin/bash spike/tests/test_handoff.sh on macOS before merge.

## Hard rules touched
- Rule 4 - CLI homes by identity, names from compliance/denylist.txt: tests "CLI home $n as the root", "a directory inside CLI home $n", "... HOME elsewhere / unset / relative / empty, account home is the fake home" for EVERY entry of the file (the suite iterates the file, 7 entries), "the real parser must refuse the denylist entry $n as the root", "HOME as a symlink", "a CLI home that is a symlink", "a bind mount of a CLI home itself under another path is refused"
- Rule 4 - never entered: "CLI home $n as the root: NEVER entered (no chdir to $n)" and "inside CLI home $n: no chdir ..." (chdir logger seam, every entry), and the strace checks "there is no chdir syscall into the CLI home" (extra); source-order guard "no chdir happens before the CLI home check in the walk"
- Rule 4 - leaf identity: "a CLI JSON file bind-mounted onto HANDOFF.md is refused by identity" with control "an ordinary file bind-mounted onto HANDOFF.md parses"
- Rule 4 - the list is the file and fails closed: "denylist missing / directory missing / empty / comments only / is a directory / symbolic link / FIFO / larger than 64 KB / one malformed entry [..] (15 lines) / NUL / high byte" all exit 3 with one fixed message; "a custom denylist entry (comments, CRLF, tabs) is read at run time and refused"; "a real entry that is absent from the layout's denylist is not refused: nothing is built in"; "a symbolic link to parse.sh is refused (rc 3)"
- Rule 4 - nothing outside the root is read, unchanged: swap, lie, move-out probe, race tests (200 runs, no outside canary)
- Security (worker output is untrusted) - injection fixture tests, hostile root names, source guards, env tests, plus new: "run directly with BASH_ENV set / an exported function / SHELLOPTS=xtrace" (controls prove the markers can appear), "this perl accepts -f", "strace: perl is started with -f"
- Rule 9 (indirectly) - n/a in Phase 0

## Open risks / questions
- Out of scope, by decision of the lead: a concurrent process running as the same user can race or ptrace the parser. Precondition for the scheduler: ALL of the worker's processes have exited (descendants that called setsid included), been killed if needed, and been reaped before parse.sh runs; Phase 4 worker sandboxing is the control. The race tests only show that a lost race never printed the outside canary in 200 runs.
- Out of scope, named in the spec (needs mount privilege): a bind mount of an outside file onto HANDOFF.md on the same filesystem, and a bind mount of a subdirectory of a CLI home (or of a file inside one) at another path. Only the CLI home directories and the denylisted entries themselves are known by identity. A bind of the home itself, and a denylisted file bound onto HANDOFF.md, are refused and tested where mount works.
- DEFENCE IN DEPTH ONLY (mutants survive, no test would fail without them): the fstat checks on the open handle for type and link count (the lstat checks before the open refuse the same input), the CLI identity check after the chdir (the check before the chdir refuses first), the getcwd check after the leaf lstat checks, and the post-read consistency check. The fstat identity-against-lstat check is covered by the lstat lie test. The spec says the same.
- bash -p only applies when parse.sh is executed directly; "bash parse.sh" bypasses the shebang and bash has read BASH_ENV by then. The scheduler must exec the script. A symbolic link to parse.sh is refused (exit 3) because the repo layout is found from the physical location.
- perl -f: accepted by this perl; it is documented for perl 5.8 and later and is a no-op on a perl built without sitecustomize (as here), so the macOS perl should accept it. Not run on macOS.
- Case-insensitive filesystems (APFS default): the root is compared with what getcwd reports, so a root typed with different letter case is refused (fails closed). Not tested on macOS.
- Decisions I made (lead to confirm): denylist entries that are only dots (".", "..") are refused as malformed in addition to the regex; the comment rule strips from the first "#" to the end of the line, so inline comments work; CR at line ends is tolerated; the denylist file size limit is 64 KB; a symlinked parse.sh is exit 3; the sandbox copy of the parser in the tests lives in a copy of the repo layout so the denylist lookup is the real code path; bash -p was chosen over unsetting variables because functions cannot be removed from inside the script reliably (a function can shadow unset itself).
- The lead must still check that files_changed paths are inside the worker's owned files and that task_id is the dispatched task. No shared-file change is needed for this task.

### Round 8 (polish)
Finding -> fix -> test name.
- CLI check after the chdir only -> the lstat identity of the next component is checked before the chdir, the check after it stays -> "CLI home $n as the root: NEVER entered", "inside CLI home $n: no chdir to $n and none to sub", strace "there is no chdir syscall into the CLI home", source-order guard; refusal message asserted.
- Names built from parts -> compliance/denylist.txt read at run time, located from the script's physical directory, path passed in @ARGV, O_NOFOLLOW, regular file, 1 to 65536 bytes, exit 3 on any problem -> the denylist failure matrix above, "the suite iterates the file", "the denylist file is opened with O_NOFOLLOW", strace "the denylist is opened with O_NOFOLLOW".
- Spec over-claimed on mounts -> two out-of-scope cases named; "bind of the home itself is refused" kept because it is tested -> spec checks "bind mount of an outside file", "subdirectory of a CLI home".
- Leaf identity untested, CLI-CANARY-JSON fixture unused, stale comment -> the JSON entry bound onto HANDOFF.md is refused (fixture now used), stale comment removed -> "a CLI JSON file bind-mounted onto HANDOFF.md ...". A file inside a CLI home directory bound onto HANDOFF.md is NOT recognised (only the directory inode is known); that is the out-of-scope case (b), so there is no test asserting a refusal for it.
- O_NOFOLLOW proved only by a source grep -> behavioural seam: HANDOFF.md is a symlink, the lstat lies, the parser refuses "at open" -> "symlink HANDOFF.md with a lying lstat: refused AT OPEN", control "the honest lstat refuses before the open"; the grep stays as an extra.
- Precondition said process group -> "all of the worker's processes ... setsid" in the spec -> spec checks.
- Nits: __DIE__ handler starts with die @_ if $^S (source guard + mutant), exit-3 path -> "an unexpected die inside the parser is exit 3" (+ fixed message, not echoed); perl -f -> strace check; bash -p shebang + unset BASH_ENV ENV -> the wrapper hardening tests; defence-in-depth list -> this file and the spec.
- Changed assertions: the six per-name CLI home loops now iterate the file (seven entries, so the JSON entry is also tested as a root, which the old code could not); descriptions "the codex home" and "the Claude home" became "a CLI home" or "the first/last denylist entry"; the exec pattern and the "HOME is passed as data" grep now include perl -f and the denylist argument; "the leaf is opened exactly once" now matches sysopen($in (two sysopen calls in all); the sandbox copy lives in a repo layout (the "exactly the two seam lines" assertion is unchanged). Count: 901 -> 1039.

## Confidence
medium: three runs pass with 1039 checks, every round 8 item has a behavioural test and the mutation check kills the ones that matter, and the compliance scan is clean. The survivors are named and are defence in depth. macOS bash 3.2, macOS perl and BSD tools are not run, the race tests are weak evidence, and the same-user concurrent process and mount-privilege cases are out of scope, not fixed.
