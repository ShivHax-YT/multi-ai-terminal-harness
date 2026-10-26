# Claude Code headless events (`claude -p --output-format stream-json --verbose`)

Status: **every row below is "from docs" or "seen in binary, not observed"**. No live capture exists yet (the human runs `SPIKE_LIVE=1 spike/claude/run.sh` on
the Mac). After that run, add `spike/fixtures/claude/observed.jsonl` (the `spike_redact` of the real capture, reviewed by
the human) and change the Source column to **observed** for the rows that appeared.

Sources (official Claude Code docs; the binary was not run to get any of this. The few rows marked "seen in binary" come from strings a reviewer found in the 2.1.295 binary):

- Headless / `-p` and stream-json: https://code.claude.com/docs/en/headless (stream format, `system/api_retry`, `system/init`,
  `--resume`, permission modes)
- CLI flags: https://code.claude.com/docs/en/cli-reference (`--max-turns` "print mode only", which `claude --help` 2.1.295 hides, see "Flags used by the spike"; `--permission-mode`, `--resume`,
  `--output-format`, `--verbose`, `--include-partial-messages`)
- Message types and fields: https://code.claude.com/docs/en/agent-sdk/typescript (`SDKMessage` union, `SDKResultMessage`,
  `SDKRateLimitEvent`, `SDKSystemMessage`, `SDKAssistantMessage`, `Usage`). The headless page says stream-json lines are these
  messages, so the shapes are taken from there; the exact CLI output may differ and must be confirmed by the live run.
- Usage-limit wording: https://code.claude.com/docs/en/errors (section "Usage limits")

Not provoked: no rate limit or usage limit was or will be triggered to learn these shapes (hard rules 1, 2, 10).

All text fields (assistant text, `result`, `errors`, tool output, hook output) are untrusted data. `parse.jq` copies only bounded,
control-character-free excerpts and never interprets them.

## Event table

Key = `type/subtype` (or just `type` when there is no subtype), as used in `parse.jq` `event_counts`. "In fixtures" = which
hand-written file contains it. Examples are one line, redacted (`<ID>`, `<WORKTREE>`), shortened with `...`.

| Key | Source | In fixtures | One-line example |
|---|---|---|---|
| `system/init` | from docs (headless, SDKSystemMessage) | sample, limits | `{"type":"system","subtype":"init","session_id":"<ID>","cwd":"<WORKTREE>","tools":["Write",...],"model":"...","permissionMode":"acceptEdits",...}` first event; carries `session_id` |
| `system/status` | from docs (SDKStatusMessage) | sample | `{"type":"system","subtype":"status","status":null,"permissionMode":"acceptEdits","session_id":"<ID>"}` (`status` is `"compacting"` or null) |
| `system/api_retry` | from docs (headless "Handle API retries") | sample, limits | `{"type":"system","subtype":"api_retry","attempt":1,"max_retries":10,"retry_delay_ms":1000,"error_status":529,"error":"overloaded","session_id":"<ID>"}` |
| `rate_limit_event` | from docs (SDKRateLimitEvent) | sample, limits | `{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1790000000,"utilization":0.85},"session_id":"<ID>"}`; `status` is `allowed`, `allowed_warning` or `rejected`; `errorCode:"credits_required"` means the subscription's included usage is exhausted |
| `assistant` | from docs (SDKAssistantMessage) | sample, limits | `{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","name":"Write","input":{...}}],"usage":{...}},"session_id":"<ID>"}`; optional `error` (see below) |
| `user` | from docs (SDKUserMessage) | sample | `{"type":"user","parent_tool_use_id":null,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"...","content":"..."}]},"session_id":"<ID>"}` (tool results come back as user messages) |
| `result/success` | from docs (SDKResultMessage) | sample | `{"type":"result","subtype":"success","is_error":false,"num_turns":2,"duration_ms":4200,"result":"DONE","total_cost_usd":0.0123,"usage":{"input_tokens":300,"output_tokens":49,...},"session_id":"<ID>"}` last line of the stream |
| `result/error_max_turns` | from docs (SDKResultMessage) | limits | `{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":5,"errors":["..."],"terminal_reason":"max_turns","session_id":"<ID>"}` what `--max-turns` produces when hit |
| `result/error_during_execution` | from docs (SDKResultMessage) | none | same envelope as `error_max_turns`; may also carry `api_error_status` (HTTP code) and `startup_failure_reason` |
| `result/error_max_budget_usd` | from docs (SDKResultMessage) | none | same envelope; only with `--max-budget-usd` (not used here) |
| `result/error_max_structured_output_retries` | from docs (SDKResultMessage) | none | same envelope; only with `--json-schema` (not used here) |
| `system/permission_denied` | from docs (SDKPermissionDeniedMessage) | limits | `{"type":"system","subtype":"permission_denied","tool_name":"Bash","tool_use_id":"...","session_id":"<ID>"}`; the final result also lists `permission_denials` |
| `stream_event` | from docs (SDKPartialAssistantMessage) | none | only with `--include-partial-messages` (not used here): `{"type":"stream_event","event":{...},"session_id":"<ID>"}` |
| `system/informational` | from docs | none | `{"type":"system","subtype":"informational","content":"...","level":"warning"}` free text, untrusted |
| `system/compact_boundary` | from docs | none | `{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"auto","pre_tokens":N}}` |
| `system/hook_started`, `system/hook_progress`, `system/hook_response` | from docs | none | hook lifecycle; SessionStart and Setup hooks are always streamed. The scratch repo has no hooks |
| `system/plugin_install` | from docs (headless) | none | only when `CLAUDE_CODE_SYNC_PLUGIN_INSTALL` is set |
| `system/task_started`, `system/task_progress`, `system/task_updated`, `system/task_notification`, `system/background_tasks_changed` | from docs | none | background task / subagent bookkeeping |
| `system/thinking_tokens`, `system/session_state_changed`, `system/files_persisted`, `system/commands_changed`, `system/local_command_output`, `system/conversation_reset`, `system/worker_shutting_down` | from docs (SDK message union) | none | housekeeping; no adapter action |
| `system/model_refusal_fallback`, `system/model_refusal_no_fallback`, `system/control_request_progress` | from docs (SDK message union) | none | refusal and control progress; refusals are reported as limit/error events by `parse.jq` |
| `tool_progress` | from docs (SDKToolProgressMessage) | none | `{"type":"tool_progress","tool_use_id":"...","tool_name":"Bash","elapsed_time_seconds":30}` |
| `tool_use_summary` | from docs | none | `{"type":"tool_use_summary","summary":"...","preceding_tool_use_ids":[...]}` free text |
| `auth_status` | from docs (SDKAuthStatusMessage) | none | `{"type":"auth_status","isAuthenticating":false,"output":[...]}` |
| `prompt_suggestion` | from docs | none | only with `--prompt-suggestions` (not used here) |

