# codex.jq: normalize one `codex exec --json` run into the events of docs/spec/event.schema.json (T-004).
#
#   jq -c -n -R [--arg ts T] [--argjson exit_code N] [--arg signal S] -f spike/normalize/codex.jq < raw.jsonl
#
# One output line per normalized event. Reads stdin only. Never fails: a line that is not JSON, or not a JSON object, becomes
# an `unknown` event (raw_type malformed_line); a missing or mistyped field falls back to a safe default or drops the event
# to `unknown`. Everything taken from the stream is untrusted data: control characters except newline and tab become spaces,
# message text is clipped to 4000 characters, every other text to 300 (names and kinds to 64 or 100). Never copied into any
# event: commands, file paths, tool arguments, aggregated output.
#
# Mapping and the ignored list: docs/spec/adapter-interface.md (the ignored list there must equal `ignored_keys` here; the
# test spike/tests/test_normalize.sh checks it). `--arg dump keys` prints {mapped_keys, ignored_keys} instead (used by the test).
# Raw key = the event `type`, or `item.started:<item type>` / `item.completed:<item type>` for item events.
# Rules: an `item` of type error is a warning, never an error or a limit (observed: config warnings during a completed run).
# Agent text (agent_message, reasoning) is never classified. Each exec call counts as 1 turn.
# Written for jq 1.6 and later.

def mapped_keys: [
  "thread.started",
  "item.started:command_execution", "item.started:file_change", "item.started:mcp_tool_call", "item.started:web_search",
  "item.completed:command_execution", "item.completed:file_change", "item.completed:mcp_tool_call", "item.completed:web_search",
  "item.completed:agent_message",
  "item.started:error", "item.completed:error",
  "turn.completed", "turn.failed", "error"
];
def ignored_keys: [
  "turn.started",
  "item.updated",
  "item.started:agent_message", "item.started:reasoning", "item.started:todo_list",
  "item.completed:reasoning", "item.completed:todo_list"
];
def tool_items: ["command_execution", "file_change", "mcp_tool_call", "web_search"];

def clean: gsub("[\u0000-\u0008\u000b-\u001f\u007f-\u009f]"; " ");
def clip($n): if type == "string" then (clean | .[0:$n]) else null end;
def isobj: type == "object";
def num: if type == "number" then . else null end;
def int0: if type == "number" and . >= 0 then floor else 0 end;
def dropnull: with_entries(select(.value != null));
def inl($list): . as $x | any($list[]; . == $x);
# Same wording as spike/codex/parse.jq (T-003); the test checks the two lines are identical. A hint only: it is applied to the
# message of the two fatal carriers (error, turn.failed) and never to agent text.
def ratelimit_text: test("rate.?limit|usage.?limit|insufficient_quota|quota (exceeded|reached)|exceeded.{0,20}quota|too many requests|\\b429\\b"; "i");

def ev($seq; $etype; $raw; $fields):
  {type: $etype, provider: "codex", seq: $seq,
   ts: ($ARGS.named.ts | if type == "string" then . else null end), raw: $raw} + $fields;

def unknown_ev($seq; $rawtype; $o):
  ($rawtype | clip(64)) as $r
  | ev($seq; "unknown"; $r; {raw_type: $r, keys: (if $o | isobj then [$o | keys[:20][] | clip(40)] else [] end)});

def zero_tokens: {input: 0, output: 0, cache_read: 0, cache_write: 0, reasoning: 0};

