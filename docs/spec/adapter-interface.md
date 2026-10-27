# Adapter interface, session state machine and event mapping (v1)

Status: Phase 0 spec, T-004 rev 2 (approved 2026-10-26). Language neutral: T-120 turns it into Rust traits and serde types,
T-121 (Claude) and T-122 (Codex) implement it, T-124 (sessions) drives the state machine.
Proof: `spike/normalize/{claude,codex}.jq` normalize every committed fixture; `spike/tests/test_normalize.sh` checks them
against `docs/spec/event.schema.json` and the golden files in `spike/normalize/expected/`.

The hard rules (`docs/HARD_RULES.md`) override this document. Where a rule is touched, the rule number is in brackets.

## Scope and trust

- One adapter per provider CLI. It runs the official, unmodified CLI through a documented headless or ACP interface and
  nothing else [3, 6]. The human-watched terminal is not an adapter transport.
- Every string that comes from a CLI (agent text, tool output, error text, names) is untrusted data. It is clipped, has
  control characters removed, and is never executed, never used as an instruction and never classified by meaning. Only
  structured fields decide anything.
- stderr is diagnostics only. It is never parsed into events.
- Failover only moves work to a different provider, and only one listed in the approved plan [2, 9].
  A limit never starts a new session on the same provider, and a logout, account switch or new session never resets a cap [2].

## Methods

Types used below: `SessionId` is the CLI's own id for the conversation (Claude `session_id`, Codex `thread_id`), an opaque
string. `Worktree` is an absolute path to the worker's git worktree. `Event` is the normalized event of
`docs/spec/event.schema.json`.

### start(task, worktree) -> SessionId

Starts the first invocation of a conversation: one headless child process with the task as its prompt, working directory
set to the worktree, and the CLI's default config home.

- Preconditions (all checked by the caller before the child exists):
  1. the binary is verified (rule 6; T-115 owns the check);
  2. the CLI runs with its default config home and an allowlisted environment, with no config-home override [2];
  3. the worktree is outside every CLI home directory [4];
  4. the plan was approved and the scheduler holds the approval token for its hash [9];
  5. the scheduler admitted the call (ceilings, pacing, spend cap) [1, 10, 11].
- Returns the `SessionId` once a `session_started` event arrived. Events are read through `events()`.
- Errors: `Unavailable` (binary missing or unverified, kill switch disabled [12]), `NotSignedIn`, `InvalidWorktree`,
  `SpawnFailed`.
- Rules: the child's input is closed or reads from /dev/null; nothing is ever sent to it later.

### send(prompt) -> ()

Starts the **next headless invocation** of the same conversation with resume by `SessionId`. It never writes to a child
that is already running. The previous invocation must have ended (state `idle`).

- Preconditions: same as `start`, plus state `idle` (not `rate_limited`, `exited` or `killed`).
- Errors: `Busy` (an invocation is running), `NotResumable` (capabilities say `resume` is false, or no `SessionId` yet),
  `Unavailable`.
- ACP adapters (later phases) send the prompt as a JSON-RPC request on the already open stdio session; the rule is the same:
  documented protocol messages only.

### events() -> Stream<Event>

The normalized events of the conversation, in raw order. Produced only from the CLI's structured output (JSONL or
JSON-RPC); never from screen text. The stream ends with `exited` when the process ends.

- Never fails on bad input: a line that is not JSON, an unexpected shape or an unknown type becomes an `unknown` event.
- Event order guarantees: `session_started` first and once per invocation; every `tool_result` after its `tool_call`.

### cancel() -> ()

Stops the running invocation (terminate, then kill after a grace period). State becomes `killed`. Idempotent. Worktree files
stay. It is also what the watchdog calls.

### authStatus() -> SignedIn | SignedOut | Unknown

Runs the CLI's own documented status command and uses its **exit code only**; the output is discarded (rule 4). Claude:
`claude auth status`; Codex: `codex login status`. No credential file, token store or Keychain item is read, copied or
logged, by this method or any other.

- `Unknown` for any exit code the adapter does not recognize, a timeout or a missing binary. Never guess `SignedIn`.

### capabilities() -> { transport, resume, mcp, hooks, native_turn_cap }

Static facts about the adapter, see `$defs.capabilities` in the schema.

- `transport` is `headless` or `acp`. There is no other value, and the registry rejects an adapter that reports neither [3].
- `resume`: the CLI can continue a conversation by id. `mcp`, `hooks`: the CLI supports them (informational).
- `native_turn_cap`: the CLI can cap turns inside one invocation by itself (Claude `--max-turns`; Codex has none). The
  scheduler enforces rule 1's 40 turns per task regardless.

### usage() -> { tokens, requests, estimated_share, cost_usd, cost_is_estimate }

