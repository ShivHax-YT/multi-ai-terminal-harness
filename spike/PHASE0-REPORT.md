# Phase 0 report (T-007, filled 2026-10-28 from the human's live run)

> **How this is used.** The human runs `spike/run-both.sh` once on the Mac (the live opt-in is set by the human, never by an
> agent; see `spike/README.md`) and sends the output to the lead. The lead fills the blanks below from that output and from the
> T-002/T-003 handoffs, then the human signs off. Nothing here is filled by running a CLI from an agent session.
> Facts marked **known 2026-10-26, confirm** come from the human's earlier live runs; re-confirm them against this run.
> Do not paste a credential file, token, account name, e-mail address or home path into this report (rule 4); capture
> output is redacted first (`spike_redact`), and the captures themselves stay gitignored.

## 1. Run header

| Item | Value |
|---|---|
| Date (UTC) | 2026-10-28 02:54 (capture stamp `20261028T025406Z`) |
| macOS version | 27.0.1 |
| bash version (`/bin/bash --version`, expected 3.2) | 3.2.57(1)-release (arm64-apple-darwin26) |
| `jq` version | jq-1.7.1-apple (`/usr/bin/jq`); git 2.55.0 |
| Repo commit (`git rev-parse --short HEAD`) | `273bd9d` (branch T-007, round 4c, before merge) |
| Capture root printed by the run (`spike/captures/run-both/<stamp>`) | `spike/captures/run-both/20261028T025406Z` |
| Command | `spike/run-both.sh` with the live opt-in set by the human; `--keep` used: no |
| Exit status of `run-both.sh` | 0 (`run-both: PASS (both CLIs)`) |
| Preflight output stored in `preflight.txt`: reviewed | yes (lead) |

## 2. Per CLI

| Item | Claude Code | Codex |
|---|---|---|
| Version (`--version`) | 2.1.310 (Claude Code), native install | codex-cli 0.162.0 (confirmed) |
| `--max-turns 5` honoured (Claude only; see the comment in `spike/claude/run.sh`: the flag is documented but hidden from `--help`) | yes: the run took 2 turns | not applicable |
| Install method | native installer binary (Mach-O, in the installer's versions directory); passes preflight (confirmed) | standalone release package (Mach-O, in the CLI's own packages directory, path as printed by preflight) |
| Code signature result (preflight SIGNATURE column) | valid | valid |
| Signer and team id (as printed) | Developer ID Application: Anthropic PBC; team Q6L2SF6YDW | Developer ID Application: OpenAI OpCo, LLC; team 2DC432GLL2 |
| Sign-in check (exit code only; output never stored) | signed in (exit 0) | signed in (exit 0) |
| `run.sh` exit status | 0 | 0 |

The pinned team ids in `spike/lib/runner.pl` are still to be confirmed against vendor-published values before release
(`spike/README.md`). The printed team ids match the pins: yes (Q6L2SF6YDW, 2DC432GLL2). Confirming the pins against the
vendors' published values is still open (section 11).

## 3. run-both rows

The printed table (session ids cut by the script). The same rows are in `run-both.json` under the capture root.

```
provider | exit | session  | turns | in      | out     | cache_r | cache_w | cost~    | warn | rl  | unk | changed                  | hello | verdict
---------+------+----------+-------+---------+---------+---------+---------+----------+------+-----+-----+--------------------------+-------+--------
claude   | 0    | b98e...  | 2     | 4       | 234     | 31726   | 12889   | 0.0030124600000000007 | 0    | 0   | 2   | hello.txt                | yes   | PASS
codex    | 0    | 01a1...  | 1     | 48690   | 60      | 37376   | 0       | -        | 2    | 0   | 0   | hello.txt                | yes   | PASS
note: claude has 2 unknown event(s): needs mapping (T-004)
```

PASS rule: run.sh exit 0, exactly one `session_started`, exactly one `result` with `is_error` false and numeric tokens, 0
`rate_limited`, `hello.txt` byte-exact. `unknown` above 0 does not fail a run; it means the event needs a mapping in T-004.
The cost column is an estimate from the CLI's own number, never a bill.

| | Claude Code | Codex |
|---|---|---|
| Verdict | PASS | PASS |
| Turns (Codex: 1 per `exec` call by T-004 decision) | 2 | 1 |
| Tokens in / out / cache read / cache write | 4 / 234 / 31726 / 12889 | 48690 / 60 / 37376 / 0 |
| Changed files in the worktree | `hello.txt` | `hello.txt` |
| Notes (reasons printed under the table) | 2 unknown events, both `system/commands_changed` (now ignored, section 4) | 2 warnings: config notices from the user's own Codex config (section 5) |

## 4. Event types seen versus `spike/claude/EVENTS.md` and `spike/codex/EVENTS.md`

For each type in the normalized output (`<cli>.normalized.jsonl`) and each raw type behind it, mark one of: **observed**
(seen in this run), **from docs** (documented, not seen), **new** (seen, not in EVENTS.md; needs a row and a mapping).