# A fatal carrier (error, turn.failed): a rate-limit-looking message first emits rate_limited, then the error.
def fatal_events($seq; $rk; $kind; $msg):
  ( if ($msg | type) == "string" and ($msg | ratelimit_text)
    then ev($seq; "rate_limited"; $rk; {raw_kind: "codex_text_hint"}) else empty end ),
  ev($seq; "error"; $rk; {kind: $kind, fatal: true, message: ($msg | clip(300) // "")});

# One JSON object. $st carries {tools: {<item id>: true}, errs: {<item id>: true}} across lines. Returns {ev: [...], st: state}.
def step($seq; $st):
  . as $o
  | ($o.type) as $t
  | (if ($t | type) == "string" and ($t | startswith("item.")) and ($o.item | isobj) and (($o.item.type | type) == "string")
     then ($o.item.type | clip(40)) else null end) as $it
  | ( if ($t | type) != "string" then "invalid_type"
      elif $t == "item.updated" then "item.updated"
      elif ($t == "item.started" or $t == "item.completed") then ($t + ":" + ($it // "invalid_item"))
      else $t end
      | clip(64) | if . == "" then "empty_type" else . end ) as $rk
  | (if ($o.item | isobj) then $o.item else {} end) as $item
  | ($item.id | clip(100)) as $iid
  | ($iid // "line\($seq)") as $tid
  | ($it != null and (tool_items | any(. == $it))) as $is_tool
  | if $rk == "thread.started" then
      {ev: [ if ($o.thread_id | type) == "string" and ($o.thread_id | length) > 0
             then ev($seq; "session_started"; $rk; {session_id: ($o.thread_id | clip(100))})
             else unknown_ev($seq; $rk; $o) end ], st: $st}
    elif ($rk | inl(ignored_keys)) then {ev: [], st: $st}
    elif $t == "item.started" and $is_tool then
      {ev: [ if $st.tools[$tid] then empty else ev($seq; "tool_call"; $rk; {id: $tid, name: $it}) end ],
       st: ($st | .tools[$tid] = true)}
    elif $t == "item.completed" and $is_tool then
      {ev: [ (if $st.tools[$tid] then empty else ev($seq; "tool_call"; $rk; {id: $tid, name: $it}) end),
             ev($seq; "tool_result"; $rk;
                {id: $tid,
                 is_error: ($item.status == "failed" or ((($item.exit_code | type) == "number") and $item.exit_code != 0))}) ],
       st: ($st | .tools[$tid] = true)}
    elif $rk == "item.completed:agent_message" then
      {ev: [ ev($seq; "message"; $rk; {role: "assistant", text: ($item.text | clip(4000) // ""),
                                       truncated: ((($item.text | type) == "string") and (($item.text | length) > 4000))}) ],
       st: $st}
    elif $rk == "item.started:error" or $rk == "item.completed:error" then
      {ev: [ if $iid != null and $st.errs[$iid] then empty
             else ev($seq; "warning"; $rk; {kind: "item_error", message: ($item.message | clip(300) // "")}) end ],
       st: (if $iid != null then ($st | .errs[$iid] = true) else $st end)}
    elif $rk == "turn.completed" then
      (if ($o.usage | isobj) then $o.usage else {} end) as $u
      | {ev: [ ev($seq; "result"; $rk;
                  {is_error: false, turns: 1,
                   tokens: {input: ($u.input_tokens | int0), output: ($u.output_tokens | int0),
                            cache_read: ($u.cached_input_tokens | int0), cache_write: ($u.cache_write_input_tokens | int0),
                            reasoning: ($u.reasoning_output_tokens | int0)},
                   tokens_known: ((($u.input_tokens | type) == "number") and (($u.output_tokens | type) == "number")),
                   cost_usd: null, cost_is_estimate: true}) ],
         st: $st}
    elif $rk == "turn.failed" then
      ($o.error | if isobj then .message else . end) as $msg
      | {ev: [ fatal_events($seq; $rk; "turn_failed"; $msg),
               ev($seq; "result"; $rk;
                  {is_error: true, turns: 1, tokens: zero_tokens, tokens_known: false, cost_usd: null, cost_is_estimate: true}) ],
         st: $st}
    elif $rk == "error" then
      {ev: [ fatal_events($seq; $rk; "stream_error"; $o.message) ], st: $st}
    else {ev: [ unknown_ev($seq; $rk; $o) ], st: $st}
    end;

def exit_events($n):
  ($ARGS.named.exit_code) as $c
  | ($ARGS.named.signal) as $sg
  | if ($c | type) == "number" or ($sg | type) == "string" then
      ev($n + 1; "exited"; "process_exit";
         ({code: (if ($c | type) == "number" then ($c | floor) else null end),
           signal: (if ($sg | type) == "string" then ($sg | clip(32)) else null end)} | dropnull))
    else empty end;

# a line that is not JSON, or not an object, becomes an unknown event and leaves the state alone
def line_step($seq; $st):
  . as $line
  | (try {ok: ($line | fromjson)} catch {bad: true}) as $p
  | if $p.bad or ($p.ok | isobj | not)
    then {ev: [ unknown_ev($seq; "malformed_line"; null) ], st: $st}
    else $p.ok | step($seq; $st) end;

if $ARGS.named.dump == "keys" then {mapped_keys: mapped_keys, ignored_keys: ignored_keys}
else
  [inputs] as $lines
  | ( foreach ($lines | to_entries[]) as $e ({tools: {}, errs: {}, ev: []};
        ($e.value) as $line
        | if ($line | test("^[ \t\r]*$")) then .ev = []
          else . as $s | ($line | line_step($e.key + 1; {tools: $s.tools, errs: $s.errs})) as $r
               | {tools: $r.st.tools, errs: $r.st.errs, ev: $r.ev} end;
        .ev[]) ),
    exit_events($lines | length)
end