Totals for the conversation, built **only** from normalized `result` events (token counts) and the scheduler's own counters.
`tokens` has the five fields of the `result` event. `requests` is the number of invocations. `estimated_share` is a share of
the provider's subscription window, or null when unknown. Everything derived from cost or share is an estimate and
`cost_is_estimate` is always true for subscription logins. No provider file is read to compute it.

### loginArgv() -> argv | none

Returns the argument vector of the CLI's own documented login command, and nothing else. It never contains a flag that
changes the account, the config home or the credential store [2, 4]. It returns `none` for API-key-only providers
(Gemini, rule 7). The caller runs it in a login session that only the human drives; see "Login" below.

## Capabilities by adapter (MVP)

| Adapter | transport | resume | mcp | hooks | native_turn_cap | authStatus command | loginArgv |
|---|---|---|---|---|---|---|---|
| Claude Code | headless | true | true | true | true | `claude auth status` | `["claude", "auth", "login"]` (T-121 confirms the exact words) |
| Codex | headless | true | true | false | false | `codex login status` | `["codex", "login"]` (T-122 confirms the exact words) |

## Invocation rules (apply to every method)

- Headless invocations use the flags recorded in `spike/README.md` (Claude: `-p --output-format stream-json --verbose
  --permission-mode acceptEdits --max-turns 5`; Codex: `exec --json --sandbox workspace-write -C <worktree>`), resume by id.
- The child's standard input is `/dev/null` (or closed). The adapter has no method that writes to a child, and the scheduler
  and lead have no access to a terminal write function [3].
- A hard time limit (watchdog, default 120 s per spike call) bounds every invocation.
- Rule 10 timings (5 s between dispatches per provider, backoff from 60 s, pause after 3 consecutive limit errors) are
  enforced by the scheduler and are referenced here, not redefined.

## Login

`loginArgv()` is the only login hook. The login runs in a terminal session that the **human** drives; automation never
sends input to it and never reads what it shows (rule 3). The adapter learns the result only by calling `authStatus()`
afterwards (exit code only). For Gemini there is no login command at all (rule 7).

## Session state machine

States: `spawning`, `running`, `idle`, `rate_limited`, `exited`, `killed` (the T-120 set). `paused` is a flag owned by
T-124, not a state. `exited` and `killed` are terminal. An invocation is one child process; `idle` means no child is
running and the conversation can be resumed.

| # | From | Trigger | To | Notes |
|---|---|---|---|---|
| 1 | (none) | child process started (`start`, or `send` from `idle`) | `spawning` | |
| 2 | `spawning` | `session_started` | `running` | a resumed invocation announces the same id again |
| 3 | `spawning` | child exits before `session_started`, no `rate_limited` seen | `exited` | |
| 4 | `running` | invocation ends: `result{is_error:false}` seen, exit code 0, no `rate_limited` seen | `idle` | resumable |
| 5 | `running` | `result{is_error:true}` seen, no `rate_limited` seen, then the child ends | `exited` | |
| 6 | `running` | child exits without any `result`, no `rate_limited` seen | `exited` | includes a non-zero exit, a crash, a watchdog kill that was not a `cancel()`, and a Codex bare top-level `error` |
| 7 | `spawning`, `running` | `rate_limited` seen (any number of times) | stays in that state; sets the invocation's `limit_seen` flag; when the child ends the state becomes `rate_limited` | counted once per invocation; later ones only raise `reset_at`; a `rate_limited` seen while `spawning` is not lost |
| 8 | `rate_limited` | backoff over (rule 10) or the user resumes | `idle` | the scheduler decides; a limit never starts a new session on the same provider [2] |
| 9 | `idle` | `send(prompt)` | `spawning` | next invocation, resume by id |
| 10 | `spawning`, `running`, `idle`, `rate_limited` | `cancel()` or watchdog | `killed` | |
| 11 | `running` | `result{is_error:false}` seen, then a non-zero exit or death by a signal that was not a `cancel()`, no `rate_limited` seen | `exited` | the invocation's `is_error` is derived from the exit code or signal (true); the `result` event itself is not rewritten |

Any other (state, trigger) pair is an illegal transition and an error in T-120's pure transition function.

**Invocation flags.** Row 7 needs memory that a single event cannot give: whether a `rate_limited` was seen earlier in this
invocation. The transition function therefore takes `(state, event, invocation_flags)` and returns the new state and the new
flags, not `(state, event)`. The flags are `limit_seen` (with the highest `reset_at` seen), `result_seen` and the `is_error`
of that result; they start empty at row 1 or 9 and are dropped when the invocation ends.

**Precedence when the child ends.** `limit_seen` wins over rows 3 to 6 and 11: an invocation in which a limit was seen ends
in `rate_limited` even when it also produced a successful or failed `result`, produced no `result` at all (a Codex limit
`error` with no `turn.failed`), or ended before `session_started`. Without `limit_seen`, the rows apply in this order: 3, 11,
4, 5, 6 (a `result{is_error:false}` with a non-zero exit or a signal is row 11, never row 4).

