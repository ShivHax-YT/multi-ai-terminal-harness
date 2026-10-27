# Phase 0 report (template, T-007)

> **How this is used.** The human runs `spike/run-both.sh` once on the Mac (the live opt-in is set by the human, never by an
> agent; see `spike/README.md`) and sends the output to the lead. The lead fills the blanks below from that output and from the
> T-002/T-003 handoffs, then the human signs off. Nothing here is filled by running a CLI from an agent session.
> Facts marked **known 2026-10-26, confirm** come from the human's earlier live runs; re-confirm them against this run.
> Do not paste a credential file, token, account name, e-mail address or home path into this report (rule 4); capture
> output is redacted first (`spike_redact`), and the captures themselves stay gitignored.

## 1. Run header

| Item | Value |
|---|---|
| Date (UTC) | |
| macOS version | |
| bash version (`/bin/bash --version`, expected 3.2) | |
| `jq` version | |
| Repo commit (`git rev-parse --short HEAD`) | |
| Capture root printed by the run (`spike/captures/run-both/<stamp>`) | |
| Command | `spike/run-both.sh` with the live opt-in set by the human; `--keep` used: yes / no |
| Exit status of `run-both.sh` | |
| Preflight output stored in `preflight.txt`: reviewed | yes / no |

## 2. Per CLI

| Item | Claude Code | Codex |
|---|---|---|
| Version (`--version`) | | known 2026-10-26, confirm: codex-cli 0.162.0 |
| Install method | known 2026-10-26, confirm: native installer binary passes; the npm-installed `claude` is refused by preflight (launcher script) | |
| Code signature result (preflight SIGNATURE column) | | |
| Signer and team id (as printed) | | |
| Sign-in check (exit code only; output never stored) | | |
| `run.sh` exit status | | |

The pinned team ids in `spike/lib/runner.pl` are still to be confirmed against vendor-published values before release
(`spike/README.md`). Record here whether the printed team ids match the pins: yes / no.

## 3. run-both rows

Paste the printed table. The same rows are in `run-both.json` under the capture root.

```
provider | exit | session | turns | in | out | cache_r | cache_w | cost~ | warn | rl | unk | changed | hello | verdict
<claude row>
<codex row>
```

PASS rule: run.sh exit 0, exactly one `session_started`, exactly one `result` with `is_error` false and numeric tokens, 0
`rate_limited`, `hello.txt` byte-exact. `unknown` above 0 does not fail a run; it means the event needs a mapping in T-004.
The cost column is an estimate from the CLI's own number, never a bill.

| | Claude Code | Codex |
|---|---|---|
| Verdict | | |
| Turns (Codex: 1 per `exec` call by T-004 decision) | | |
| Tokens in / out / cache read / cache write | | |
| Changed files in the worktree | | |
| Notes (reasons printed under the table) | | |

## 4. Event types seen versus `spike/claude/EVENTS.md` and `spike/codex/EVENTS.md`

For each type in the normalized output (`<cli>.normalized.jsonl`) and each raw type behind it, mark one of: **observed**
(seen in this run), **from docs** (documented, not seen), **new** (seen, not in EVENTS.md; needs a row and a mapping).

| CLI | Raw type | Status | Normalized as | Action |
|---|---|---|---|---|
| Claude | `system/init` | | `session_started` | |
| Claude | `rate_limit_event` | known 2026-10-26, confirm: routine on a normal run (`allowed` / `allowed_warning`) | `limit_notice` | |
| Claude | `result/success` | | `result` | |
| Claude | (add rows) | | | |
| Codex | `thread.started` | known 2026-10-26, confirm: observed | `session_started` | |
| Codex | `turn.completed` | known 2026-10-26, confirm: observed, usage has all five numbers | `result` | |
| Codex | `item.completed:command_execution` | known 2026-10-26, confirm: observed | `tool_call` + `tool_result` | |
| Codex | `item.completed:error` | known 2026-10-26, confirm: observed as config warnings in a completed run | `warning` | |
| Codex | (add rows) | | | |

Unknown events (count from the table, list the raw types): ______. Each needs a row in EVENTS.md and a mapping or an
ignore entry in `docs/spec/adapter-interface.md` and the matching `spike/normalize/<cli>.jq` (T-004), together.

## 5. Rate-limit shapes: observed versus documented

No limit was provoked (rules 1, 2, 10). Record only what appeared on its own.

| Shape | Documented | Observed in this run |
|---|---|---|
| Claude `rate_limit_event` with `allowed` / `allowed_warning` | yes | known 2026-10-26, confirm: routine on a normal run, mapped to `limit_notice` |
| Claude `rate_limit_event` with `rejected` | yes | none expected |
| Claude `system/api_retry` | yes | |
| Codex `error` / `turn.failed` carrying limit wording | text heuristic only (no SDK limit event) | none expected |
| Codex `item.completed:error` items | not a limit | known 2026-10-26, confirm: config warnings (deprecated key, under-development feature) inside a run that still completed; mapped to `warning` |
| `rate_limited` count in the table | | |

## 6. Resume results (from T-002 and T-003; this script does not resume)

| CLI | Result | Source |
|---|---|---|
| Claude | known 2026-10-26, confirm: the session id was reused by `--resume` | T-002 `resume.sh` live run |
| Codex | known 2026-10-26, confirm: the thread id was kept on `exec resume` | T-003 `resume.sh` live run |
| Codex two-line `hello.txt` check after the wording fix | to confirm by a fresh T-003 run | |

## 7. stderr notes

| CLI | Observation |
|---|---|
| Codex | known 2026-10-26, confirm: one stderr line, "Reading additional input from stdin...", even with stdin from `/dev/null` |
| Claude | |

## 8. Surprises

- known 2026-10-26, confirm: the npm-installed `claude` is a launcher script and is refused by preflight (rule 6); the native installer's binary passes.
- known 2026-10-26, confirm: the first Codex task wording was ambiguous (the sentence-ending period became part of `hello.txt`); fixed by a wording change, and this run is the fresh Codex run.
- (add)

## 9. Implications

- **T-004 (adapter interface, normalizers):** unknown raw types to map; any new field; `error` carrying non-fatal notices in Codex; the `thinking_tokens` shape. List here:
- **T-120 (event types and serde):** nothing in the schema is expected to change unless section 4 has a **new** row. List here:
- **T-121 (Claude adapter) and T-122 (Codex adapter):** the exact argv used by the two run scripts, the sign-in check by exit code, `loginArgv` words to confirm, install-method handling (launcher script versus native binary). List here:
- **ADR 0001 impact (`docs/adr/0001-stack.md`):** none / describe. The stack decision depends on both CLIs being drivable through their documented headless interfaces and on their output being parseable; state whether this run supports that.

## 10. Phase 0 done-when checklist (`docs/BUILD_PLAN.md`)

- [ ] Both CLIs finished the scripted task and returned parsed, normalized results (`run-both.sh` printed PASS for both, section 3).
- [ ] The compliance CI fails on a planted violation of each check: `make compliance-selftest` result: ______
- [ ] `make check` passes on the Mac: result: ______
- [ ] A redacted `observed.jsonl` per CLI was committed (T-002 and T-003 handoff steps; scrubbed, redacted, read by the human) and `/bin/bash spike/tests/test_normalize.sh` is green with them.
- [ ] Stack decision recorded (`docs/adr/0001-stack.md`), plan and handoff formats written, adapter interface written (T-004).

## 11. Follow-ups

| # | What | Owner | File |
|---|---|---|---|
| 1 | | | |

## 12. Sign-off

Human sign-off (name, date, "Phase 0 closed" or "not closed because ..."): ______________________________
