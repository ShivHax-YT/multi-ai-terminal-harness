# claude.jq: normalize one Claude Code headless run (stream-json) into the events of docs/spec/event.schema.json (T-004).
#
#   jq -c -n -R [--arg ts T] [--argjson exit_code N] [--arg signal S] -f spike/normalize/claude.jq < raw.jsonl
#
# One output line per normalized event. Reads stdin only. Never fails: a line that is not JSON, or not a JSON object, becomes
# an `unknown` event (raw_type malformed_line); a missing or mistyped field falls back to a safe default or drops the event
# to `unknown`. Everything taken from the stream is untrusted data: control characters except newline and tab become spaces,
# message text is clipped to 4000 characters, every other text to 300 (names and kinds to 64 or 100). Never copied into any
# event: the init tool, MCP, plugin and skill lists, cwd, tool inputs, paths, commands.
#
# Mapping and the ignored list: docs/spec/adapter-interface.md (the ignored list there must equal `ignored_keys` here; the
# test spike/tests/test_normalize.sh checks it). `--arg dump keys` prints {mapped_keys, ignored_keys} instead (used by the test).
# Raw key = `type` or `type/subtype`; content blocks are `assistant:text`, `user:tool_result`, and so on.
# Written for jq 1.6 and later.

def mapped_keys: [
  "system/init", "system/api_retry", "system/permission_denied",
  "assistant", "assistant:text", "assistant:tool_use",
  "user:tool_result",
  "rate_limit_event",
  "result/*"
];
def ignored_keys: [
  "system/status", "system/thinking_tokens",
  "assistant:thinking", "assistant:redacted_thinking",
  "user:text",
  "assistant.message.usage"
];

def clean: gsub("[\u0000-\u0008\u000b-\u001f\u007f-\u009f]"; " ");
# cut to the limit first, then clean: gsub on a long untrusted string is quadratic, and cleaning keeps the length
def clip($n): if type == "string" then (.[0:$n] | clean) else null end;
def isobj: type == "object";
def num: if type == "number" then . else null end;
def intn: if type == "number" then floor else null end;
def int0: if type == "number" and . >= 0 then floor else 0 end;
def nstr: if type == "number" then (floor | tostring) else "?" end;
def dropnull: with_entries(select(.value != null));
def inl($list): . as $x | any($list[]; . == $x);

def ev($seq; $etype; $raw; $fields):
  {type: $etype, provider: "claude", seq: $seq,
   ts: ($ARGS.named.ts | if type == "string" then . else null end), raw: $raw} + $fields;

def unknown_ev($seq; $rawtype; $o):
  ($rawtype | clip(64)) as $r
  | ev($seq; "unknown"; $r; {raw_type: $r, keys: (if $o | isobj then [$o | keys[:20][] | clip(40)] else [] end)});

# ---- content blocks ------------------------------------------------------------------------------------------------------
def blocks($m):
  (if ($m | isobj) then $m.content else null end) as $c
  | if ($c | type) == "string" then [{type: "text", text: $c}]
    elif ($c | type) == "array" then $c
    else null end;

