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
- `native_turn_cap`: the CLI can cap turns inside one invocation by itself (Claude `--max-turns`; Codex has none). Claude's
  native cap is what makes the turn reservation enforceable: the scheduler passes the reserved number as `--max-turns` and
  the CLI itself stops there. Codex has no native cap; 1 turn per `exec` call is the approved rule (human decision
  2026-10-26) and the 120 s watchdog bounds one call. The scheduler enforces rule 1's 40 turns per task regardless; see
  "Turns" under the state machine.

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
  --permission-mode acceptEdits --max-turns 5`, where 5 is the adapter default that the scheduler may only lower, see "Turns";
  Codex: `exec --json --sandbox workspace-write -C <worktree>`), resume by id.
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

**Triggers.** A trigger is one of the 11 normalized event types, or one of four commands: `start` (row 1), `send(prompt)`,
`cancel()` (the watchdog calls it too) and `resume` (backoff over, or the user resumes). Rows 3 to 7 and 11 say "child ends":
that trigger is the **`exited` event** (`exited{code?, signal?}`), which the adapter appends when the process is reaped. It
is the only event that applies the end-of-invocation precedence below. (`exited` is both an event name and a state name; a
row says "`exited` event" when it means the trigger.)

| # | From | Trigger | To | Notes |
|---|---|---|---|---|
| 1 | (none) | child process started (`start`, or `send` from `idle`) | `spawning` | the invocation flags are empty |
| 2 | `spawning` | `session_started` | `running` | a resumed invocation announces the same id again |
| 3 | `spawning` | `exited` event before `session_started`, no `rate_limited` seen | `exited` | |
| 4 | `running` | `exited` event with exit code 0 and no signal, a `result{is_error:false}` seen, no `rate_limited` seen | `idle` | resumable |
| 5 | `running` | `exited` event after a `result{is_error:true}` seen, no `rate_limited` seen | `exited` | whatever the exit code |
| 6 | `running` | `exited` event without any `result`, no `rate_limited` seen | `exited` | includes a non-zero exit, a crash, a kill from outside the adapter (neither `cancel()` nor the watchdog, which are row 10), and a Codex bare top-level `error` |
| 7 | `spawning`, `running` | `rate_limited` seen (any number of times) | stays in that state; sets the invocation's `limit_seen` flag; when the child ends (the `exited` event) the state becomes `rate_limited` | counted once per invocation; later ones only raise `reset_at`; a `rate_limited` seen while `spawning` is not lost |
| 8 | `rate_limited` | backoff over (rule 10) or the user resumes (`resume`) | `idle` | the scheduler decides; a limit never starts a new session on the same provider [2] |
| 9 | `idle` | `send(prompt)` | `spawning` | next invocation, resume by id; the invocation flags are empty |
| 10 | `spawning`, `running`, `idle`, `rate_limited` | `cancel()` or watchdog | `killed` | the adapter feeds no further event of that child to the function (not even its `exited` event), but it still reaps the child and drains its stdout and stderr to EOF (no zombie process, no blocked pipe); the invocation flags are dropped; the turn reservation stays |
| 11 | `running` | `result{is_error:false}` seen, then a non-zero exit or death by a signal that was not a `cancel()`, no `rate_limited` seen | `exited` | the invocation's `is_error` is derived from the exit code or signal (true); the `result` event itself is not rewritten; an `exited` event with neither code nor signal is not a clean exit either |
| 12 | `spawning` | `warning`, `limit_notice`, `unknown`, `error{fatal:false}` | `spawning` | routine; no flag changes |
| 13 | `spawning` | `error{fatal:true}` | `spawning` | decision: a fatal error is information, not an exit; the state changes only when the child ends (row 3, or row 7 when `limit_seen`), because the `rate_limited` that a Codex limit message emits before its `error` must still win at exit |
| 14 | `running` | `message`, `tool_call`, `tool_result`, `warning`, `limit_notice`, `error` (fatal or not), `unknown` | `running` | routine; no flag changes |
| 15 | `running` | `result{is_error}` | `running` | sets `result_seen` and `is_error`; with several `result` events the last one counts for the flags (its `is_error` replaces the earlier one); the turns settle separately, on the highest known number (see "Turns") |
| 16 | `exited`, `killed` | `cancel()` or watchdog | unchanged | idempotent no-op, so a second `cancel()` is not an error |

**Illegal transitions.** Any other (state, trigger) pair is an illegal transition and an error in T-120's pure transition
function; it changes neither the state nor the flags. The ones that matter, listed explicitly:

- `session_started` while in `running` (it is legal only in `spawning`, row 2), or in any state with no child.
- `message`, `tool_call`, `tool_result` and `result` while in `spawning` (they come after `session_started`).
- Every normalized event, including the `exited` event, while in `idle` or `rate_limited` (no child is running), and in
  `exited` or `killed` (events after a terminal state).
- `send(prompt)` in any state but `idle`; `resume` in any state but `rate_limited`; `start` when a state already exists.
- `cancel()` is legal in every state that exists (rows 10 and 16). Before row 1 there is no state and nothing to cancel, so
  `cancel()` with no state is illegal.

**Invocation flags.** Rows 7 and 15 need memory that a single event cannot give: whether a `rate_limited` was seen earlier in
this invocation, and what the `result` said. The transition function therefore takes `(state, event, invocation_flags)` and
returns the new state and the new flags, not `(state, event)`. The flags are `limit_seen` (with the highest `reset_at` seen),
`result_seen` and `is_error` (that of the last `result`); they start empty at row 1 or 9 and are dropped when the invocation
ends. Only rows 7 and 15 change them. An invocation ends at the `exited` event (rows 3 to 7 and 11) or at `cancel()` of a live
invocation (row 10); the function then returns empty flags. The scheduler takes the highest `reset_at` for its backoff from the
`rate_limited` events themselves, not from the flags, which are gone by then.

**Precedence when the child ends.** The `exited` event applies it. `limit_seen` wins over rows 3 to 6 and 11: an invocation in
which a limit was seen ends in `rate_limited` even when it also produced a successful or failed `result`, produced no
`result` at all (a Codex limit `error` with no `turn.failed`), or ended before `session_started`. Without `limit_seen`, the
rows apply in this order: 3, 11, 4, 5, 6 (a `result{is_error:false}` with a non-zero exit or a signal is row 11, never
row 4). The `result` events and `error` events of the stream are not rewritten by any of this.

Proof: `spike/tests/test_normalize.sh` carries a jq reference `transition(state; event; flags)` that implements this table and
nothing more, replays every fixture's normalized output (plus an appended `exited` event) through it, and asserts no illegal
transition and the expected end state of each fixture.

**Turns (rule 1: never more than 40 per task).** `result.turns` is the number of turns used by that invocation: for Claude
the `num_turns` of its `result`; for Codex 1 per `exec` call (human decision 2026-10-26; the 120 s watchdog bounds one call).
`result.turns_known` is true only when that number is real: for Claude only when `num_turns` is a number of at least 0
(missing, a string or a negative number gives `turns_known` false and `turns` 0); for Codex always. A Claude call can use up to
its `--max-turns`, so the scheduler (T-124) does not count after the fact; it reserves before it dispatches. The task's count is
always turns used plus turns reserved:

- **Atomic check and reserve.** For one task, computing the remainder, deciding to dispatch or refuse, and recording the
  reservation are one serialized step (one lock per task, nothing can run between the check and the record). Two concurrent
  dispatches can never both reserve against the same count.
- **Reserve at dispatch.** Before every invocation the scheduler reserves that invocation's maximum: for Claude its
  `--max-turns` value, for Codex 1.
- **Cap Claude to what is left.** For Claude, `--max-turns` is set to min(5, 40 minus turns already used or reserved), where 5
  is the adapter default. A Claude invocation is never started with `--max-turns` 0 (or less): the value is always at least
  1, because the next bullet refuses the dispatch before it could be lower.
- **Refuse when nothing fits.** The scheduler refuses the dispatch (no child process is started) when the reservation does
  not fit under 40: for Claude and for Codex alike when 40 minus turns already used or reserved is 0 or less.
- **A result settles the count, once, when the invocation ends.** Settlement happens at the end of the invocation (its
  `exited` event or the reap after `cancel()`), never while the child still runs, so freed turns can never be reserved by
  another dispatch before a later, higher `result` arrives. The reservation is then replaced by max(1, the highest `turns`
  among the invocation's `result` events that have `turns_known` true). If any `result` of the invocation has `turns_known`
  false, the count is max(the reservation, that highest known `turns`): a mix of known and unknown results never frees turns. The highest counts, not the last, so a later `result`
  can never lower what an earlier one already counted: once settled, the count of an invocation never goes down. A result that
  is an error still counts its turns. A settled number above the reservation (the CLI overshot its own cap) is counted as
  reported and shrinks what the next dispatch can get. The `is_error` flag still follows the last `result` (row 15); the two
  rules are independent.
- **No usable result keeps the reservation.** When no `result` arrives (a crash, the watchdog, `cancel()`, a Codex bare
  top-level `error`), or every `result` has `turns_known` false, the full reservation stays counted: a `result` with
  `turns_known` false is treated exactly as if no result had arrived. No failure path can make a run cheaper than its
  reservation.
- **The count belongs to the task.** The 40 turns are counted per task, not per provider or session, and carry across a
  failover to another provider: a failover never resets the count (fail-safe reading; round 5 decision C, confirmed by the
  human 2026-10-27).

Worked example. At 38 turns used, Claude gets `--max-turns` 2 (min(5, 40 minus 38)). At 40 turns used or reserved, nothing
is dispatched. A Claude call reserved at 5 and killed before its `result` counts 5. A Claude call reserved at 5 whose `result`
says `num_turns` 2 counts 2, which frees 3 for the next call. A Claude call reserved at 5 whose `result` has no `num_turns`
(`turns_known` false) counts 5. At 38 used, Claude is given 2 and reports `num_turns` 3: 41 is counted as reported, 40 minus 41
is -1, which is 0 or less, and the next dispatch is refused.

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
- `result` always has a numeric `turns`, a boolean `turns_known` and five numeric token fields (rule 1 accounting).
  `turns_known` is false when Claude's `num_turns` is missing, not a number or negative (`turns` is then 0, and the scheduler
  keeps the full turn reservation, see "Turns"); for Codex it is always true. `tokens_known` is false when the
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
| `assistant` with any other `error` | from docs | `error{kind, fatal:false, message}` | kind and message are the error code, clipped; an empty error string gives kind `unknown_error` (kind is never empty) and an empty message |
| `rate_limit_event`, status `allowed` or `allowed_warning` | observed (`allowed`); `allowed_warning` from docs | `limit_notice{status, utilization?, reset_at?}` | routine; `reset_at` = `resetsAt` |
| `rate_limit_event`, status `rejected` | from docs | `rate_limited{raw_kind:"claude_rejected", reset_at?}` | `claude_credits_required` when `errorCode` is `credits_required` |
| `rate_limit_event`, any other or missing status | from docs | `rate_limited{raw_kind:"claude_unknown_limit_status", reset_at?}` | fail safe [10] |
| `system/api_retry` | from docs | `warning{kind:"api_retry"}` | the CLI retries by itself; never `rate_limited`, even for status 429 |
| `system/permission_denied` | from docs | `warning{kind:"permission_denied"}` | |
| `result/*` | observed (`result/success`) | `result{is_error, subtype, turns, turns_known, tokens, tokens_known, cost_usd, cost_is_estimate, stop_reason?, duration_ms?}` | input = `input_tokens`, output = `output_tokens`, cache_read = `cache_read_input_tokens`, cache_write = `cache_creation_input_tokens`, reasoning = 0, turns = `num_turns` (`turns_known` true only when it is a number >= 0, else turns 0 and `turns_known` false), cost = `total_cost_usd`; `is_error` = the field (missing: subtype is not `success`) |
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
| `turn.completed` | observed | `result{is_error:false, turns:1, turns_known:true, tokens, tokens_known, cost_usd:null, cost_is_estimate:true}` | input = `input_tokens`, output = `output_tokens`, cache_read = `cached_input_tokens`, cache_write = `cache_write_input_tokens`, reasoning = `reasoning_output_tokens` (all five seen) |
| `turn.failed` | from docs | `error{kind:"turn_failed", fatal:true}` then `result{is_error:true, turns:1, turns_known:true, tokens 0, tokens_known:false}` | |
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
  `unknown` with the raw key as `raw_type` (for example `assistant:tool_use`) and the key names of the object. The required
  fields are: `session_id` / `thread_id` (a non-empty string); Claude `assistant:text` `text` (a string; an empty string is
  valid); `assistant:tool_use` `id` and `name`, and `user:tool_result` `tool_use_id` (non-empty strings); Codex
  `item.completed:agent_message` `text` (a string; an empty string is valid). A Codex tool item without an id is not
  malformed: it gets the id `line<N>` (N = the raw line of its `item.completed`; its `item.started` without an id is dropped), so its call and result match.
- By design, `error` and `warning` events keep an empty `message` (and an `error` with no message text is still an `error`):
  a fatal error must never degrade to `unknown` because its text is missing, since the state machine and the rate-limit
  precedence depend on seeing it. Their `kind` is never empty (the schema says `minLength` 1; an empty Claude `assistant` error
  string gives kind `unknown_error`), and `tool_call` `id` and `name` and `tool_result` `id` are never empty either.
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