**Turns.** `result.turns` is the number of turns used by that invocation: for Claude the `num_turns` of its `result`; for
Codex 1 per `exec` call (human decision 2026-10-26; the 120 s watchdog bounds one call). T-124 adds them up toward rule 1's
40 turns per task. A result that is an error still counts its turns. **An invocation that ends without any `result` (a Codex
bare top-level `error`, a crash, a watchdog kill, a killed Claude run) still counts at least 1 turn** toward the 40-turn
ceiling: the scheduler counts 1 turn at dispatch of every invocation, then reconciles with `result.turns` when a `result`
arrives and that number is larger. The count never goes down, so no failure path can make a run free.

## Event schema

`docs/spec/event.schema.json` (JSON Schema 2020-12). Every event has `type`, `provider`, `seq` (the 1-based raw input line;
several events can share one line), `ts` (string or null; the normalizers leave null unless `--arg ts` is given) and `raw`
(the raw key it came from). Types: `session_started`, `message`, `tool_call`, `tool_result`, `warning`, `limit_notice`,
`rate_limited`, `error`, `result`, `exited`, `unknown`. Field details are in the schema.

Rules fixed by the schema and the mappings below:

- `limit_notice` (status `allowed` or `allowed_warning`) is routine information. It is never a limit hit and never counts
  toward rule 10 backoff.
- `rate_limited` is a limit hit, or a limit state this spec does not know (fail safe, human decision 2026-10-26). It carries
  `raw_kind`, and `reset_at` (epoch seconds) or `retry_after_s` when the CLI gave them.
- `result` always has a numeric `turns` and five numeric token fields (rule 1 accounting). `tokens_known` is false when the
  CLI reported no usage (a failed Codex turn), and the five fields are then 0. `cost_usd` is a number or null.
  `cost_is_estimate` is always true for subscription logins (human decision 2026-10-26).
- `unknown` carries `raw_type` and the key names only, never values. Anything that is neither mapped nor ignored is
  `unknown`; the hand-off from an observed capture to a mapping row is a change to this document and the jq file together.

## Mapping, Claude Code (`claude -p --output-format stream-json --verbose`)