| CLI | Raw type | Status | Normalized as | Action |
|---|---|---|---|---|
| Claude | `system/init` | observed | `session_started` | none |
| Claude | `rate_limit_event` | observed, routine (`status: allowed`; `rateLimitType: overage`) | `limit_notice` | none |
| Claude | `result/success` | observed (`num_turns` 2, `is_error` false) | `result` | none |
| Claude | `assistant:tool_use` | observed (one `Write` of `hello.txt`) | `tool_call` | none |
| Claude | `user:tool_result` | observed | `tool_result` | none |
| Claude | `assistant:text` | observed (`DONE`) | `message` | none |
| Claude | `assistant:thinking` | observed (empty text plus an opaque signature) | ignored | none |
| Claude | `system/thinking_tokens` | observed twice (`estimated_tokens`, `estimated_tokens_delta`) | ignored | none |
| Claude | `system/commands_changed` | **was "from docs"; observed twice** (the whole slash-command list, 65 entries, about 23 KB each) | was `unknown`; now ignored | done 2026-10-28: added to `claude.jq` ignored keys, the spec's ignored list and EVENTS.md; `scrub-init.jq` now redacts its `commands` (personal configuration) |
| Codex | `thread.started` | observed (confirmed) | `session_started` | none |
| Codex | `turn.started` | observed | ignored | none |
| Codex | `turn.completed` | observed (confirmed); usage has all five numbers (`input_tokens`, `cached_input_tokens`, `cache_write_input_tokens`, `output_tokens`, `reasoning_output_tokens`) | `result` | none |
| Codex | `item.started:command_execution` | observed | none (the completed item carries the call) | none |
| Codex | `item.completed:command_execution` | observed (confirmed): `/bin/zsh -lc "printf 'hello from codex\\n' > hello.txt"`, exit 0 | `tool_call` + `tool_result` | note for T-122 (login shell, section 9) |
| Codex | `item.completed:agent_message` | observed twice | `message` | none |
| Codex | `item.completed:error` | observed twice (confirmed): config warnings in a completed run | `warning` | none |

Unknown events (count from the table, list the raw types): 2, both Claude `system/commands_changed`. Mapped as ignored, with
the spec, `claude.jq` and EVENTS.md changed together; `spike/tests/test_normalize.sh` now runs over both observed captures with
0 unknown and byte-exact goldens (`spike/normalize/expected/{claude,codex}-observed.jsonl`).

## 5. Rate-limit shapes: observed versus documented

No limit was provoked (rules 1, 2, 10). Record only what appeared on its own.

| Shape | Documented | Observed in this run |
|---|---|---|
| Claude `rate_limit_event` with `allowed` / `allowed_warning` | yes | observed (confirmed): `allowed`, routine, mapped to `limit_notice`; this one also carried `rateLimitType: overage`, `overageStatus: allowed`, `overageInUse: true`, `isUsingOverage: false` |
| Claude `rate_limit_event` with `rejected` | yes | none |
| Claude `system/api_retry` | yes | none |
| Codex `error` / `turn.failed` carrying limit wording | text heuristic only (no SDK limit event) | none |
| Codex `item.completed:error` items | not a limit | observed (confirmed): two config warnings (a deprecated `[features]` key; an under-development feature enabled) inside a run that completed; mapped to `warning` |
| `rate_limited` count in the table | | 0 and 0 |

## 6. Resume results (from T-002 and T-003; this script does not resume)

| CLI | Result | Source |
|---|---|---|
| Claude | known 2026-10-26, confirm: the session id was reused by `--resume` | T-002 `resume.sh` live run (not re-run; run-both never resumes) |
| Codex | known 2026-10-26, confirm: the thread id was kept on `exec resume` | T-003 `resume.sh` live run (not re-run) |
| Codex | T-003 resume check, to confirm by a fresh T-003 run: after `spike/codex/resume.sh`, `hello.txt` has line 1 `hello from codex` and line 2 `resumed`. Not part of the run-both.sh check, which expects exactly one line. | T-003 `resume.sh` (still open, section 11) |

## 7. stderr notes

| CLI | Observation |
|---|---|
| Codex | confirmed: one stderr line, "Reading additional input from stdin...", even with stdin from `/dev/null` (39 bytes) |
| Claude | empty (0 lines) |

## 8. Surprises

- confirmed: the native `claude` binary passes preflight (the npm launcher-script refusal was not re-tested in this run).
- confirmed: the reworded Codex task produced a byte-exact one-line `hello.txt` (`printf 'hello from codex\n'`).
- **Claude `system/commands_changed` carries personal configuration.** It repeats the whole slash-command list, with the name
  and description of every one of the user's own skills and plugin commands (65 entries, about 23 KB, twice per run). The old
  `scrub-init.jq` only scrubbed `system/init`, so the first fixture attempt still held that list (found by the `@` check).
  `scrub-init.jq` now redacts `commands` too, with a count, and `test_claude_parse.sh` checks both the scrub and the committed
  `observed.jsonl`. Any adapter log in Phase 1 must treat this event the same way (no personal configuration in logs).
