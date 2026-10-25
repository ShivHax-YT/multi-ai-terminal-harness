# parse.jq: summarise one Claude Code headless run (claude -p --output-format stream-json --verbose).
#
#   jq -Rs -f parse.jq raw.jsonl     raw text in; a line that is not valid JSON is reported in "malformed", never fatal
#   jq -s  -f parse.jq raw.jsonl     already-parsed events in (use only when every line is valid JSON)
#
# Output (one object):
#   session_id          first session id found (init event first), or null
#   session_ids         every distinct session id seen (sorted); resume.sh compares these
#   lines               number of non-blank input lines
#   event_counts        {"<type>/<subtype>": n}  (just "<type>" when the event has no subtype)
#   tool_uses           tool names from assistant tool_use blocks, in order
#   final               fields of the LAST result event (all null when there is none)
#   limit_or_error_events  rate limits, API retries, assistant errors, error results, permission denials, refusals
#   unknown             events this parser does not know (type/subtype/keys only, never the free text)
#   malformed           lines that are not valid JSON ({line, excerpt})
#
# Rules: it never fails on an unknown type (it goes to "unknown"); text fields are untrusted data, so they are only ever
# copied as bounded, control-character-free excerpts and are never interpreted, evaluated or used as a command.
# Written for jq 1.6 and later.

# ---- sanitising helpers -----------------------------------------------------------------------------------------------
def clean($n): if type == "string" then gsub("[\u0000-\u001f\u007f]"; " ") | .[0:$n] else null end;
def num: if type == "number" then . else null end;
def str($n): if type == "string" then clean($n) else null end;

# ---- what this parser recognises (documented shapes; see EVENTS.md) -----------------------------------------------------
def known_top: ["assistant", "user", "result", "system", "stream_event", "rate_limit_event", "tool_progress",
                "tool_use_summary", "auth_status", "prompt_suggestion"];
def known_system: ["init", "api_retry", "compact_boundary", "status", "informational", "plugin_install", "hook_started",
                   "hook_progress", "hook_response", "permission_denied", "worker_shutting_down", "task_started",
                   "task_progress", "task_updated", "task_notification", "background_tasks_changed", "thinking_tokens",
                   "session_state_changed", "files_persisted", "commands_changed", "local_command_output",
                   "model_refusal_fallback", "model_refusal_no_fallback", "control_request_progress",
                   "conversation_reset"];
def known_result: ["success", "error_max_turns", "error_during_execution", "error_max_budget_usd",
                   "error_max_structured_output_retries"];

def is_known:
  (.type as $t | known_top | index($t)) != null
  and (if .type == "system" then (.subtype as $s | known_system | index($s)) != null
       elif .type == "result" then (.subtype as $s | known_result | index($s)) != null
       else true end);

def evlabel: if (.subtype | type) == "string" then "\(.type)/\(.subtype)" else "\(.type)" end;

# ---- read the input: raw text (-R) or an array of events (-s) ------------------------------------------------------------
def entries:
  if type == "string" then
    [split("\n") | to_entries[] | select(.value | test("[^ \t\r]"))
     | . as $e
     | try {line: ($e.key + 1), ok: ($e.value | fromjson)}
       catch {line: ($e.key + 1), bad: ($e.value | clean(80))}]
  elif type == "array" then
    [to_entries[] | {line: (.key + 1), ok: .value}]
  else
    [{line: 1, ok: .}]
  end;

def usage_of: (.usage? // null) as $u
  | if ($u | type) == "object" then
      {input_tokens: ($u.input_tokens | num), output_tokens: ($u.output_tokens | num),
       cache_creation_input_tokens: ($u.cache_creation_input_tokens | num),
       cache_read_input_tokens: ($u.cache_read_input_tokens | num)}
    else {input_tokens: null, output_tokens: null, cache_creation_input_tokens: null, cache_read_input_tokens: null} end;

def limit_event($line):
  if .type == "rate_limit_event" then
    (.rate_limit_info // {}) as $i
    | if ($i | type) == "object" and ($i.status == "allowed_warning" or $i.status == "rejected") then
        {line: $line, kind: "rate_limit_event", status: ($i.status | str(32)), resetsAt: ($i.resetsAt | num),
         utilization: ($i.utilization | num), errorCode: ($i.errorCode | str(64))}
      else empty end
  elif .type == "system" and .subtype == "api_retry" then
    {line: $line, kind: "api_retry", error: (.error | str(64)), error_status: (.error_status | num),
     attempt: (.attempt | num), max_retries: (.max_retries | num), retry_delay_ms: (.retry_delay_ms | num)}
  elif .type == "assistant" and (.error | type) == "string" then
    {line: $line, kind: "assistant_error", error: (.error | str(64))}
  elif .type == "result" and (.is_error == true or ((.subtype | type) == "string" and .subtype != "success")) then
    {line: $line, kind: "result_error", subtype: (.subtype | str(64)), is_error: (.is_error == true),
     api_error_status: (.api_error_status | num), terminal_reason: (.terminal_reason | str(64)),
     errors: (if (.errors | type) == "array" then [.errors[:5][] | str(200)] else [] end)}
  elif .type == "system" and (.subtype == "permission_denied" or .subtype == "model_refusal_fallback"
                              or .subtype == "model_refusal_no_fallback") then
    {line: $line, kind: .subtype, tool_name: (.tool_name | str(64))}
  else empty end;

def final_of($r):
  {subtype: ($r.subtype | str(64)),
   is_error: (if ($r.is_error | type) == "boolean" then $r.is_error else null end),
   num_turns: ($r.num_turns | num), duration_ms: ($r.duration_ms | num), usage: ($r | usage_of),
   total_cost_usd: ($r.total_cost_usd | num), stop_reason: ($r.stop_reason | str(64)),
   terminal_reason: ($r.terminal_reason | str(64)), result_excerpt: ($r.result | str(200))};

def tools_of: select(.type == "assistant") | (.message.content? // [])
  | if type == "array" then .[] else empty end
  | select(type == "object" and .type == "tool_use") | (.name | str(64)) | select(. != null);

(entries) as $all
| ([$all[] | select(has("ok")) | {line, e: .ok}]) as $evs
| ([$evs[] | select(.e | type == "object")]) as $objs
| ($objs | map(.e)) as $objects
| ([$objects[] | .session_id | str(100)] | map(select(. != null))) as $sids
| ([$objects[] | select(.type == "system" and .subtype == "init") | .session_id | str(100)] | map(select(. != null))) as $init_sids
| (([$objects[] | select(.type == "result")] | last) // {}) as $final
| {
    session_id: (($init_sids + $sids) | first),
    session_ids: ($sids | unique),
    lines: ($all | length),
    event_counts: ([$objects[] | select((.type | type) == "string") | (evlabel | clean(100))]
                   | group_by(.) | map({key: .[0], value: length}) | from_entries),
    tool_uses: [$objects[] | tools_of],
    final: final_of($final),
    limit_or_error_events: [$objs[] | .line as $l | .e | limit_event($l)],
    unknown: [$evs[] | select(((.e | type) != "object") or (.e | is_known | not))
              | .line as $l | .e
              | if type == "object" then
                  {line: $l, type: (.type | str(64)), subtype: (.subtype | str(64)), keys: ([keys[:20][] | clean(40)])}
                else {line: $l, type: ("non-object " + type)} end],
    malformed: [$all[] | select(has("bad")) | {line, excerpt: .bad}]
  }
