# Codex headless events (`codex exec --json`), T-003

Input for T-004 (adapter interface and normalized event schema). Everything here is marked **observed** (seen in a real
run on the human's Mac) or **from docs** (taken from official material, not yet seen). Nothing is observed yet: the live
run is the human's step, and the implementer of T-003 never ran a Codex binary. When the human has run `run.sh` and
`resume.sh`, change "from docs" to "observed" row by row, add `spike/fixtures/codex/observed.jsonl` (redacted with
`spike_redact`, read by a human first), and record differences in the last section.

## Sources

| Id | Source | Used for |
|---|---|---|
| S1 | The official `@openai/codex-sdk` TypeScript package, version 0.164.0, type definitions (`dist/index.d.ts`) and source (`dist/index.js`), downloaded from the npm registry. It documents `ThreadEvent` and `ThreadItem`, "Top-level JSONL events emitted by codex exec". | every event and item shape; usage fields; how the SDK builds the `exec` and `resume` command line |
| S2 | The same package's README | threads persist in Codex's own session store and are resumed by thread id |
| S3 | Official Codex non-interactive documentation (`codex exec`, `codex exec resume`) and `codex exec --help`, `codex exec resume --help` | flag names `--json`, `--sandbox`, `-C`. **Not re-read this session**: the docs host was not reachable from the build sandbox, so these flag names rest on S1 (which uses `--sandbox` and `--cd`) and on the implementer's recollection of the docs. The human confirms them with `--help` on the Mac. |

Flag names are never guessed beyond that list. Anything the scripts depend on and S1 does not show is listed under "To
confirm on the Mac" at the end.

## CLI facts

| Fact | Status | Source |
|---|---|---|
| `codex exec` is the headless mode; with `--json` stdout is one JSON object per line (JSONL) | from docs | S1, S3 |
| The first event of a run is `thread.started` with the `thread_id`, "can be used to resume the thread later" | from docs | S1 |
| Options such as `--sandbox <mode>` and `--cd <dir>` belong to `codex exec` and are placed before the `resume` word; the SDK builds `exec <options> resume <thread_id>` and passes the prompt separately | from docs | S1 |
| `run.sh` runs `exec --json --sandbox workspace-write -C <worktree> "<task>"`; `resume.sh` runs `exec --json --sandbox workspace-write -C <worktree> resume <thread_id> "<prompt>"` | design | brief T-003, S1 |
| Sandbox modes: `read-only`, `workspace-write`, `danger-full-access`; the scripts use only `workspace-write` | from docs | S1 |
| A thread has many turns; each `exec` or `exec resume` call is one turn (`turn.started` ... `turn.completed` or `turn.failed`) | from docs | S1 |
| A resumed run is expected to report the same `thread_id` in its own `thread.started` | to confirm | `resume.sh` prints whether it did |
| Exit status: success 0; a failed turn is expected to give a non-zero status | to confirm | not in S1 |
| stderr: the runner merges stderr into the one output file; `run.sh` splits lines starting with `{` (events) from the rest (stderr text) | design | `spike/lib/runner.pl` dup2 of both descriptors |

## Top-level events

The JSON key `type` selects the event. Fields below are all the fields S1 declares.

| `type` | Fields | Status | Meaning |
|---|---|---|---|
| `thread.started` | `thread_id` (string) | from docs | first event; the id to resume with |
| `turn.started` | none | from docs | a prompt was sent; events until `turn.completed` or `turn.failed` belong to this turn |
| `turn.completed` | `usage` (object, see below) | from docs | the turn ended normally |
| `turn.failed` | `error.message` (string) | from docs | the turn ended with an error |
| `item.started` | `item` | from docs | an item was added, usually in progress |
| `item.updated` | `item` | from docs | an item changed (for example the to-do list) |
| `item.completed` | `item` | from docs | an item reached a terminal state (success or failure) |
| `error` | `message` (string) | from docs | an unrecoverable error emitted directly by the stream |

An event type that is not in this table is **unknown**: `parse.jq` counts it in `event_counts` and lists it in `unknown`
(`kind: "event"`); it never fails. `sample.jsonl` carries one synthetic unknown event, `future.event.kind`, to prove that
(it is not a real Codex event).

### Usage (inside `turn.completed`)

All numbers (from docs, S1): `input_tokens`, `cached_input_tokens`, `cache_write_input_tokens`, `output_tokens`,
`reasoning_output_tokens`. Older documentation shows only the first, second and fourth, so a consumer must not require the
others. `parse.jq` keeps only the entries whose value is a number. Usage is per turn, not per thread.

## Items

An item is the `item` object in `item.started`, `item.updated` and `item.completed`. It has an `id` (string) and a `type`.
`parse.jq` counts one item per distinct `id`, whatever number of events it appeared in.

| item `type` | Other fields | Status | Notes |
|---|---|---|---|
| `agent_message` | `text` | from docs | the model's reply; JSON text when a schema was requested; `final.last_message_excerpt` comes from the last one |
| `reasoning` | `text` | from docs | the model's reasoning summary |
| `command_execution` | `command`, `aggregated_output`, `exit_code` (only after exit), `status` (`in_progress`, `completed`, `failed`) | from docs | a shell command the agent ran; `commands_run` lists these |
| `file_change` | `changes` (list of `path` and `kind`: `add`, `delete`, `update`), `status` (`completed`, `failed`) | from docs | emitted once the patch succeeds or fails |
| `mcp_tool_call` | `server`, `tool`, `arguments`, `result` (success), `error.message` (failure), `status` | from docs | not used by the spike task |
| `web_search` | `query` | from docs | not used by the spike task |
| `todo_list` | `items` (list of `text` and `completed`) | from docs | starts when the plan is issued, updates as steps change, completes at turn end |
| `error` | `message` | from docs | a non-fatal error shown as an item; it is not a turn failure |

An item type that is not in this table lands in `unknown` with `kind: "item"`. `sample.jsonl` carries one synthetic unknown
item type, `future_item_kind`.

## Error and rate-limit shapes

**From docs**: S1 defines only two error carriers, `error` (`message`) and `turn.failed` (`error.message`), plus the
non-fatal `error` item. There is **no dedicated rate-limit event or field** in S1. A rate or usage limit therefore
arrives, if at all, as text in one of those messages. `parse.jq` classifies each such carrier into
`limit_or_error_events` with `kind: "rate_limit"` when its message matches a case-insensitive text heuristic (rate limit,
usage limit, quota, too many requests, a standalone 429, "try again in/later", limit reached/exceeded) and `kind: "error"`
otherwise. Agent text (`agent_message`, `reasoning`) is never classified, because the model can write any words. The
heuristic is **not observed**: the fixture `failure.jsonl` uses synthetic messages written to exercise it. T-004 must
treat the text match as a hint and keep exit status and the human's report as the other signals. Limits were never
provoked for this spike.

Redacted example (synthetic, not observed):

```json
{"type":"error","message":"synthetic: stream error, last status: 429 Too Many Requests"}
{"type":"turn.failed","error":{"message":"synthetic: usage limit reached, try again in 3 hours"}}
```

A failed run in `failure.jsonl` ends with `turn.failed` as the last terminal event: `final.status` is `failed`. A run that
never reaches `turn.completed`, `turn.failed` or `error` (for example killed by the 120 s watchdog) has
`final.status` `incomplete`.

## Redacted examples (from docs; the ids are fixture values)

```json
{"type":"thread.started","thread_id":"0199a213-81c0-7800-8aa1-bbab2a035a53"}
{"type":"turn.started"}
{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"bash -lc '...'","aggregated_output":"","status":"in_progress"}}
{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"bash -lc '...'","aggregated_output":"","exit_code":0,"status":"completed"}}
{"type":"item.completed","item":{"id":"item_2","type":"file_change","changes":[{"path":"<WORKTREE>/hello.txt","kind":"add"}],"status":"completed"}}
{"type":"item.completed","item":{"id":"item_8","type":"agent_message","text":"DONE"}}
{"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"cache_write_input_tokens":0,"output_tokens":122,"reasoning_output_tokens":64}}
```

## Fixtures

| File | Content |
|---|---|
| `spike/fixtures/codex/sample.jsonl` | one successful turn written from S1: every event type and every item type, plus the synthetic `future.event.kind` and `future_item_kind` |
| `spike/fixtures/codex/failure.jsonl` | `error` and `turn.failed` events, two with rate-limit wording (synthetic) |
| `spike/fixtures/codex/malformed.jsonl` | broken lines, non-object lines and events of the wrong shape, to prove the parser never fails; the text in it is inert data |
| `spike/fixtures/codex/observed.jsonl` | **does not exist yet**: the human adds it, redacted, after the live run |

No fixture contains an at-sign or a home-directory path (the test checks).

## parse.jq

`jq -n -R -f spike/codex/parse.jq < raw.jsonl` prints one object:

```
{ thread_id, lines, malformed_lines,
  event_counts: {"<event type>": n}, items: {"<item type>": n},
  commands_run: [{command, status, exit_code}],
  final: {status: completed|failed|incomplete, usage, last_message_excerpt (at most 200 chars)},
  limit_or_error_events: [{type, kind: rate_limit|error, message}],
  unknown: [{kind: event|item, type, keys}] }
```

Lines that are not JSON are counted in `malformed_lines`. All text is clipped, has control characters replaced by spaces,
and is only data.

## To confirm on the Mac (live run)

1. `codex exec --help` lists `--json`, `--sandbox`, and `-C`/`--cd`; `codex exec resume --help` shows where its options go.
   If `resume` does not accept the options before the word `resume` (or needs `--json` after it), `resume.sh` fails
   with a usage error from Codex and nothing else; record the working order here and report it to the lead.
2. The real event stream matches this file. Differences (extra fields, extra event or item types, `thread_id` format,
   whether `item.updated` appears, whether usage has all five numbers) go in a new "Observed differences" table.
3. Exit statuses of a normal run, a failed turn and a killed run.
4. Whether the second run keeps the same `thread_id`.
