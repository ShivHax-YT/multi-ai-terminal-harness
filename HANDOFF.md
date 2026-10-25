# HANDOFF T-002

## Summary
Added the Claude Code headless spike: run.sh (one `claude -p` stream-json run in a scratch worktree, turn cap 5, 120 s runner watchdog), resume.sh (one resume by session id) and parse.jq (summary of every event type, unknown types kept in `unknown`, malformed lines reported, free text only as bounded excerpts).
Both live scripts call `spike_require_live` first, register the CLI as a hash-verified private copy and start it only through `spike_run_live`; without SPIKE_LIVE=1 they exit 3 and do nothing.
EVENTS.md documents each event type from the official docs (all rows "from docs"; nothing observed yet). Fixtures are hand-written from those docs. The live run is the human's job; this branch never set SPIKE_LIVE and never ran the real binary.

## Files changed
- spike/claude/run.sh - one live run: register verified copy, scratch repo + worktree claude-1, spike_run_live, split output, parse, print summary
- spike/claude/resume.sh - one live resume of a capture's session id; reports id reuse and whether hello.txt has both lines
- spike/claude/parse.jq - event summariser (accepts raw text with -Rs or an array with -s; never fails on unknown or malformed input)
- spike/claude/EVENTS.md - table of every type/subtype with source, fixtures and a one-line example; limit and error shapes from docs; flag facts with sources
- spike/fixtures/claude/sample.jsonl - hand-written normal run
- spike/fixtures/claude/limits.jsonl - hand-written limit and error shapes
- spike/fixtures/claude/README.md - what the fixtures are and the pending observed.jsonl
- spike/tests/test_claude_parse.sh - offline tests (93 checks)
- HANDOFF.md - this file

## Tests run
- /bin/bash spike/tests/test_claude_parse.sh - 93 passed, 0 failed (session_id found; numeric usage; injected unknown/malformed lines handled; run.sh and resume.sh exit 3 without SPIKE_LIVE with a fake claude marker still absent; fixtures have no at-sign, /Users/ or /home/; EVENTS.md covers every fixture type/subtype)
- make -s check-fast - PASS (compliance scan clean)
- make -s spike-test - PASS: test_claude_parse 93, test_common 914, test_handoff 1039, test_plan 414, test_preflight 142, all with 0 failed
- scripts/ci/compliance-scan.sh - clean
- bash -n on run.sh, resume.sh and the test - clean
- spike/handoff/parse.sh --root of this worktree - parses this file, exit 0

## Hard rules touched
- Rule 1 - run.sh and resume.sh exit 3 without SPIKE_LIVE=1 and start no CLI (fake claude marker stays absent, no scratch repo or capture is created); one spike_run_live call per script, no loop or retry (static checks in test_claude_parse.sh); `--max-turns 5` plus a 120 s watchdog
- Rule 2 - no config-home variable is named anywhere in the owned files; the child gets the runner's closed environment (compliance scan, and a test greps the scripts)
- Rule 3 - only `claude -p` through spike_run_live; no PTY, no expect, no tmux send-keys (static test)
- Rule 4 - no credential path is read or named; resume.sh refuses a capture dir inside a CLI home; fixtures have no at-sign and no /Users/ (test greps)
- Rule 6 - the CLI runs only as the registered hash-verified copy (spike_register_cli, spike_run_live with the copy); an unverified or launcher-script claude is refused with exit 1 and nothing runs
- Rule 10 - no retry: on any error the scripts print the status and exit 1

## Open risks / questions
- Human live steps on the Mac (once each, no loops; do not re-run on an error, send me the output instead):
  1. Check out this branch. Run `spike/preflight.sh`. The claude row must say it is installed, verified and signed in. A launcher script (for example an npm shim) is refused by design; use the native binary install.
  2. Run `SPIKE_LIVE=1 spike/claude/run.sh` once. Expect `status: exited 0`, `hello.txt ok: yes`, and a summary with a session_id and numeric usage. It prints the capture directory.
  3. Run `SPIKE_LIVE=1 spike/claude/resume.sh <that capture dir>` once. Expect `session id reused: yes` (or no, which is a finding) and `hello.txt both lines: yes`.
  4. Redact and review: `/bin/bash -c '. spike/lib/common.sh; spike_redact' < spike/captures/claude/<timestamp>/raw.jsonl > spike/fixtures/claude/observed.jsonl`. Read the file by eye for anything personal, confirm `grep -c '@' ` and `grep -c /Users/` print 0, then run `/bin/bash spike/tests/test_claude_parse.sh`.
  5. Tell the lead which event rows in EVENTS.md appeared (so they change to "observed"), the unknown list from the summary, and any stderr.txt content. Then clean up: `/bin/bash -c '. spike/lib/common.sh; spike_cleanup <run dir printed by run.sh>'`.
- Unconfirmed until the live run: (a) `acceptEdits` alone is enough for the Write tool headless (docs say yes; if not, record what was needed, never bypass permissions); (b) the installed version accepts `--max-turns` (docs say print mode only); (c) a resumed run keeps write permission (the script passes acceptEdits again); (d) the session id is the same on resume; (e) how the human-readable limit text ("You've hit your session limit") appears in stream-json is not in the docs, so only structured fields are used for limit detection.
- Deviation from the brief: resume.sh puts the prompt before `--resume <id>` (the form in the headless docs) and adds `--permission-mode acceptEdits --max-turns 5`; the brief's sketch had neither.
- The T-001 runner writes the child's stdout and stderr to the same output file, so run.sh splits afterwards: JSON-object lines go to raw.jsonl, other lines to stderr.txt. A stderr line that is itself a JSON object would land in raw.jsonl (parse.jq would then list it under unknown). If CLI stderr and stdout interleave mid-line, such a line is reported as malformed, never fatal.
- Rule 6 limitation: the runner executes a private COPY of the binary. A claude that needs files next to itself may not start from the copy (exit 126 or 127, reported as "needs human review", no fallback to the original path).
- Follow-ups for shared files (lead): (1) spike/lib: add an option for a separate stderr file and one for the child's working directory to spike_run_live (workaround now: `cd` to the worktree before the call, and a post-hoc split); (2) spike/README.md: change the script index row for claude/* and tests/test_claude_parse.sh from planned to done (T-002); (3) no Makefile change is needed, `make spike-test` already globs spike/tests/*.sh.

## Confidence
medium, the parser and gates are covered by 93 offline checks and the other suites still pass, but every event shape is from docs and the live path (registration, runner, flags, resume) has never run against the real CLI.
