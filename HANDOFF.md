# HANDOFF T-002

## Summary
Second follow-up round: (A) run.sh and resume.sh now decide success with a `completion_verdict` function (CLI exit 0, parse.jq exit 0 captured as PARSE_RC, a result event with is_error exactly false, a usable session id; fixed reason strings, stream text never echoed; hello.txt is information only and cannot rescue a failure); (B) resume.sh reserves the resume with an atomic `mkdir "$CAP/resume.lock"` right before the run, never removed, so a capture is resumed at most once even with racing runs.
Reviewer follow-ups applied (this commit): hidden `--max-turns` documented; parse.jq guards array-typed type/subtype; capture files private (umask 077, no pre-create); resume.sh reports `unknown`, strips trailing slashes and handles rc 121; run.sh names the scratch run dir when setup fails; stdout split moved to split.jq; init-event personal config scrubbed by scrub-init.jq before a fixture is promoted; EVENTS.md lists five binary-only system subtypes.
Added the Claude Code headless spike: run.sh (one `claude -p` stream-json run in a scratch worktree, turn cap 5, 120 s runner watchdog), resume.sh (one resume by session id) and parse.jq (summary of every event type, unknown types kept in `unknown`, malformed lines reported, free text only as bounded excerpts).
Both live scripts call `spike_require_live` first, register the CLI as a hash-verified private copy and start it only through `spike_run_live`; without SPIKE_LIVE=1 they exit 3 and do nothing.
EVENTS.md documents each event type from the official docs (all rows "from docs"; nothing observed yet). Fixtures are hand-written from those docs. The live run is the human's job; this branch never set SPIKE_LIVE and never ran the real binary.

## Files changed
- spike/claude/run.sh - one live run: register verified copy, scratch repo + worktree claude-1, spike_run_live, split output, parse, print summary
- spike/claude/resume.sh - one live resume of a capture's session id; reports id reuse and whether hello.txt has both lines
- spike/claude/split.jq - splits the runner's combined output into raw.jsonl (JSON objects only) and stderr.txt (everything else); used by run.sh and resume.sh
- spike/claude/scrub-init.jq - replaces the system/init lists (mcp_servers, plugins, skills, slash_commands, agents, tools) with ["<redacted>"] plus counts; run before spike_redact when promoting a capture
- spike/claude/parse.jq - event summariser (accepts raw text with -Rs or an array with -s; never fails on unknown or malformed input)
- spike/claude/EVENTS.md - table of every type/subtype with source, fixtures and a one-line example; limit and error shapes from docs; flag facts with sources
- spike/fixtures/claude/sample.jsonl - hand-written normal run
- spike/fixtures/claude/limits.jsonl - hand-written limit and error shapes
- spike/fixtures/claude/README.md - what the fixtures are and the pending observed.jsonl
- spike/tests/test_claude_parse.sh - offline tests (237 checks)
- HANDOFF.md - this file

## Tests run
- /bin/bash spike/tests/test_claude_parse.sh - 237 passed, 0 failed (session_id found; numeric usage; injected unknown/malformed lines handled; run.sh and resume.sh exit 3 without SPIKE_LIVE with a fake claude marker still absent; fixtures have no at-sign, /Users/ or /home/; EVENTS.md covers every fixture type/subtype)
- make -s check-fast - PASS (compliance scan clean)
- make -s spike-test - NOT CLEAN in this sandbox: it stops in T-001's test_common.sh with "sandbox guard refused: no parent for <fake home file>" (an environment issue; that suite and spike/lib are untouched here); it passed in the original T-002 commit. test_claude_parse.sh alone passes (237). The test_common failure is the known macOS sandbox-guard bug that T-008 fixes
- scripts/ci/compliance-scan.sh - clean
- bash -n on run.sh, resume.sh and the test - clean
- spike/handoff/parse.sh --root of this worktree - parses this file, exit 0

## Hard rules touched
- Rule 1 - run.sh and resume.sh exit 3 without SPIKE_LIVE=1 and start no CLI (fake claude marker stays absent, no scratch repo or capture is created); one spike_run_live call per script, no loop or retry (static checks in test_claude_parse.sh); `--max-turns 5` plus a 120 s watchdog
- Rule 2 - no config-home variable is named anywhere in the owned files; the child gets the runner's closed environment (compliance scan, and a test greps the scripts)
- Rule 3 - only `claude -p` through spike_run_live; no PTY, no expect, no tmux send-keys (static test)
- Rule 4 - no credential path is read or named; resume.sh refuses a capture dir inside a CLI home (a trailing slash no longer slips past the symlink test); capture files are 0600 in a 0700 directory (both scripts set umask 077, the runner creates the files); fixtures have no at-sign and no /Users/ (test greps); personal init config is scrubbed by scrub-init.jq (tests with a synthetic personal init event, and a check on observed.jsonl once it exists)
- Rule 6 - the CLI runs only as the registered hash-verified copy (spike_register_cli, spike_run_live with the copy); an unverified or launcher-script claude is refused with exit 1 and nothing runs
- Rule 10 - no retry: on any error the scripts print the status and exit 1; the exit status comes from completion_verdict only (tests: one case per failure reason, a leak check that stream text never reaches the reason, source checks that PARSE_RC is captured right after parse.jq and that no exit depends on hello.txt); resume.sh refuses a second resume of the same capture with an atomic mkdir (tests: second and third reservation fail, 16 parallel racers give exactly one winner, the reservation line directly precedes the spike_run_live line)

