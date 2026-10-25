# Parser for the JSONL stream of `codex exec --json` (T-003). Data only: nothing here evaluates, runs or follows any text.
#
#   jq -n -R -f spike/codex/parse.jq < raw.jsonl
#
# Reads raw lines (-R with -n), so a line that is not valid JSON never stops the run: it is counted in malformed_lines.
# An event or item type this file does not know lands in `unknown` and is still counted; nothing here can fail on an
# unknown type, a missing field or a field of the wrong type. Every string taken from the stream is clipped and has its
# control characters replaced by spaces; it is for display and counting only.
#
# Output:
#   { thread_id, lines, malformed_lines,
#     event_counts: {"<event type>": n},
#     items: {"<item type>": n},                       one count per distinct item id (started/updated/completed = one item)
#     commands_run: [{command, status, exit_code}],
#     final: {status, usage, last_message_excerpt},    status: completed | failed | incomplete
#     limit_or_error_events: [{type, kind, message}],  kind: rate_limit | error (a text heuristic, see EVENTS.md)
#     unknown: [{kind, type, keys}] }                  kind: event | item
#
# Event and item shapes: the official Codex TypeScript SDK types (ThreadEvent / ThreadItem), see EVENTS.md.

def clip($n): if type == "string" then gsub("[[:cntrl:]]"; " ") | .[0:$n] else null end;
def isobj: type == "object";
def known_events: ["thread.started", "turn.started", "turn.completed", "turn.failed",
                   "item.started", "item.updated", "item.completed", "error"];
def known_items: ["agent_message", "reasoning", "command_execution", "file_change",
                  "mcp_tool_call", "web_search", "todo_list", "error"];
def is_known($list; $t): $list | any(. == $t);
def is_item_event: isobj and (.type == "item.started" or .type == "item.updated" or .type == "item.completed");
def etype: if isobj then (.type | clip(64)) else null end;
def keys_of: if isobj then [keys_unsorted[:20][] | clip(64)] else [] end;
def count_by_key(f): reduce f as $k ({}; .[$k] += 1);
def ratelimit_text: test("rate.?limit|usage.?limit|quota|too many requests|\\b429\\b|try again (in|later)|limit (reached|exceeded)|exceeded.*limit"; "i");

[ inputs
  | select(type == "string" and length > 0)
  | (try {ok: true, v: fromjson} catch {ok: false}) ] as $lines
| [ $lines[] | select(.ok) | .v ] as $events
| ($lines | map(select(.ok | not)) | length) as $malformed

# items, one record per distinct item id (records without an id are kept one by one)
| [ $events | to_entries[]
    | select((.value | is_item_event) and (.value.item | isobj))
    | .value as $e
    | { idx: .key,
        id: ($e.item.id | if type == "string" then clip(100) else null end),
        type: ($e.item.type | clip(64)),
        item: $e.item } ] as $item_events
| ( ( $item_events | map(select(.id != null)) | group_by(.id) | map(last) )
    + ( $item_events | map(select(.id == null)) ) | sort_by(.idx) ) as $final_items

| [ $events[] | select(isobj and (.type == "turn.completed" or .type == "turn.failed" or .type == "error")) ] as $terminal

| {
    thread_id: ( [ $events[] | select(isobj and .type == "thread.started") | .thread_id | select(type == "string") | clip(200) ] | first ),
    lines: ($lines | length),
    malformed_lines: $malformed,
    event_counts: count_by_key($events[] | (etype // "unknown")),
    items: count_by_key($final_items[] | (.type // "unknown")),
    commands_run: [ $final_items[] | select(.type == "command_execution")
                    | .item as $i
                    | { command: ($i.command | clip(500)),
                        status: ($i.status | clip(32)),
                        exit_code: ($i.exit_code | if type == "number" then . else null end) } ],
    final: {
      status: ( if ($terminal | length) == 0 then "incomplete"
                elif ($terminal | last | .type) == "turn.completed" then "completed"
                else "failed" end ),
      usage: ( [ $events[] | select(isobj and .type == "turn.completed" and (.usage | isobj)) | .usage ] | last
               | if . == null then null
                 else with_entries(select(.value | type == "number") | .key |= .[0:64]) end ),
      last_message_excerpt: ( [ $final_items[] | select(.type == "agent_message") | .item.text | clip(200) ] | last )
    },
    limit_or_error_events: (
      [ $events[]
        | if isobj and .type == "error" then {type: "error", msg: .message}
          elif isobj and .type == "turn.failed" then {type: "turn.failed", msg: (.error | if isobj then .message else . end)}
          elif is_item_event and (.item | isobj) and .item.type == "error" then {type: "item.error", msg: .item.message}
          else empty end
        | {type, kind: (if (.msg | type == "string") and (.msg | ratelimit_text) then "rate_limit" else "error" end),
           message: (.msg | clip(200))} ] ),
    unknown: (
      [ $events[] | select(is_known(known_events; etype) | not)
        | {kind: "event", type: etype, keys: keys_of} ]
      + [ $final_items[] | select(is_known(known_items; .type) | not)
          | {kind: "item", type: .type, keys: (.item | keys_of)} ] )
  }
