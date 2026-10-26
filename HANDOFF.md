# HANDOFF T-003

## Summary
Codex headless spike, offline half. `spike/codex/run.sh` and `resume.sh` drive one `codex exec --json` task and one
`codex exec ... resume <thread_id>` through the T-001 runner (gate first, registered hash-verified copy only, 120 s
watchdog, one call, no retry). `parse.jq` turns the JSONL into the specified summary object and never fails on unknown
types or malformed lines. `EVENTS.md` documents every event, item, usage and error shape, all marked "from docs" (taken
from the official `@openai/codex-sdk` 0.164.0 type definitions; nothing observed except CLI flag placement, verified with
`--help` on codex-cli 0.162.0). The live run is the human's step. Reviewer follow-ups applied: flag order recorded, exact-argv
allow-list test, narrower rate-limit heuristic, de-duplicated error items, exact hello.txt byte checks, pwned check in the temp dir.

## Files changed
- spike/codex/run.sh - gated live run: register codex, login status (exit code only), scratch worktree codex-1, one `codex exec --json --sandbox workspace-write -C <wt>` (single-line call), split/parse/redact, exact-bytes hello.txt check (one optional trailing newline)
- spike/codex/resume.sh - gated live resume by thread id, one resume per capture, single-line call, exact two-line hello.txt check (second line with or without trailing newline); comment records the verified flag order
- spike/codex/parse.jq - JSONL summary; rate-limit heuristic narrowed (rate/usage limit, insufficient_quota, quota exceeded, too many requests, 429); limit_or_error_events built from de-duplicated items
- spike/codex/EVENTS.md - event/item/usage/error shapes; flag placement marked "observed via --help, codex-cli 0.162.0"; heuristic false-positive note for T-004
- spike/fixtures/codex/sample.jsonl - hand-written from the SDK types, every event and item type plus two synthetic unknowns
- spike/fixtures/codex/failure.jsonl - error and turn.failed shapes with synthetic rate-limit wording
- spike/fixtures/codex/malformed.jsonl - broken lines, wrong shapes, inert injection text
- spike/tests/test_codex_parse.sh - 371 offline checks (parser, fixtures, EVENTS.md coverage, gate with a fake codex, exact-argv allow-list with mutation self-test, hello_ok byte cases, heuristic and dedup cases, static rules)
- HANDOFF.md - this file

## Tests run
- `/bin/bash spike/tests/test_codex_parse.sh` - 371 passed, 0 failed (offline; SPIKE_LIVE never set; no provider CLI run)
- `PATH=/usr/bin:/bin make -s check-fast` - PASS (compliance-scan clean)
- `PATH=/usr/bin:/bin make -s spike-test` - PASS (codex 302, common 914, handoff 1039, plan 414, preflight 142)
- `bash -n` on run.sh and resume.sh - clean

## Hard rules touched
- Rule 1 (human-triggered, bounded): run.sh and resume.sh exit 3 without SPIKE_LIVE=1 (unset plus 7 near-miss values tried), the fake codex marker stays absent, nothing is created; exactly one `spike_run_live` call each, no loops, 120 s watchdog (test_codex_parse.sh, gate and static sections).
- Rule 2 (no profiles/overrides/alternate homes): the test pins the exact argument vector on the single `spike_run_live` line of each script (nothing can be appended after `-C "$WT"`; mutated copies with extra arguments are rejected), explicitly rejects --enable, --disable, --ignore-user-config, --strict-config, --ignore-rules, attached -ckey=value, -c/--config, -p/--profile, --dangerously-*, --oss, --local-provider, --approve-for-me, and greps for the four config-home variable names; compliance scan clean.
- Rule 3 (headless only): only `codex exec` via the runner, stdin /dev/null; test checks the command shape and that no bare codex/claude command exists in the scripts.
- Rule 4 (credentials): sign-in by `login status` exit code only (output to /dev/null); scripts name no CLI home (checked against compliance/denylist.txt); fixtures contain no at-sign, /Users/ or /home/ (tested).
- Rule 6 (official binary): `spike_register_cli codex` and `$SPIKE_VERIFIED_COPY` only; test checks the call shape.
- Rule 10 (no retry): one call, no loop/retry/sleep in code; resume.sh refuses a second resume of the same capture (test: static checks; refusal logic by review, since it sits behind the live gate).

## Open risks / questions
- No event stream is observed. Event/item shapes come from the official `@openai/codex-sdk` 0.164.0 types (npm); the installed CLI is codex-cli 0.162.0, so a field added between the two versions may differ.
- Flag order is verified (reviewer, `--help`, codex-cli 0.162.0): `-C` and `--sandbox` are `codex exec` options only and go before `resume` (`codex exec resume -C ...` fails "unexpected argument"); `--json` works on `exec` and `exec resume`. resume.sh's invocation is correct. Residual risk: a later CLI version changes this; the failure is then a Codex usage error and nothing else runs.
- The rate-limit text heuristic can still flag an error that merely mentions a limit, quota or the number 429, and can miss a differently worded limit; T-004 must combine it with exit status.
- Post-gate code paths (registration, scratch repo, the live call, the result checks in run.sh/resume.sh) cannot be exercised offline without SPIKE_LIVE=1, which this task forbids. They are reviewed by reading plus `bash -n`, and the awk split and parser are tested separately. Expect to fix small script bugs on the first live run.
- The runner sends stdout and stderr to the same file, so stderr.txt is derived (lines not starting with `{`). A stderr line that starts with `{` would land in raw.jsonl; the parser counts it as malformed.
- Rate-limit shape is a text heuristic only (the SDK has no rate-limit event). Unobserved; never provoked.
- If codex on PATH is the npm launcher script rather than the native signed binary, registration refuses it ("launcher only") and run.sh stops before any prompt. Install the native binary first.

Human live-run steps (Mac, once, in order):
1. Check out this branch. Run `spike/preflight.sh`: the codex row must show a verified signature and signed in. If signed out, sign in yourself in a terminal with Codex's own login flow.
2. Run `codex exec --help` and `codex exec resume --help`. Expected (verified on codex-cli 0.162.0): `--json`, `--sandbox`, `-C` are `exec` options that go before `resume`; `resume` itself rejects `-C`; `--json` works on both. If your version differs, stop and tell the lead before step 3.
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
Medium. The parser, fixtures, gate behaviour, exact argument vector and static rules are fully tested offline (371 checks), and the flag placement is now verified against codex-cli 0.162.0 `--help`. Confidence in the live path is still lower: the post-gate code (registration, scratch repo, result checks) is unexercised by design, and the event shapes are unobserved.