## Open risks / questions
- Human live steps on the Mac (once each, no loops; do not re-run on an error, send me the output instead):
  1. Check out this branch. Run `spike/preflight.sh`. The claude row must say it is installed, verified and signed in. A launcher script (for example an npm shim) is refused by design; use the native binary install.
  2. Run `SPIKE_LIVE=1 spike/claude/run.sh` once. Expect `status: exited 0`, `hello.txt ok: yes`, and a summary with a session_id and numeric usage. It prints the capture directory.
  3. Run `SPIKE_LIVE=1 spike/claude/resume.sh <that capture dir>` once. Expect `session id reused: yes` (or no, which is a finding) and `hello.txt both lines: yes`.
  4. Scrub, redact and review: `jq -c -f spike/claude/scrub-init.jq spike/captures/claude/<timestamp>/raw.jsonl | /bin/bash -c '. spike/lib/common.sh; spike_redact' > spike/fixtures/claude/observed.jsonl`. The scrub step replaces the init event's mcp_servers, plugins, skills, slash_commands, agents and tools with ["<redacted>"] plus counts (personal config must not be committed). Read the whole file by eye for anything else personal (other event types could also name plugins, hooks or commands), confirm `grep -c '@' ` and `grep -c /Users/` print 0, then run `/bin/bash spike/tests/test_claude_parse.sh` (it fails if observed.jsonl still has real names in those init lists).
  5. Tell the lead which event rows in EVENTS.md appeared (so they change to "observed"), the unknown list from the summary, and any stderr.txt content. Then clean up: `/bin/bash -c '. spike/lib/common.sh; spike_cleanup <run dir printed by run.sh>'`.
- Unconfirmed until the live run: (a) `acceptEdits` alone is enough for the Write tool headless (docs say yes; if not, record what was needed, never bypass permissions); (b) CLOSED: `--max-turns` is hidden in `claude --help` 2.1.295 (hideHelp) but defined in the binary and documented for print mode, so passing it is fine; the live run only has to show the cap is honoured; (c) a resumed run keeps write permission (the script passes acceptEdits again); (d) the session id is the same on resume; (e) how the human-readable limit text ("You've hit your session limit") appears in stream-json is not in the docs, so only structured fields are used for limit detection.
- The five system subtypes seen in the binary but not observed (api_error, model_fallback, notification, turn_duration, stop_hook_summary) are listed in EVENTS.md for T-004 and are deliberately not in parse.jq's known list, so a live capture reports them under `unknown`.
- The verdict is per script (the function is duplicated in run.sh and resume.sh on purpose, each test extracts and runs both copies). resume.sh records session-id reuse (yes/no/unknown) but does not fail on a different id; that is a finding for the human. A stale `resume.lock` directory (for example after a crash before the run started) blocks that capture for good: delete it by hand only after checking that no resume happened.
- Not testable offline (needs SPIKE_LIVE=1, which tests never set): the trailing-slash handling and the `unknown`/rc 121 branches of resume.sh are covered by source checks plus a test of the same shell idiom, not by running the script.
- Deviation from the brief: resume.sh puts the prompt before `--resume <id>` (the form in the headless docs) and adds `--permission-mode acceptEdits --max-turns 5`; the brief's sketch had neither.
- The T-001 runner writes the child's stdout and stderr to the same output file, so run.sh splits afterwards: JSON-object lines go to raw.jsonl, other lines to stderr.txt. A stderr line that is itself a JSON object would land in raw.jsonl (parse.jq would then list it under unknown). The split lives in spike/claude/split.jq and is tested offline, including non-object JSON lines. If CLI stderr and stdout interleave mid-line, such a line is reported as malformed, never fatal.
- Rule 6 limitation: the runner executes a private COPY of the binary. A claude that needs files next to itself may not start from the copy (exit 126 or 127, reported as "needs human review", no fallback to the original path).
- Follow-ups for shared files (lead): (1) spike/lib: add an option for a separate stderr file and one for the child's working directory to spike_run_live (workaround now: `cd` to the worktree before the call, and a post-hoc split); (2) spike/README.md: change the script index row for claude/* and tests/test_claude_parse.sh from planned to done (T-002); (3) no Makefile change is needed, `make spike-test` already globs spike/tests/*.sh.

## Confidence
medium, the parser, split, scrub and gates are covered by 166 offline checks and the other suites still pass, but every event shape is from docs and the live path (registration, runner, flags, resume) has never run against the real CLI.