Source column: **observed** = seen in a real run (Claude Code 2.1.310, the human's Mac, 2026-10-26; fixtures stay synthetic);
**from docs** = taken from the official documentation or the SDK message types, not seen yet. Captures win over docs.

| Raw key | Source | Becomes | Notes |
|---|---|---|---|
| `system/init` | observed | `session_started{session_id}` | tool, MCP, plugin and skill lists and `cwd` are never copied |
| `assistant:text` | observed | `message{role:"assistant", text, truncated}` | text clipped to 4000 |
| `assistant:tool_use` | observed | `tool_call{id, name}` | the tool input is never copied |
| `user:tool_result` | observed | `tool_result{id, is_error}` | content is never copied |
| `assistant` with `error` = `rate_limit` | from docs | `rate_limited{raw_kind:"claude_assistant_rate_limit"}` | no reset information in this shape |
| `assistant` with any other `error` | from docs | `error{kind, fatal:false, message}` | kind and message are the error code, clipped |
| `rate_limit_event`, status `allowed` or `allowed_warning` | observed (`allowed`); `allowed_warning` from docs | `limit_notice{status, utilization?, reset_at?}` | routine; `reset_at` = `resetsAt` |
| `rate_limit_event`, status `rejected` | from docs | `rate_limited{raw_kind:"claude_rejected", reset_at?}` | `claude_credits_required` when `errorCode` is `credits_required` |
| `rate_limit_event`, any other or missing status | from docs | `rate_limited{raw_kind:"claude_unknown_limit_status", reset_at?}` | fail safe [10] |
| `system/api_retry` | from docs | `warning{kind:"api_retry"}` | the CLI retries by itself; never `rate_limited`, even for status 429 |
| `system/permission_denied` | from docs | `warning{kind:"permission_denied"}` | |
| `result/*` | observed (`result/success`) | `result{is_error, subtype, turns, tokens, tokens_known, cost_usd, cost_is_estimate, stop_reason?, duration_ms?}` | input = `input_tokens`, output = `output_tokens`, cache_read = `cache_read_input_tokens`, cache_write = `cache_creation_input_tokens`, reasoning = 0, turns = `num_turns`, cost = `total_cost_usd`; `is_error` = the field (missing: subtype is not `success`) |
| `result/*` with `is_error` and `api_error_status` 429 | from docs | `rate_limited{raw_kind:"claude_result_429"}` before the `result` | |

Ignored (no event, no `unknown`):

<!-- ignored:claude:start -->
- `system/status`
- `system/thinking_tokens`
- `assistant:thinking`
- `assistant:redacted_thinking`
- `user:text`
- `assistant.message.usage`
<!-- ignored:claude:end -->

`system/thinking_tokens` is observed; the others are from docs. `assistant.message.usage` is a field, not an event: the per-message
usage is skipped because the `result` has the totals.

## Mapping, Codex (`codex exec --json`)

Same Source rules (Codex 0.162.0, observed 2026-10-26). Raw key for items is `item.started:<item type>` or
`item.completed:<item type>`.

| Raw key | Source | Becomes | Notes |
|---|---|---|---|
| `thread.started` | observed | `session_started{session_id}` | `thread_id`; kept on resume |
| `item.started:command_execution`, `:file_change`, `:mcp_tool_call`, `:web_search` | `command_execution` observed (completed); others from docs | `tool_call{id, name}` | name = the item type; command, arguments, paths and output are never copied |
| `item.completed:` of the same four item types | as above | `tool_call` first if none was seen for that id, then `tool_result{id, is_error}` | `is_error`: status `failed`, or a non-zero `exit_code` |
| `item.completed:agent_message` | from docs | `message{role:"assistant", text, truncated}` | agent text is never classified |
| `item.started:error`, `item.completed:error` | observed | `warning{kind:"item_error"}` | one warning per item id. Never `error`, never `rate_limited`: config warnings arrived as items during a successful run |
| `turn.completed` | observed | `result{is_error:false, turns:1, tokens, tokens_known, cost_usd:null, cost_is_estimate:true}` | input = `input_tokens`, output = `output_tokens`, cache_read = `cached_input_tokens`, cache_write = `cache_write_input_tokens`, reasoning = `reasoning_output_tokens` (all five seen) |
| `turn.failed` | from docs | `error{kind:"turn_failed", fatal:true}` then `result{is_error:true, turns:1, tokens 0, tokens_known:false}` | |
| `error` | from docs | `error{kind:"stream_error", fatal:true}` | |

On the two fatal carriers (`turn.failed`, top-level `error`) only, a message that matches T-003's rate-limit text heuristic
first emits `rate_limited{raw_kind:"codex_text_hint"}`. The heuristic is `ratelimit_text` in `spike/codex/parse.jq`; the
same line is in `spike/normalize/codex.jq` and the test proves they are identical. It is a hint with known false positives
and false negatives; exit status stays the other signal. Agent text and item errors are never classified.

Ignored (no event, no `unknown`):

<!-- ignored:codex:start -->
- `turn.started`
- `item.updated`
- `item.started:agent_message`
- `item.started:reasoning`
- `item.started:todo_list`
- `item.completed:reasoning`
- `item.completed:todo_list`
<!-- ignored:codex:end -->

Every `item.updated` is ignored whatever its item type.

## Unknown, malformed and hostile input

- A type this spec neither maps nor ignores becomes `unknown{raw_type, keys}` (key names only). Types that exist only in
  documentation (hooks, tasks, compaction, `system/api_error`, `system/model_fallback`, and so on) stay `unknown` until a
  capture shows them and a row is added here.
- A line that is not JSON, or JSON that is not an object, becomes `unknown` with `raw_type` `malformed_line`.
- A mapped event whose required field is missing or the wrong type (for example `system/init` without a `session_id`) becomes
  `unknown`.
- Text: control characters except newline and tab become spaces; message text is clipped to 4000 characters
  (`truncated:true` when clipped), all other text to 300, names and ids to 64 and 100. Nothing is ever executed.
- Never copied into any event: init tool, MCP, plugin and skill lists, `cwd`, tool inputs, commands, file paths.

## Normalizers (the executable reference)

```
jq -c -n -R [--arg ts T] [--argjson exit_code N] [--arg signal S] -f spike/normalize/<cli>.jq < raw.jsonl
```

- Reads stdin only (no `import`, `include`, `$ENV`, `env` or `input_filename`). Never exits non-zero on bad input.
- `--argjson exit_code N` (and optionally `--arg signal S`) appends one `exited` event last, with `seq` = line count + 1.
- Each file defines `mapped_keys` and `ignored_keys`; `--arg dump keys` prints them. The ignored lists above equal them.
- `spike/normalize/expected/<cli>-<fixture>.jsonl` is the golden output for each committed fixture (`spike/fixtures/<cli>/*`
  and `spike/fixtures/normalize/<cli>-*`). T-121 and T-122 compare their Rust output with these files, byte for byte after
  re-serialization.
- Any `spike/fixtures/{claude,codex}/observed*.jsonl` the human adds is checked automatically (0 `unknown`, one successful
  `result`, 0 `rate_limited`, numeric tokens). A new raw type in a capture fails the test until a row is added here and in
  the jq file.