def block_events($seq; $who):
  . as $b
  | if ($b | isobj | not) or (($b.type | type) != "string") then unknown_ev($seq; $who + ":invalid_block"; null)
    else ($who + ":" + ($b.type | clip(40))) as $k
    | if $k == "assistant:text" then
        ev($seq; "message"; $k; {role: "assistant", text: ($b.text | clip(4000) // ""),
                                 truncated: ((($b.text | type) == "string") and (($b.text | length) > 4000))})
      elif $k == "assistant:tool_use" then
        ev($seq; "tool_call"; $k; {id: ($b.id | clip(100) // ""), name: ($b.name | clip(64) // "")})
      elif $k == "user:tool_result" then
        ev($seq; "tool_result"; $k; {id: ($b.tool_use_id | clip(100) // ""), is_error: ($b.is_error == true)})
      elif ($k | inl(ignored_keys)) then empty
      else unknown_ev($seq; $k; $b)
      end
    end;

def assistant_events($seq; $o):
  ( if ($o.error | type) == "string" then
      if $o.error == "rate_limit" then ev($seq; "rate_limited"; "assistant"; {raw_kind: "claude_assistant_rate_limit"})
      else ev($seq; "error"; "assistant"; {kind: ($o.error | clip(64)), fatal: false, message: ($o.error | clip(300))})
      end
    else empty end ),
  ( blocks($o.message) as $bs
    | if $bs == null then (if ($o.error | type) == "string" then empty else unknown_ev($seq; "assistant:no_content"; $o) end)
      else $bs[] | block_events($seq; "assistant") end );

def user_events($seq; $o):
  blocks($o.message) as $bs
  | if $bs == null then unknown_ev($seq; "user:no_content"; $o)
    else $bs[] | block_events($seq; "user") end;

# ---- limits --------------------------------------------------------------------------------------------------------------
# Only allowed and allowed_warning are notices. rejected is a limit. Any other or missing status is treated as a limit too
# (fail safe, hard rule 10; human decision 2026-10-26).
def limit_event_events($seq; $o):
  ($o.rate_limit_info) as $i
  | (if $i | isobj then $i else {} end) as $info
  | ({reset_at: ($info.resetsAt | intn)} | dropnull) as $reset
  | $info.status as $s
  | if $s == "allowed" or $s == "allowed_warning" then
      ev($seq; "limit_notice"; "rate_limit_event"; {status: $s} + ({utilization: ($info.utilization | num)} | dropnull) + $reset)
    elif $s == "rejected" then
      ev($seq; "rate_limited"; "rate_limit_event";
         {raw_kind: (if $info.errorCode == "credits_required" then "claude_credits_required" else "claude_rejected" end)} + $reset)
    else
      ev($seq; "rate_limited"; "rate_limit_event"; {raw_kind: "claude_unknown_limit_status"} + $reset)
    end;

def result_events($seq; $o; $rk):
  (if ($o.usage | isobj) then $o.usage else {} end) as $u
  | (if ($o.is_error | type) == "boolean" then $o.is_error else ($o.subtype != "success") end) as $err
  | ($o.api_error_status | if type == "string" then (try tonumber catch null) else . end) as $status
  | ( if $err and $status == 429 then ev($seq; "rate_limited"; $rk; {raw_kind: "claude_result_429"}) else empty end ),
    ev($seq; "result"; $rk;
       {is_error: $err}
       + ({subtype: ($o.subtype | clip(64))} | dropnull)
       + {turns: ($o.num_turns | int0),
          tokens: {input: ($u.input_tokens | int0), output: ($u.output_tokens | int0),
                   cache_read: ($u.cache_read_input_tokens | int0), cache_write: ($u.cache_creation_input_tokens | int0),
                   reasoning: 0},
          tokens_known: ((($u.input_tokens | type) == "number") and (($u.output_tokens | type) == "number")),
          cost_usd: ($o.total_cost_usd | num),
          cost_is_estimate: true}
       + ({stop_reason: ($o.stop_reason | clip(64)), duration_ms: (if ($o.duration_ms | type) == "number" and $o.duration_ms >= 0 then ($o.duration_ms | floor) else null end)} | dropnull));

# ---- one JSON object -----------------------------------------------------------------------------------------------------
def claude_events($seq):
  . as $o
  | ($o.type) as $t
  | ($o.subtype) as $st
  | ( if ($t | type) != "string" then "invalid_type"
      elif ($t == "system" or $t == "result") and ($st | type) == "string" then ($t + "/" + $st)
      else $t end
      | clip(64) | if . == "" then "empty_type" else . end ) as $rk
  | if $rk == "system/init" then
      (if ($o.session_id | type) == "string" and ($o.session_id | length) > 0
       then ev($seq; "session_started"; $rk; {session_id: ($o.session_id | clip(100))})
       else unknown_ev($seq; $rk; $o) end)
    elif $rk == "system/api_retry" then
      ev($seq; "warning"; $rk; {kind: "api_retry",
         message: ("attempt \($o.attempt | nstr) of \($o.max_retries | nstr), status \($o.error_status | nstr), error \($o.error | clip(64) // "?")" | clip(300))})
    elif $rk == "system/permission_denied" then
      ev($seq; "warning"; $rk; {kind: "permission_denied", message: ("tool \($o.tool_name | clip(64) // "?")" | clip(300))})
    elif ($rk | inl(ignored_keys)) then empty
    elif $t == "assistant" then assistant_events($seq; $o)
    elif $t == "user" then user_events($seq; $o)
    elif $t == "rate_limit_event" then limit_event_events($seq; $o)
    elif $t == "result" then result_events($seq; $o; $rk)
    else unknown_ev($seq; $rk; $o)
    end;

def normalize_line($seq):
  (try {ok: fromjson} catch {bad: true}) as $p
  | if $p.bad then unknown_ev($seq; "malformed_line"; null)
    elif ($p.ok | isobj | not) then unknown_ev($seq; "malformed_line"; null)
    else $p.ok | claude_events($seq) end;

def exit_events($n):
  ($ARGS.named.exit_code) as $c
  | ($ARGS.named.signal) as $sg
  | if ($c | type) == "number" or ($sg | type) == "string" then
      ev($n + 1; "exited"; "process_exit";
         ({code: (if ($c | type) == "number" then ($c | floor) else null end),
           signal: (if ($sg | type) == "string" then ($sg | clip(32)) else null end)} | dropnull))
    else empty end;

if $ARGS.named.dump == "keys" then {mapped_keys: mapped_keys, ignored_keys: ignored_keys}
else
  [inputs] as $lines
  | ( $lines | to_entries[]
      | (.key + 1) as $seq
      | .value as $line
      | select($line | test("^[ \t\r]*$") | not)
      | ($line | normalize_line($seq)) ),
    exit_events($lines | length)
end