- **The Claude model was not chosen by us.** The run script passes no model, and the CLI used `claude-haiku-5-5` (the user's own
  default). A role-based app must pass the model explicitly.
- **Codex runs commands through the user's login shell** (`/bin/zsh -lc ...`), so the user's shell profile runs inside each
  sandboxed command.
- **Codex config warnings come from the user's own config** (`[features]` keys) and arrive as `item.completed:error`. They are
  correctly warnings, not errors.
- The table's cost column prints the CLI's raw float (`0.0030124600000000007`) and breaks the column alignment. Cosmetic.
- The human's terminal masked the `captures (gitignored; ...)` line as "key material" because of its long path. Cosmetic.
- If the `run-both.sh` parent alone gets a TERM (not the process group), it waits for the running child process to finish
  before it reacts. The parent checks for a signal before it starts Codex, so a signal received before that check keeps Codex
  from starting. This is by design for a human-run spike, and the runner (`spike/lib/runner.pl`) is frozen. To stop at once,
  press Ctrl-C or signal the process group: `kill -TERM -<pgid>`. (Not exercised in this run.)

## 9. Implications

- **T-004 (adapter interface, normalizers):** `system/commands_changed` is now an observed, ignored Claude type (done). The
  `system/thinking_tokens` shape is `{estimated_tokens, estimated_tokens_delta}` (ignored). Codex `turn.completed` usage has a
  fifth number, `cache_write_input_tokens` (0 here). No other new field.
- **T-120 (event types and serde):** no change. No **new** normalized type; every raw type mapped to an existing event or ignore.
- **T-121 (Claude adapter):** argv as in `spike/claude/run.sh` (`-p`, `--output-format stream-json`, `--verbose`,
  `--permission-mode acceptEdits`, `--max-turns`, honoured). Sign-in by exit code worked. Pass `--model` explicitly per role.
  Treat `system/commands_changed` (and the `system/init` lists) as personal configuration: never log them unscrubbed.
- **T-122 (Codex adapter):** argv as in `spike/codex/run.sh` (`exec --json --sandbox workspace-write -C <worktree> <task>`).
  Sign-in by exit code worked. Expect the stdin notice on stderr and user-config warnings as `warning` events. Commands run via
  the user's login shell.
- **ADR 0001 impact (`docs/adr/0001-stack.md`):** none. Both CLIs were driven only through their documented headless
  interfaces, their output parsed into the normalized events with no screen text, and both runs passed. The run supports the
  decision.

## 10. Phase 0 done-when checklist (`docs/BUILD_PLAN.md`)

- [x] Both CLIs finished the scripted task and returned parsed, normalized results (`run-both.sh` printed PASS for both, section 3).
- [ ] The compliance CI fails on a planted violation of each check: `make compliance-selftest` result: MAKE_CHECK_SELFTEST
- [ ] `make check` passes on the Mac: result: MAKE_CHECK_RESULT
- [x] A redacted `observed.jsonl` per CLI was committed (T-002 and T-003 handoff steps; scrubbed, redacted, read by the human) and `/bin/bash spike/tests/test_normalize.sh` is green with them. Status: both files built (`scrub-init.jq` + `spike_redact` for Claude; `observed.redacted.jsonl` for Codex), 0 `@` and 0 home paths, read by the lead and by the human (2026-10-28), committed with their goldens; `test_normalize.sh` green (803 passed).
- [x] Stack decision recorded (`docs/adr/0001-stack.md`, accepted 2026-10-25), plan and handoff formats written, adapter interface written (T-004, merged into T-007).

## 11. Follow-ups

| # | What | Owner | File |
|---|---|---|---|
| 1 | Done 2026-10-28: the human read both observed fixtures; committed | human | `spike/fixtures/{claude,codex}/observed.jsonl` |
| 2 | Confirm the pinned team ids against the vendors' published values before release | human | `spike/lib/runner.pl` |
| 3 | A fresh T-003 resume run to confirm the two-line `hello.txt` (section 6) | human, optional | `spike/codex/resume.sh` |
| 4 | Round the cost column in the table (cosmetic) | later lib task | `spike/run-both.sh` |
| 5 | Pass the model explicitly; never log `commands_changed` / init lists unscrubbed | T-121 | Claude adapter |
| 6 | Document the login-shell behaviour and the stdin notice | T-122 | Codex adapter |
| 7 | `spike_cleanup` closed environment, and the accepted "directory replacement" residual (T-007 handoff) | later lib task | `spike/lib/common.sh` |
| 8 | Three old scratch run dirs from 2026-10-26 remain under the scratch root; remove with `spike_cleanup <run dir>` | human, optional | scratch root |

## 12. Sign-off

Human sign-off (name, date, "Phase 0 closed" or "not closed because ..."): ______________________________