### Seen in the binary, not observed (for T-004)

These `system` subtypes were found as strings in the 2.1.295 binary. They are not in the docs and no capture has shown them, so
nothing is known about their fields. `parse.jq` does not list them as known, so a live capture that contains one reports it under
`unknown` (type, subtype and key names only), which is how T-004 should learn their shape. Treat every field as untrusted.

| Key | Source | In fixtures | Note |
|---|---|---|---|
| `system/api_error` | seen in binary, not observed | none | probably an API error notice (compare `system/api_retry`); fields unknown |
| `system/model_fallback` | seen in binary, not observed | none | probably a switch to another model; fields unknown |
| `system/notification` | seen in binary, not observed | none | probably a user-facing notice; free text, untrusted |
| `system/turn_duration` | seen in binary, not observed | none | probably per-turn timing; fields unknown |
| `system/stop_hook_summary` | seen in binary, not observed | none | probably a summary of Stop hooks; the scratch repo has no hooks |

Anything not in the tables above is, by design, reported by `parse.jq` under `unknown` (type, subtype and key names only).

## Rate-limit, usage-exhausted and error shapes (all from docs, none provoked)

| Situation | Where it shows up in the stream | Source |
|---|---|---|
| Usage warning (`allowed_warning`) | `rate_limit_event` with `rate_limit_info.status:"allowed_warning"`, `utilization`, `resetsAt` | SDKRateLimitEvent |
| Limit hit | `rate_limit_event` with `status:"rejected"` and `resetsAt` (epoch seconds) | SDKRateLimitEvent |
| Subscription usage exhausted | `rate_limit_event` with `status:"rejected"`, `errorCode:"credits_required"`, `canUserPurchaseCredits`, `hasChargeableSavedPaymentMethod` (Claude Code 2.1.181 or later) | SDKRateLimitEvent |
| Retryable API error (429 `rate_limit`, 529 `overloaded`, 5xx `server_error`, auth errors) | `system/api_retry` with `error` category, `error_status`, `attempt`, `max_retries`, `retry_delay_ms` | headless "Handle API retries" |
| Error on a message | `assistant` with top-level `error` in: `authentication_failed`, `oauth_org_not_allowed`, `account_on_hold`, `billing_error`, `rate_limit`, `overloaded`, `invalid_request`, `model_not_found`, `server_error`, `max_output_tokens`, `cloud_credential_error`, `unknown` | SDKAssistantMessageError |
| Run ended with an error | `result` with `is_error:true` and `subtype` one of the `error_*` values, optional `api_error_status`, `terminal_reason` | SDKResultMessage |
| Human-readable limit text | Text such as `You've hit your session limit · resets 3:45pm` (also weekly, Opus, Sonnet variants). The docs show the wording, not which JSON field carries it in `-p` mode. **Unconfirmed**: treat as untrusted display text and decide only from the structured fields above | errors "Usage limits" |

Adapter note for T-004: classify `rate_limited` from `rate_limit_event.status == "rejected"`, an `assistant.error == "rate_limit"`,
or a result with `is_error` and `api_error_status == 429`; use `system/api_retry` as a warning only (Claude Code retries by
itself). Rule 10 then applies (back off, never retry the same provider in a loop).

## Flags used by the spike (where each fact came from)

| Flag | Fact | Source |
|---|---|---|
| `-p` / `--print` | headless, non-interactive | cli-reference, headless |
| `--output-format stream-json` with `--verbose` | newline-delimited JSON events; the last line is the `result` | headless "Stream responses" |
| `--max-turns N` | "Limit the number of agentic turns (print mode only). Exits with an error when the limit is reached." Used with 5 (rule 1 ceiling is 40). **Not listed by `claude --help` in 2.1.295**: the flag is hidden from help (hideHelp) but is defined in the binary, so it is accepted. The live run must still confirm the cap is honoured (`result/error_max_turns`) | cli-reference; binary inspection (hidden in help) |
| `--permission-mode acceptEdits` | "Claude writes files without prompting"; other shell commands still need allowed tools. Not `bypassPermissions` | headless "Auto-approve tools" |
| `--resume <session-id>` | continue a specific conversation; `--fork-session` (not used) would create a new id, so the id is expected to be reused | headless "Continue conversations", cli-reference |

Open questions for the live run: does `acceptEdits` alone let the Write tool create `hello.txt` headless (the docs say yes), does
a resumed run keep the permission mode without being told again (the spike passes it again anyway), and does the session id stay the same on resume.
