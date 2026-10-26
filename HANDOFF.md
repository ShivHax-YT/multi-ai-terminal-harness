# HANDOFF T-008
## Summary
Adds `spike_run_live_split`, the live runner with stdout and stderr in separate files, so T-002 and T-003 no longer
guess which lines are events. The errfile is opened by the same `open_outfile` helper as the outfile and an errfile
that resolves to the outfile (path or dev/inode) is refused. Also fixes two macOS-only test failures: recursive greps
hang on a FIFO under BSD grep (now `-D skip`), and BASHPID is missing in bash 3.2 (now `selfpid`).
## Files changed
- spike/lib/common.sh - spike_run_live_split and the _SPIKE_ERRFILE plumbing
- spike/lib/runner.pl - run-split subcommand through run_core; errfile under the outfile policy; identity refusal
- spike/tests/test_common.sh - split tests; grep -D skip; selfpid
- spike/README.md - runner section documents spike_run_live_split
## Tests run
- macOS (human): make check passes; test_common 986/0, test_handoff 1015/0, test_plan 414/0, test_preflight 141/0
- Linux (gates): /bin/bash spike/tests/test_common.sh 997 passed, 0 failed; make -s check-fast passes
## Hard rules touched
- 1: split gate without SPIKE_LIVE=1 gives rc 3 and starts nothing (test "split gate: without SPIKE_LIVE=1")
- 4: errfile symlink, hard link, FIFO and CLI-home parent refused, mode 0600 (tests "split: errfile ...")
- 6: only the registered copy runs through the split entry point (tests "split: registered copy ...")
## Open risks / questions
- A refused split run can leave the empty files it just created (identity check runs after both opens).
- Split tests cover TERM and HUP, not INT or the caller-SIGKILL watchdog; add them when the runner is ported (T-119).
- No runtime test for leaked fds; perl's close-on-exec keeps only fds 0-2.
- Gates: compliance-auditor PASS, Opus reviewer PASS, test-runner (see merge note).
## Confidence
high - both gates pass and the human's macOS run is green; the follow-ups are cleanup items.
