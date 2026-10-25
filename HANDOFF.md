# HANDOFF T-003

## Summary
Codex headless spike, offline half. `spike/codex/run.sh` and `resume.sh` drive one `codex exec --json` task and one
`codex exec ... resume <thread_id>` through the T-001 runner (gate first, registered hash-verified copy only, 120 s
watchdog, one call, no retry). `parse.jq` turns the JSONL into the specified summary object and never fails on unknown
types or malformed lines. `EVENTS.md` documents every event, item, usage and error shape, all marked "from docs" (taken
from the official `@openai/codex-sdk` 0.164.0 type definitions; nothing observed). The live run is the human's step.

## Files changed
- spike/codex/run.sh - gated live run: register codex, login status (exit code only), scratch worktree codex-1, one `codex exec --json --sandbox workspace-write -C <wt>`, split/parse/redact the capture
- spike/codex/resume.sh - gated live resume by thread id from a run.sh capture, one resume per capture, checks hello.txt has two lines
- spike/codex/parse.jq - JSONL summary (thread_id, event_counts, items, commands_run, final, limit_or_error_events, unknown, malformed_lines)
- spike/codex/EVENTS.md - event/item/usage/error shapes with sources and status, CLI facts, live-run confirmations
- spike/fixtures/codex/sample.jsonl - hand-written from the SDK types, every event and item type plus two synthetic unknowns
- spike/fixtures/codex/failure.jsonl - error and turn.failed shapes with synthetic rate-limit wording
- spike/fixtures/codex/malformed.jsonl - broken lines, wrong shapes, inert injection text
- spike/tests/test_codex_parse.sh - 302 offline checks (parser, fixtures, EVENTS.md coverage, gate with a fake codex, banned flags, static rules)
- HANDOFF.md - this file

## Tests run
- `/bin/bash spike/tests/test_codex_parse.sh` - 302 passed, 0 failed (offline; SPIKE_LIVE never set; no provider CLI run)
- `PATH=/usr/bin:/bin make -s check-fast` - PASS (compliance-scan clean)
- `PATH=/usr/bin:/bin make -s spike-test` - PASS (codex 302, common 914, handoff 1039, plan 414, preflight 142)
- `bash -n` on run.sh and resume.sh - clean

## Hard rules touched
- Rule 1 (human-triggered, bounded): run.sh and resume.sh exit 3 without SPIKE_LIVE=1 (unset plus 7 near-miss values tried), the fake codex marker stays absent, nothing is created; exactly one `spike_run_live` call each, no loops, 120 s watchdog (test_codex_parse.sh, gate and static sections).
- Rule 2 (no profiles/overrides/alternate homes): test greps run.sh/resume.sh for every banned flag (-c/--config, -p/--profile, --dangerously-*, --oss, --local-provider, --approve-for-me) and for the four config-home variable names; compliance scan clean.
- Rule 3 (headless only): only `codex exec` via the runner, stdin /dev/null; test checks the command shape and that no bare codex/claude command exists in the scripts.
- Rule 4 (credentials): sign-in by `login status` exit code only (output to /dev/null); scripts name no CLI home (checked against compliance/denylist.txt); fixtures contain no at-sign, /Users/ or /home/ (tested).
- Rule 6 (official binary): `spike_register_cli codex` and `$SPIKE_VERIFIED_COPY` only; test checks the call shape.
- Rule 10 (no retry): one call, no loop/retry/sleep in code; resume.sh refuses a second resume of the same capture (test: static checks; refusal logic by review, since it sits behind the live gate).

## Open risks / questions
- Nothing here is observed. The official docs page was not reachable from the build sandbox (egress blocked), so event/item shapes come from the official `@openai/codex-sdk` 0.164.0 types (npm), and flag names `--json`, `--sandbox`, `-C` from the SDK's own command line plus recollection of the docs. The SDK passes `--experimental-json`; the plain `--json` must be confirmed with `codex exec --help`.
- `resume.sh` puts all options before the word `resume` (the SDK's order), not `resume <id> --json` as the brief sketched. If `codex exec resume --help` says otherwise, resume.sh will fail with a Codex usage error and do nothing else; the human records the right order in EVENTS.md and the lead amends resume.sh.
- Post-gate code paths (registration, scratch repo, the live call, the result checks in run.sh/resume.sh) cannot be exercised offline without SPIKE_LIVE=1, which this task forbids. They are reviewed by reading plus `bash -n`, and the awk split and parser are tested separately. Expect to fix small script bugs on the first live run.
- The runner sends stdout and stderr to the same file, so stderr.txt is derived (lines not starting with `{`). A stderr line that starts with `{` would land in raw.jsonl; the parser counts it as malformed.
- Rate-limit shape is a text heuristic only (the SDK has no rate-limit event). Unobserved; never provoked.
- If codex on PATH is the npm launcher script rather than the native signed binary, registration refuses it ("launcher only") and run.sh stops before any prompt. Install the native binary first.

Human live-run steps (Mac, once, in order):
1. Check out this branch. Run `spike/preflight.sh`: the codex row must show a verified signature and signed in. If signed out, sign in yourself in a terminal with Codex's own login flow.
2. Run `codex exec --help` and `codex exec resume --help`. Confirm `--json`, `--sandbox`, `-C` exist and where `resume` takes options. If different, stop and tell the lead before step 3.
3. Run `SPIKE_LIVE=1 spike/codex/run.sh`. Expect `hello.txt: OK`, a thread_id, final status completed, and a capture path. One run only; do not repeat it if it fails (rule 10). If rate limited, wait.
4. Run `SPIKE_LIVE=1 spike/codex/resume.sh <capture path printed by run.sh>`. Expect same thread id and `hello.txt: OK (two lines ...)`.
5. Read `raw.jsonl` and `resume.raw.jsonl` in the capture directory. If they hold nothing private, copy `observed.redacted.jsonl` to `spike/fixtures/codex/observed.jsonl`, check it has no at-sign or home path, and run `/bin/bash spike/tests/test_codex_parse.sh`.
6. Update EVENTS.md: change "from docs" to "observed" row by row, add an "Observed differences" table (extra fields, exit statuses, whether usage has all five numbers, resume flag order).
7. Delete the scratch directory `${TMPDIR:-/tmp}/harness-spike/run-*` when finished.

Follow-ups for shared files (lead):
- spike/lib: add an option to `spike_run_live` to write stderr to a separate file (and optionally set the child's cwd), so captures need no after-the-fact split.
- spike/README.md script index: mark `codex/*` and `tests/test_codex_parse.sh` as done (T-003); no change needed in the Makefile (spike-test globs spike/tests/*.sh).
- T-004: use EVENTS.md as the codex input; rate-limit detection must combine the text heuristic with exit status.

## Confidence
Medium. The parser, fixtures, gate behaviour and static rules are fully tested offline (302 checks, all suites green). Confidence in the live path is lower: it is unexercised by design, and the CLI flag placement for `resume` and the `--json` flag name rest on the SDK source and memory of the docs.
