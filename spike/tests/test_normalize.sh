#!/bin/bash
# Offline tests for the adapter spec and the normalizers (T-004):
#   docs/spec/adapter-interface.md, docs/spec/event.schema.json, spike/normalize/{claude,codex}.jq, spike/normalize/expected/*,
#   spike/fixtures/normalize/*.
#   /bin/bash spike/tests/test_normalize.sh
# Exit 0 = all checks passed. Never sets SPIKE_LIVE=1 and never runs a provider CLI: the only programs run are jq, grep, sed,
# awk, cmp and sort. Any spike/fixtures/{claude,codex}/observed*.jsonl is picked up automatically; absent ones print a NOTE.
set -u
unset CDPATH

HERE=$(cd "$(dirname "$0")" && pwd -P)
SPIKE=$(cd "$HERE/.." && pwd -P)
REPO=$(cd "$SPIKE/.." && pwd -P)
NORM="$SPIKE/normalize"
EXPECTED="$NORM/expected"
FIXN="$SPIKE/fixtures/normalize"
SPEC="$REPO/docs/spec/adapter-interface.md"
SCHEMA="$REPO/docs/spec/event.schema.json"
SH=/bin/bash

TMP=$(mktemp -d "${TMPDIR:-/tmp}/normalize-test.XXXXXX") || exit 2
TMP=$(cd "$TMP" && pwd -P) || exit 2
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/out"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1" >&2
}
note() { printf 'NOTE: %s\n' "$1"; }
check() { # description, then a command; passes if the command succeeds
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then pass; else fail "$desc"; fi
}
eq() { # desc actual expected
  if [ "$2" = "$3" ]; then pass; else fail "$1: expected [$3] got [$2]"; fi
}
jqe() { # desc json filter: passes if `jq -e filter` is true on the json
  if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then pass; else fail "$1 (filter: $3)"; fi
}
# normalize <cli> <file> [jq args...] : prints the normalized events of the file
normalize() {
  local cli=$1 file=$2
  shift 2
  jq -c -n -R "$@" -f "$NORM/$cli.jq" < "$file"
}
count() { # events-file jq-condition : number of events for which the condition is true
  jq -c "select($2)" "$1" | wc -l | tr -d ' '
}

email_hits() { grep -cE '[^ @]+@[^ @]+\.[a-zA-Z]{2,}' "$1"; } # email-shaped text; a harmless @types/node does not match
SPEC_FLAT="$TMP/spec-flat.md" # the spec on one line, so a phrase wrapped over two lines still matches
tr '\n' ' ' < "$SPEC" 2> /dev/null | sed 's/  */ /g' > "$SPEC_FLAT"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }

# ---- files exist, syntax -------------------------------------------------------------------------------------------------
for f in "$SPEC" "$SCHEMA" "$NORM/claude.jq" "$NORM/codex.jq" "$FIXN/claude-routine.jsonl" "$FIXN/codex-item-warning.jsonl" \
  "$FIXN/claude-hostile.jsonl" "$FIXN/codex-hostile.jsonl"; do
  check "exists: ${f#"$REPO"/}" test -f "$f"
done
check "bash -n on this test" "$SH" -n "$HERE/test_normalize.sh"
check "the schema is valid JSON" jq empty "$SCHEMA"
check "claude.jq compiles on an empty input" jq -c -n -R -f "$NORM/claude.jq" < /dev/null
check "codex.jq compiles on an empty input" jq -c -n -R -f "$NORM/codex.jq" < /dev/null
eq "claude.jq prints nothing on empty input" "$(normalize claude /dev/null | wc -c | tr -d ' ')" "0"
eq "codex.jq prints nothing on empty input" "$(normalize codex /dev/null | wc -c | tr -d ' ')" "0"

# ---- schema structure; hard rule 3: no pty transport -----------------------------------------------------------------
check "transport enum is exactly headless,acp" jq -e '."$defs".transport.enum == ["headless","acp"]' "$SCHEMA"
check "capabilities.transport uses the transport def" jq -e '."$defs".capabilities.properties.transport."$ref" == "#/$defs/transport"' "$SCHEMA"
check "capabilities lists transport, resume, mcp, hooks, native_turn_cap" \
  jq -e '(."$defs".capabilities.required | sort) == (["transport","resume","mcp","hooks","native_turn_cap"] | sort)' "$SCHEMA"
check "no schema string mentions a terminal transport" test "$(grep -ciE '"(pty|tty|terminal)"' "$SCHEMA")" = "0"
check "event_type enum has the 11 types" jq -e '."$defs".event_type.enum | length == 11' "$SCHEMA"
check "oneOf covers every event type" jq -e '(.oneOf | map(."$ref" | ltrimstr("#/$defs/")) | sort) == (."$defs".event_type.enum | sort)' "$SCHEMA"
check "every event type has a def with required fields" jq -e '. as $s | ."$defs".event_type.enum | all(. as $t | $s."$defs"[$t] != null)' "$SCHEMA"
check "cost_is_estimate is fixed true in result" jq -e '."$defs".result.allOf[1].properties.cost_is_estimate.const == true' "$SCHEMA"

# ---- the spec: methods, rules 3 and 2, ignored lists ---------------------------------------------------------------------
methods="$TMP/methods.md"
awk '/^## Methods/{f=1;next} /^## /{f=0} f' "$SPEC" > "$methods"
check "the Methods section is not empty" test -s "$methods"
check "interface methods name no pty/terminal/stdin write" test "$(grep -ciE 'pty|terminal|tty|stdin' "$methods")" = "0"
for m in 'start(task, worktree)' 'send(prompt)' 'events()' 'cancel()' 'authStatus()' 'capabilities()' 'usage()' 'loginArgv()'; do
  check "spec defines $m" grep -qF "$m" "$methods"
done
check "spec: send never writes to a running child" grep -q 'never writes to a child' "$methods"
check "spec: authStatus is exit code only" grep -q 'exit code only' "$methods"
check "spec: loginArgv returns only the CLI's own login command" grep -q "CLI's own documented login command" "$methods"
check "spec states the rule 2 failover line" grep -q 'Failover only moves work to a different provider' "$SPEC"
check "spec states that a limit never starts a new session on the same provider" grep -q 'never starts a new session on the same provider' "$SPEC"
check "spec: each Codex exec counts as 1 turn" grep -q 'Codex 1 per `exec` call' "$SPEC"
check "spec: an unknown limit status is rate_limited" grep -q 'claude_unknown_limit_status' "$SPEC"
check "spec: cost_is_estimate is always true" grep -q 'cost_is_estimate` is always true' "$SPEC"
for s in spawning running idle rate_limited exited killed; do
  check "spec state machine names $s" grep -q "\`$s\`" "$SPEC"
done

ignored_in_spec() { # cli : the marked list, sorted
  sed -n "/<!-- ignored:$1:start -->/,/<!-- ignored:$1:end -->/p" "$SPEC" | grep '^- `' | sed 's/^- `//; s/`$//' | sort
}
ignored_in_jq() { jq -r -n --arg dump keys -f "$NORM/$1.jq" < /dev/null | jq -r '.ignored_keys[]' | sort; }
mapped_in_jq() { jq -r -n --arg dump keys -f "$NORM/$1.jq" < /dev/null | jq -r '.mapped_keys[]' | sort; }
for cli in claude codex; do
  check "spec has ignored:$cli markers" test "$(grep -c "<!-- ignored:$cli:" "$SPEC")" = "2"
  eq "jq ignored list equals the spec's marked list ($cli)" "$(ignored_in_jq $cli)" "$(ignored_in_spec $cli)"
  check "$cli.jq defines non-empty mapped_keys and ignored_keys" test -n "$(mapped_in_jq $cli)" -a -n "$(ignored_in_jq $cli)"
  eq "mapped_keys and ignored_keys do not overlap ($cli)" "$(comm -12 <(mapped_in_jq $cli) <(ignored_in_jq $cli) | wc -l | tr -d ' ')" "0"
  while IFS= read -r k; do
    base=${k##*:}
    base=${base%%/\**}
    if grep -qF "$base" "$SPEC"; then pass; else fail "mapped key $k ($cli) is described in the spec"; fi
  done < <(mapped_in_jq $cli)
done

# ---- hard rule 4: the normalizers read stdin only -------------------------------------------------------------------------
for cli in claude codex; do
  check "$cli.jq uses no import/include/\$ENV/env/input_filename" \
    test "$(grep -vE '^[[:space:]]*#' "$NORM/$cli.jq" | grep -cE '(^|[^A-Za-z_])(import|include|env|input_filename|debug|stderr|halt_error|input_line_number)([^A-Za-z_]|$)|\$ENV|\$__loc__|\$__prog')" = "0"
  check "$cli.jq reads no file (no getpath of a path, no @sh, no ltrimstr of a home)" \
    test "$(grep -vE '^[[:space:]]*#' "$NORM/$cli.jq" | grep -cE '@sh|\$HOME|/Users/|~/')" = "0"
done
eq "normalizers use no import/include/\$ENV/env/input_filename (both files)" \
  "$(cat "$NORM/claude.jq" "$NORM/codex.jq" | grep -vE '^[[:space:]]*#' | grep -cE '(^|[^A-Za-z_])(import|include|env|input_filename)([^A-Za-z_]|$)|\$ENV')" "0"

# ---- hard rule 10: the rate-limit text heuristic is one regex in both files ----------------------------------------------
rl_codex=$(grep -E '^def ratelimit_text:' "$NORM/codex.jq")
rl_parse=$(grep -E '^def ratelimit_text:' "$SPIKE/codex/parse.jq")
check "the ratelimit_text regex is identical in both files" test -n "$rl_codex" -a "$rl_codex" = "$rl_parse"

# ---- the schema-based validator (jq), checks every event against docs/spec/event.schema.json -----------------------------
cat > "$TMP/validate.jq" <<'EOF'
# input: array of events; $sch: [schema]. Output: array of {event, problem} for every event that breaks the schema.
def deref($S): if type == "object" and has("$ref") then (. as $n | $S | getpath($n["$ref"] | ltrimstr("#/") | split("/"))) else . end;
def typeok($x): . as $v
  | if $x == "string" then ($v | type) == "string"
    elif $x == "integer" then ($v | type) == "number" and $v == ($v | floor)
    elif $x == "number" then ($v | type) == "number"
    elif $x == "boolean" then ($v | type) == "boolean"
    elif $x == "null" then $v == null
    elif $x == "array" then ($v | type) == "array"
    elif $x == "object" then ($v | type) == "object"
    else false end;
def okv($S; $v): deref($S) as $d
  | (if ($d | has("type")) then ([$d.type] | flatten | any(. as $x | $v | typeok($x))) else true end)
    and (if ($d | has("const")) then $v == $d.const else true end)
    and (if ($d | has("enum")) then ($d.enum | any(. == $v)) else true end)
    and (if ($d | has("minimum")) and ($v | type) == "number" then $v >= $d.minimum else true end)
    and (if ($d | has("maxLength")) and ($v | type) == "string" then ($v | length) <= $d.maxLength else true end)
    and (if ($d | has("minLength")) and ($v | type) == "string" then ($v | length) >= $d.minLength else true end)
    and (if ($d | has("maxItems")) and ($v | type) == "array" then ($v | length) <= $d.maxItems else true end)
    and (if ($d | has("items")) and ($v | type) == "array" then ($v | all(.[]; . as $i | $d.items | okv($S; $i))) else true end)
    and (if ($v | type) == "object" and ($d | has("properties")) then
           (($d.required // []) | all(. as $k | $v | has($k)))
           and ($v | to_entries | all(.[]; . as $e
                 | if ($d.properties | has($e.key)) then ($d.properties[$e.key] | okv($S; $e.value))
                   else ($d.additionalProperties != false) end))
         else true end);
def flat($S): deref($S) as $d
  | ([($d.properties // {}) | to_entries[]]) as $own
  | ([($d.allOf // [])[] | flat($S)]) as $subs
  | {required: (($d.required // []) + ([$subs[].required] | add // [])),
     props: ($own + ([$subs[].props] | add // []))};
$sch[0] as $S
| [ .[] | . as $e
    | ($S."$defs"[$e.type]) as $def
    | if $def == null then {event: $e, problem: "type not in schema"}
      else ($def | flat($S)) as $f
        | if ($f.required | all(. as $k | $e | has($k)) | not) then {event: $e, problem: "missing required field"}
          elif ($e | to_entries | all(.[]; . as $kv | $f.props | any(.key == $kv.key)) | not) then {event: $e, problem: "field outside the schema"}
          elif ($e | to_entries | all(.[]; . as $kv | [$f.props[] | select(.key == $kv.key) | .value] | all(.[]; okv($S; $kv.value))) | not)
          then {event: $e, problem: "field fails its schema"}
          else empty end
      end ]
EOF
# validator self-test: it must catch a bad event
printf '%s\n' '{"type":"message","provider":"claude","seq":1,"ts":null,"raw":"x","role":"assistant","text":"hi","truncated":false}' \
  '{"type":"message","provider":"claude","seq":1,"ts":null,"raw":"x","role":"assistant","text":5,"truncated":false}' \
  '{"type":"message","provider":"claude","seq":0,"ts":null,"raw":"x","role":"assistant","text":"hi","truncated":false}' \
  '{"type":"message","provider":"claude","seq":1,"ts":null,"raw":"x","role":"assistant","text":"hi","truncated":false,"extra":1}' \
  '{"type":"result","provider":"codex","seq":1,"ts":null,"raw":"x","is_error":false,"turns":1,"turns_known":true,"tokens":{"input":1,"output":1,"cache_read":1,"cache_write":1},"tokens_known":true,"cost_usd":null,"cost_is_estimate":true}' \
  '{"type":"result","provider":"codex","seq":1,"ts":null,"raw":"x","is_error":false,"turns":1,"turns_known":true,"tokens":{"input":1,"output":1,"cache_read":1,"cache_write":1,"reasoning":0},"tokens_known":true,"cost_usd":null,"cost_is_estimate":false}' \
  '{"type":"bogus","provider":"codex","seq":1,"ts":null,"raw":"x"}' \
  '{"type":"result","provider":"codex","seq":1,"ts":null,"raw":"x","is_error":false,"turns":1,"turns_known":true,"tokens":{"input":1,"output":1,"cache_read":1,"cache_write":1,"reasoning":0},"tokens_known":true,"cost_usd":null,"cost_is_estimate":true}' \
  '{"type":"result","provider":"codex","seq":1,"ts":null,"raw":"x","is_error":false,"turns":1,"tokens":{"input":1,"output":1,"cache_read":1,"cache_write":1,"reasoning":0},"tokens_known":true,"cost_usd":null,"cost_is_estimate":true}' \
  '{"type":"result","provider":"codex","seq":1,"ts":null,"raw":"x","is_error":false,"turns":1,"turns_known":"yes","tokens":{"input":1,"output":1,"cache_read":1,"cache_write":1,"reasoning":0},"tokens_known":true,"cost_usd":null,"cost_is_estimate":true}' \
  '{"type":"tool_call","provider":"claude","seq":1,"ts":null,"raw":"x","id":"","name":"X"}' \
  '{"type":"tool_call","provider":"claude","seq":1,"ts":null,"raw":"x","id":"t1","name":""}' \
  '{"type":"tool_result","provider":"claude","seq":1,"ts":null,"raw":"x","id":"","is_error":false}' \
  '{"type":"error","provider":"claude","seq":1,"ts":null,"raw":"x","kind":"","fatal":false,"message":""}' \
  '{"type":"error","provider":"claude","seq":1,"ts":null,"raw":"x","kind":"unknown_error","fatal":false,"message":""}' \
  > "$TMP/badevents.jsonl"
bad=$(jq -s --slurpfile sch "$SCHEMA" -f "$TMP/validate.jq" "$TMP/badevents.jsonl" | jq 'length')
# bad (12): text 5, seq 0, extra field, result without reasoning, cost_is_estimate false, unknown type, result without turns_known,
# turns_known not a boolean, tool_call with an empty id, tool_call with an empty name, tool_result with an empty id, error with an
# empty kind. Good (3): the first message, one complete result, an error with an empty message but a kind.
eq "validator self-test: 3 good events, 12 bad events caught (a missing turns_known, empty ids and an empty kind included)" "$bad" "12"
validate() { # events-file : prints the number of schema problems
  jq -s --slurpfile sch "$SCHEMA" -f "$TMP/validate.jq" "$1" | jq 'length'
}

# ---- every fixture ------------------------------------------------------------------------------------------------------
# entries "cli|file|name"; name is the golden's base name
entries=()
for cli in claude codex; do
  for f in "$SPIKE/fixtures/$cli"/*.jsonl; do
    [ -f "$f" ] && entries+=("$cli|$f|$cli-$(basename "$f" .jsonl)")
  done
done
for f in "$FIXN"/*.jsonl; do
  [ -f "$f" ] || continue
  n=$(basename "$f" .jsonl)
  case "$n" in
    claude-* | codex-*) entries+=("${n%%-*}|$f|$n") ;;
    *) fail "fixtures/normalize/$n.jsonl must start with claude- or codex-" ;;
  esac
done

# raw keys of a fixture, derived independently of the normalizers (well-formed lines only). Keys with a character outside
# printable ASCII, or longer than 64, are dropped here (the hostile tests cover them). The filter is a jq regex on purpose:
# a shell glob range such as [ -~] follows the locale's collation under bash 3.2 (macOS), where it excluded every letter
# and silently checked zero keys.
printable_key_def='def printable_key: select(test("^[ -~]{1,64}$"));'
claude_rawkeys="$printable_key_def"'
  def blocks: (.message.content? // null) | if type == "string" then [{type: "text"}] elif type == "array" then . else [] end;
  [ inputs | (try fromjson catch null) | select(type == "object" and (.type | type) == "string")
    | . as $o
    | (if ($o.type == "assistant" or $o.type == "user") then empty # these two are keyed by their blocks (and "assistant" by its error) below
       elif ($o.type == "system" or $o.type == "result") and ($o.subtype | type) == "string" then "\($o.type)/\($o.subtype)" else $o.type end),
      (if $o.type == "assistant" and ($o.error | type) == "string" then "assistant" else empty end),
      (if $o.type == "assistant" or $o.type == "user" then ($o | blocks[] | select(type == "object" and (.type | type) == "string") | "\($o.type):\(.type)") else empty end)
  ] | unique | .[] | printable_key'
codex_rawkeys="$printable_key_def"'
  [ inputs | (try fromjson catch null) | select(type == "object" and (.type | type) == "string")
    | if .type == "item.updated" then "item.updated"
      elif (.type == "item.started" or .type == "item.completed") then (if (.item | type) == "object" and (.item.type | type) == "string" then "\(.type):\(.item.type)" else empty end)
      else .type end
  ] | unique | .[] | printable_key'
key_listed() { # cli key [jq-file] : 0 if the key is mapped (a trailing /* is a wildcard) or ignored in that file
  local cli=$1 key=$2 file=${3:-$NORM/$1.jq}
  jq -n -e --arg dump keys -f "$file" < /dev/null \
    | jq -e --arg k "$key" '(.mapped_keys + .ignored_keys) | any(. as $e | $e == $k or (($e | endswith("/*")) and ($k | startswith($e[0:-1]))))' > /dev/null
}
# rawkey_problems cli fixture normalized-output [jq-file] : prints one line per raw key of the fixture that is neither listed
# (mapped or ignored) nor yields an unknown event, then "checked N". Derived independently of the normalizer.
rawkey_problems() {
  local cli=$1 file=$2 out=$3 jqfile=${4:-$NORM/$1.jq} keysprog key n=0
  if [ "$cli" = claude ]; then keysprog=$claude_rawkeys; else keysprog=$codex_rawkeys; fi
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    n=$((n + 1))
    if key_listed "$cli" "$key" "$jqfile"; then
      :
    elif jq -s -e --arg k "$key" 'any(.[]; .type == "unknown" and .raw_type == $k)' "$out" > /dev/null; then
      :
    else
      printf "raw key '%s' is neither mapped, ignored, nor yields unknown\n" "$key"
    fi
  done < <(jq -n -r -R "$keysprog" < "$file")
  echo "checked $n"
}

# The independent key derivation itself, pinned on the two sample fixtures and on edge cases, so a platform difference that
# yields no keys (bash 3.2's collation-ordered glob ranges did) fails here by name instead of passing silently.
eq "derived raw keys of fixtures/claude/sample.jsonl" "$(jq -n -r -R "$claude_rawkeys" < "$SPIKE/fixtures/claude/sample.jsonl" | paste -sd' ' -)" \
  "assistant:text assistant:tool_use rate_limit_event result/success system/api_retry system/init system/status user:tool_result"
eq "derived raw keys of fixtures/codex/sample.jsonl" "$(jq -n -r -R "$codex_rawkeys" < "$SPIKE/fixtures/codex/sample.jsonl" | paste -sd' ' -)" \
  "future.event.kind item.completed:agent_message item.completed:command_execution item.completed:error item.completed:file_change item.completed:future_item_kind item.completed:mcp_tool_call item.completed:reasoning item.completed:todo_list item.completed:web_search item.started:command_execution item.started:mcp_tool_call item.started:todo_list item.updated thread.started turn.completed turn.started"
k64=$(printf 'y%.0s' $(seq 64))
printf '%s\n' '{"type":"ok_type"}' '{"type":"bad\u0007type"}' "{\"type\":\"${k64}x\"}" "{\"type\":\"$k64\"}" '{"type":"caf\u00e9"}' \
  '{"type":"tab\there"}' > "$TMP/keyedge.jsonl"
eq "key derivation keeps printable ASCII up to 64 characters and drops control, non-ASCII and longer keys" \
  "$(jq -n -r -R "$codex_rawkeys" < "$TMP/keyedge.jsonl" | paste -sd' ' -)" "ok_type $k64"

observed_seen=0
for e in "${entries[@]}"; do
  IFS='|' read -r cli file name <<< "$e"
  out="$TMP/out/$name.jsonl"
  normalize "$cli" "$file" > "$out" 2> "$TMP/err.txt"
  rc=$?
  eq "$name: normalizer exits 0" "$rc" "0"
  check "$name: nothing on stderr" test ! -s "$TMP/err.txt"

  # golden file, byte for byte
  golden="$EXPECTED/$name.jsonl"
  case "$(basename "$file")" in
    observed*) is_observed=1 ;;
    *) is_observed=0 ;;
  esac
  if [ -f "$golden" ]; then
    check "$name: output equals expected/$name.jsonl byte for byte" cmp -s "$out" "$golden"
  elif [ "$is_observed" = 1 ]; then
    note "no golden file for $name (expected/$name.jsonl); the observed rules below still apply"
  else
    fail "$name: missing golden file expected/$name.jsonl"
  fi

  # schema enum, required envelope, structure
  check "$name: every output .type is in the schema enum" \
    jq -s -e --slurpfile sch "$SCHEMA" 'all(.[]; . as $e | $sch[0]."$defs".event_type.enum | any(. == $e.type))' "$out"
  check "$name: every event has provider, seq, raw" \
    jq -s -e 'all(.[]; has("provider") and has("seq") and has("raw") and has("ts") and (.seq | type == "number") and (.raw | type == "string"))' "$out"
  eq "$name: events validate against event.schema.json" "$(validate "$out")" "0"
  check "$name: seq never decreases" jq -s -e '[.[].seq] as $s | all(range(1; $s | length); $s[.] >= $s[. - 1])' "$out"
  check "$name: provider is $cli" jq -s -e --arg p "$cli" 'all(.[]; .provider == $p)' "$out"

  # session_started first and once (the deliberately broken-line fixture is exempt)
  # (codex-prestart-error is a run that died before thread.started, so it has no session_started by design)
  if [ "$name" != "codex-malformed" ] && [ "$name" != "codex-prestart-error" ]; then
    eq "$name: session_started appears once" "$(count "$out" '.type == "session_started"')" "1"
    check "$name: session_started is the first event" jq -s -e '.[0].type == "session_started"' "$out"
  fi
  # every tool_result has an earlier tool_call with the same id
  check "$name: every tool_result id has an earlier tool_call" \
    jq -s -e '. as $all | all(range(0; length); . as $i | $all[$i] | if .type == "tool_result" then (.id as $id | [$all[0:$i][] | select(.type == "tool_call" and .id == $id)] | length > 0) else true end)' "$out"
  # every result has numeric turns and five numeric token fields
  check "$name: every result has numeric tokens" \
    jq -s -e 'all(.[] | select(.type == "result"); (.turns | type == "number") and (.turns_known | type == "boolean") and (.tokens | [.input, .output, .cache_read, .cache_write, .reasoning] | all(type == "number")) and (.tokens_known | type == "boolean") and .cost_is_estimate == true)' "$out"
  # rule 1: every result of every committed fixture (and of any observed capture) carries a real turn count, so none of them
  # would make the scheduler keep a full reservation by accident
  check "$name: every result has turns_known true and, for Codex, turns 1" \
    jq -s -e --arg p "$cli" 'all(.[] | select(.type == "result"); .turns_known == true and (.turns >= 1) and ($p != "codex" or .turns == 1))' "$out"
  # tokens_known is false only for turn.failed (Codex), whatever fixture; the broken-line fixture has odd usage shapes
  if [ "$name" != "codex-malformed" ]; then
    check "$name: tokens_known is false only for turn.failed" \
      jq -s -e 'all(.[] | select(.type == "result" and .tokens_known == false); .raw == "turn.failed")' "$out"
  fi

  # every raw key is mapped, ignored, or yields unknown (derived independently of the normalizer)
  problems=$(rawkey_problems "$cli" "$file" "$out")
  eq "$name: at least one raw key was checked" "$(printf '%s\n' "$problems" | grep -c '^checked [1-9]')" "1"
  eq "$name: every raw key is mapped, ignored, or yields unknown" "$(printf '%s\n' "$problems" | grep -vc '^checked ')" "0"

  # no personal or path data, no tool inputs, no commands
  check "$name: no <WORKTREE> or command text in the output" test "$(grep -cE '<WORKTREE>|rm -rf|printf|file_path' "$out")" = "0"
  check "$name: no tools, mcp_servers, cwd, input, command, arguments or path keys on events" \
    jq -s -e 'all(.[]; (keys - ["tools","mcp_servers","cwd","input","command","arguments","file_path","path","changes","aggregated_output"]) == keys)' "$out"
  check "$name: no control character reaches the output" \
    jq -s -e 'all(.[]; [.. | strings] | all(test("[\u0000-\u0008\u000b-\u001f\u007f-\u009f]") | not))' "$out"
  check "$name: no ESC or NUL byte in the output file" test "$(tr -d '\033\000' < "$out" | wc -c | tr -d ' ')" = "$(wc -c < "$out" | tr -d ' ')"

  # observed captures: 0 unknown, one successful result, 0 rate_limited
  if [ "$is_observed" = 1 ]; then
    observed_seen=$((observed_seen + 1))
    eq "$name (observed): 0 unknown" "$(count "$out" '.type == "unknown"')" "0"
    eq "$name (observed): exactly one result" "$(count "$out" '.type == "result"')" "1"
    eq "$name (observed): that result has is_error false" "$(count "$out" '.type == "result" and .is_error == false')" "1"
    eq "$name (observed): 0 rate_limited" "$(count "$out" '.type == "rate_limited"')" "0"
    check "$name (observed): numeric tokens" \
      jq -s -e 'all(.[] | select(.type == "result"); .tokens | [.input, .output, .cache_read, .cache_write, .reasoning] | all(type == "number"))' "$out"
    check "$name (observed): no email-shaped text in the capture (harmless text such as @types/node is fine)" \
      test "$(email_hits "$file")" = "0"
  fi
done
for cli in claude codex; do
  if ! compgen -G "$SPIKE/fixtures/$cli/observed*.jsonl" > /dev/null; then
    note "no spike/fixtures/$cli/observed*.jsonl yet; the observed-capture checks for $cli are skipped (the human adds the redacted capture)"
  fi
done

# no stale golden files
for g in "$EXPECTED"/*.jsonl; do
  [ -f "$g" ] || continue
  gname=$(basename "$g" .jsonl)
  if [ -f "$TMP/out/$gname.jsonl" ]; then pass; else fail "golden file $gname.jsonl has no fixture"; fi
done

# ---- specific rows (rule 10 pacing, rule 1 accounting) --------------------------------------------------------------------
cl_limits="$TMP/out/claude-limits.jsonl"
cl_sample="$TMP/out/claude-sample.jsonl"
cl_routine="$TMP/out/claude-routine.jsonl"
eq "claude limits: exactly 3 rate_limited" "$(count "$cl_limits" '.type == "rate_limited"')" "3"
eq "claude limits: first reset_at 1790003600" "$(jq -s '[.[] | select(.type == "rate_limited")][0].reset_at' "$cl_limits")" "1790003600"
eq "claude limits: raw kinds in order" "$(jq -s -c '[.[] | select(.type == "rate_limited") | .raw_kind]' "$cl_limits")" '["claude_rejected","claude_credits_required","claude_assistant_rate_limit"]'
eq "claude limits: the error_max_turns result is an error result" "$(count "$cl_limits" '.type == "result" and .is_error == true and .subtype == "error_max_turns" and .turns == 5')" "1"
for n in claude-sample claude-routine; do
  eq "$n: 0 rate_limited" "$(count "$TMP/out/$n.jsonl" '.type == "rate_limited"')" "0"
  eq "$n: 1 limit_notice" "$(count "$TMP/out/$n.jsonl" '.type == "limit_notice"')" "1"
  eq "$n: exactly one result, is_error false" "$(count "$TMP/out/$n.jsonl" '.type == "result" and .is_error == false')" "1"
  eq "$n: exactly one result in total" "$(count "$TMP/out/$n.jsonl" '.type == "result"')" "1"
done
eq "claude sample: 0 unknown" "$(count "$cl_sample" '.type == "unknown"')" "0"
eq "claude routine: 0 unknown" "$(count "$cl_routine" '.type == "unknown"')" "0"
eq "claude sample: api_retry 529 is one warning" "$(count "$cl_sample" '.type == "warning" and .kind == "api_retry"')" "1"
eq "claude sample: limit_notice carries the warning status" "$(jq -s -r '[.[] | select(.type == "limit_notice")][0].status' "$cl_sample")" "allowed_warning"
eq "claude routine: limit_notice status allowed" "$(jq -s -r '[.[] | select(.type == "limit_notice")][0].status' "$cl_routine")" "allowed"
eq "claude routine: thinking_tokens and thinking blocks are ignored" "$(count "$cl_routine" '.raw | test("thinking")')" "0"
jqe "claude sample: result tokens map the usage fields" "$(jq -s -c '[.[] | select(.type == "result")][0]' "$cl_sample")" \
  '.tokens == {input: 300, output: 49, cache_read: 120, cache_write: 0, reasoning: 0} and .turns == 2 and .cost_usd == 0.0123 and .cost_is_estimate == true and .tokens_known == true'
jqe "claude routine: result maps cache_creation to cache_write" "$(jq -s -c '[.[] | select(.type == "result")][0]' "$cl_routine")" \
  '.tokens == {input: 40, output: 24, cache_read: 40, cache_write: 5, reasoning: 0} and .turns == 2 and .stop_reason == "end_turn" and .duration_ms == 3100'

# synthetic limit-status lines
limit_line() { printf '{"type":"rate_limit_event","rate_limit_info":%s}\n' "$1"; }
{
  limit_line '{"status":"surprise","resetsAt":1790009999}'
  limit_line '{"status":"ALLOWED"}'
  limit_line '{"status":null}'
  limit_line '{"status":["allowed"]}'
} > "$TMP/unknown-status.jsonl"
normalize claude "$TMP/unknown-status.jsonl" > "$TMP/o.jsonl"
eq "claude unknown limit status: 4 rate_limited" "$(count "$TMP/o.jsonl" '.type == "rate_limited" and .raw_kind == "claude_unknown_limit_status"')" "4"
eq "claude unknown limit status: no limit_notice" "$(count "$TMP/o.jsonl" '.type == "limit_notice"')" "0"
eq "claude unknown limit status: reset_at kept when present" "$(jq -s '.[0].reset_at' "$TMP/o.jsonl")" "1790009999"
eq "claude unknown limit status: reset_at absent when missing" "$(jq -s '.[1] | has("reset_at")' "$TMP/o.jsonl")" "false"
{
  printf '%s\n' '{"type":"rate_limit_event"}'
  printf '%s\n' '{"type":"rate_limit_event","rate_limit_info":{}}'
  printf '%s\n' '{"type":"rate_limit_event","rate_limit_info":"allowed"}'
  printf '%s\n' '{"type":"rate_limit_event","rate_limit_info":null}'
} > "$TMP/missing-status.jsonl"
normalize claude "$TMP/missing-status.jsonl" > "$TMP/o.jsonl"
eq "claude missing limit status: 4 rate_limited" "$(count "$TMP/o.jsonl" '.type == "rate_limited" and .raw_kind == "claude_unknown_limit_status"')" "4"
eq "claude missing limit status: 0 limit_notice" "$(count "$TMP/o.jsonl" '.type == "limit_notice"')" "0"
{
  limit_line '{"status":"allowed"}'
  limit_line '{"status":"allowed_warning","utilization":0.9,"resetsAt":1790000100}'
} > "$TMP/routine-status.jsonl"
normalize claude "$TMP/routine-status.jsonl" > "$TMP/o.jsonl"
eq "claude allowed and allowed_warning: 2 limit_notice, 0 rate_limited" "$(count "$TMP/o.jsonl" '.type == "limit_notice"')/$(count "$TMP/o.jsonl" '.type == "rate_limited"')" "2/0"
printf '%s\n' '{"type":"system","subtype":"api_retry","attempt":3,"max_retries":10,"retry_delay_ms":4000,"error_status":429,"error":"rate_limit"}' > "$TMP/retry.jsonl"
normalize claude "$TMP/retry.jsonl" > "$TMP/o.jsonl"
eq "api_retry 429 is a warning (1 warning, 0 rate_limited, 0 error)" "$(count "$TMP/o.jsonl" '.type == "warning"')/$(count "$TMP/o.jsonl" '.type == "rate_limited"')/$(count "$TMP/o.jsonl" '.type == "error"')" "1/0/0"
{
  printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":429,"num_turns":1,"usage":{"input_tokens":1,"output_tokens":0}}'
  printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":500,"num_turns":1,"usage":{"input_tokens":1,"output_tokens":0}}'
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"api_error_status":429,"num_turns":1,"usage":{"input_tokens":1,"output_tokens":0}}'
} > "$TMP/r429.jsonl"
normalize claude "$TMP/r429.jsonl" > "$TMP/o.jsonl"
eq "claude result 429: exactly one claude_result_429, before its result" "$(jq -s -c '[.[] | select(.type == "rate_limited" or .type == "result") | (.raw_kind // "result")]' "$TMP/o.jsonl")" '["claude_result_429","result","result","result"]'
printf '%s\n' '{"type":"result","subtype":"success","num_turns":1}' > "$TMP/nousage.jsonl"
normalize claude "$TMP/nousage.jsonl" > "$TMP/o.jsonl"
jqe "claude result without usage: zero tokens, tokens_known false, still numeric" "$(jq -s -c '.[0]' "$TMP/o.jsonl")" \
  '.tokens == {input: 0, output: 0, cache_read: 0, cache_write: 0, reasoning: 0} and .tokens_known == false and .is_error == false and .cost_usd == null'
printf '%s\n' '{"type":"system","subtype":"init"}' \
  '{"type":"assistant","message":{"content":[{"type":"server_tool_use"},{"type":"tool_use","id":"t1","name":"X"},"str",null,7,{"type":"tool_use","name":"Y"},{"type":"text"}]}}' \
  '{"type":"user","message":{"content":[{"type":"image"},{"type":"text","text":"x"},{"type":"tool_result","tool_use_id":"t1","is_error":true},{"type":"tool_result"}]}}' > "$TMP/odd.jsonl"
normalize claude "$TMP/odd.jsonl" > "$TMP/o.jsonl"
eq "claude odd shapes: init without id, unknown block types, invalid blocks, tool_use without id, text without text, tool_result without id" \
  "$(jq -s -c '[.[] | [.type, .raw_type // .name // ""]]' "$TMP/o.jsonl")" \
  '[["unknown","system/init"],["unknown","assistant:server_tool_use"],["tool_call","X"],["unknown","assistant:invalid_block"],["unknown","assistant:invalid_block"],["unknown","assistant:invalid_block"],["unknown","assistant:tool_use"],["unknown","assistant:text"],["unknown","user:image"],["tool_result",""],["unknown","user:tool_result"]]'

# codex rows
cx_failure="$TMP/out/codex-failure.jsonl"
cx_sample="$TMP/out/codex-sample.jsonl"
cx_warn="$TMP/out/codex-item-warning.jsonl"
parse_rl=$(jq -n -R -f "$SPIKE/codex/parse.jq" < "$SPIKE/fixtures/codex/failure.jsonl" | jq '[.limit_or_error_events[] | select(.kind == "rate_limit" and (.type == "error" or .type == "turn.failed"))] | length')
eq "codex failure: rate_limited count equals parse.jq's rate_limit entries of type error or turn.failed" "$(count "$cx_failure" '.type == "rate_limited"')" "$parse_rl"
eq "codex failure: rate_limited is codex_text_hint" "$(count "$cx_failure" '.type == "rate_limited" and .raw_kind == "codex_text_hint"')" "$parse_rl"
check "codex failure: each rate_limited comes right before its error" \
  jq -s -e '. as $a | all(range(0; length); . as $i | $a[$i] | if .type == "rate_limited" then ($a[$i + 1].type == "error") else true end)' "$cx_failure"
eq "codex failure: every error is fatal" "$(count "$cx_failure" '.type == "error" and .fatal == true')" "4"
eq "codex failure: 2 failed results, tokens_known false" "$(count "$cx_failure" '.type == "result" and .is_error == true and .tokens_known == false and .turns == 1 and .cost_usd == null')" "2"
eq "codex sample: exactly 2 unknown" "$(count "$cx_sample" '.type == "unknown"')" "2"
eq "codex sample: the unknowns are the synthetic types" "$(jq -s -c '[.[] | select(.type == "unknown") | .raw_type] | sort' "$cx_sample")" '["future.event.kind","item.completed:future_item_kind"]'
eq "codex sample: exactly one result, is_error false" "$(count "$cx_sample" '.type == "result" and .is_error == false')" "1"
eq "codex sample: error item is a warning, not an error or a limit" "$(count "$cx_sample" '.type == "warning" and .kind == "item_error"')/$(count "$cx_sample" '.type == "error"')/$(count "$cx_sample" '.type == "rate_limited"')" "1/0/0"
eq "codex sample: reasoning and todo_list produce nothing" "$(count "$cx_sample" '.raw | test("reasoning|todo_list|item.updated|turn.started")')" "0"
eq "codex sample: 4 tool calls, each with one result" "$(count "$cx_sample" '.type == "tool_call"')/$(count "$cx_sample" '.type == "tool_result"')" "4/4"
eq "codex sample: a started tool item is not duplicated by its completion" "$(count "$cx_sample" '.type == "tool_call" and .id == "item_1"')" "1"
eq "codex sample: result tokens equal turn.completed usage" \
  "$(jq -s -c '[.[] | select(.type == "result")][0].tokens' "$cx_sample")" \
  "$(jq -n -R -f "$SPIKE/codex/parse.jq" < "$SPIKE/fixtures/codex/sample.jsonl" | jq -c '.final.usage | {input: .input_tokens, output: .output_tokens, cache_read: .cached_input_tokens, cache_write: .cache_write_input_tokens, reasoning: .reasoning_output_tokens}')"
eq "codex item-warning: 1 warning, 0 error, 0 rate_limited, 1 result" \
  "$(count "$cx_warn" '.type == "warning"')/$(count "$cx_warn" '.type == "error"')/$(count "$cx_warn" '.type == "rate_limited"')/$(count "$cx_warn" '.type == "result"')" "1/0/0/1"
jqe "codex item-warning: the result is a success with five usage fields" "$(jq -s -c '[.[] | select(.type == "result")][0]' "$cx_warn")" \
  '.is_error == false and .turns == 1 and .tokens == {input: 1000, output: 50, cache_read: 800, cache_write: 0, reasoning: 20}'
eq "codex item-warning: 0 unknown" "$(count "$cx_warn" '.type == "unknown"')" "0"
# item errors never become failures, even when the text looks like a limit
printf '%s\n' '{"type":"item.completed","item":{"id":"e1","type":"error","message":"synthetic: rate limit exceeded 429 too many requests"}}' \
  '{"type":"item.completed","item":{"id":"a1","type":"agent_message","text":"usage limit reached, rate limit, 429"}}' > "$TMP/looks-like-limit.jsonl"
normalize codex "$TMP/looks-like-limit.jsonl" > "$TMP/o.jsonl"
eq "codex item error and agent text that look like limits are never rate_limited" "$(count "$TMP/o.jsonl" '.type == "rate_limited" or .type == "error"')" "0"
# failed command and mcp calls
printf '%s\n' '{"type":"item.completed","item":{"id":"c1","type":"command_execution","exit_code":1,"status":"completed"}}' \
  '{"type":"item.completed","item":{"id":"c2","type":"mcp_tool_call","status":"failed"}}' \
  '{"type":"item.completed","item":{"id":"c3","type":"file_change","status":"completed"}}' > "$TMP/failed-tools.jsonl"
normalize codex "$TMP/failed-tools.jsonl" > "$TMP/o.jsonl"
eq "codex tool_result is_error: non-zero exit, failed status, ok" "$(jq -s -c '[.[] | select(.type == "tool_result") | .is_error]' "$TMP/o.jsonl")" '[true,true,false]'

# ---- malformed and hostile input never makes jq exit non-zero -----------------------------------------------------------------
{
  printf '%s\n' 'not json at all' '' '   ' '[1,2,3]' '"a string"' 'null' '42' 'true' '{' '{"type":' '{"no_type":true}' '{"type":7}' '{"type":null}' \
    '{"type":["assistant"]}' '{"type":{"a":1}}' '{"type":"assistant"}' '{"type":"assistant","message":"str"}' \
    '{"type":"assistant","message":{"content":"plain text"}}' '{"type":"assistant","message":{"content":{"a":1}}}' \
    '{"type":"assistant","message":{"content":[1,null,"x",[],{"type":7},{"type":"text"},{"type":"text","text":{"n":1}},{"type":"tool_use"}]}}' \
    '{"type":"assistant","error":{"x":1}}' '{"type":"user"}' '{"type":"user","message":{"content":"str"}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result"}]}}' '{"type":"system"}' '{"type":"system","subtype":7}' \
    '{"type":"system","subtype":"api_retry"}' '{"type":"system","subtype":"api_retry","attempt":"x","error":{"a":1}}' \
    '{"type":"system","subtype":"permission_denied","tool_name":[1]}' '{"type":"system","subtype":"init","session_id":5}' \
    '{"type":"rate_limit_event","rate_limit_info":{"status":{"a":1},"resetsAt":"soon"}}' \
    '{"type":"result"}' '{"type":"result","subtype":["x"],"is_error":"yes","num_turns":"many","usage":"none","total_cost_usd":"free"}' \
    '{"type":"result","is_error":true,"api_error_status":"429"}' \
    '{"type":"thread.started"}' '{"type":"thread.started","thread_id":{"a":1}}' '{"type":"item.started"}' '{"type":"item.completed","item":[]}' \
    '{"type":"item.completed","item":{"type":"command_execution","exit_code":"x"}}' '{"type":"item.updated","item":5}' \
    '{"type":"item.started","item":{"id":{"a":1},"type":"error"}}' '{"type":"item.completed","item":{"id":["a"],"type":"agent_message","text":5}}' \
    '{"type":"turn.completed"}' '{"type":"turn.completed","usage":[1]}' '{"type":"turn.failed","error":5}' '{"type":"turn.failed","error":null}' \
    '{"type":"error","message":null}' '{"type":"error","message":["429"]}'
} > "$TMP/weird.jsonl"
for cli in claude codex; do
  for src in "$TMP/weird.jsonl" "$SPIKE/fixtures/claude/sample.jsonl" "$SPIKE/fixtures/codex/sample.jsonl" "$SPIKE/fixtures/codex/malformed.jsonl"; do
    sname=$(basename "$src")
    normalize "$cli" "$src" > "$TMP/o.jsonl" 2> "$TMP/err.txt"
    rc=$?
    eq "$cli.jq on $sname exits 0 (malformed lines never make jq fail)" "$rc" "0"
    eq "$cli.jq on $sname: every event validates against the schema" "$(validate "$TMP/o.jsonl")" "0"
  done
done
normalize claude "$TMP/weird.jsonl" > "$TMP/o.jsonl"
eq "claude weird input: 8 malformed_line unknowns" "$(count "$TMP/o.jsonl" '.type == "unknown" and .raw_type == "malformed_line"')" "8"
eq "claude weird input: garbage makes no error event, only the unknown-status and the string-429 rate_limited" "$(count "$TMP/o.jsonl" '.type == "error"')/$(count "$TMP/o.jsonl" '.type == "rate_limited"')" "0/2"
eq "claude weird input: 44 unknown (was 40 before round 4: +1 text without text, +1 text with an object, +1 tool_use without id, +1 tool_result without id)" \
  "$(count "$TMP/o.jsonl" '.type == "unknown"')" "44"
check "claude weird input: no tool_call or tool_result with an empty id, no message from a non-string text" \
  jq -s -e 'all(.[]; if .type == "tool_call" or .type == "tool_result" then (.id != "") else true end)' "$TMP/o.jsonl"
normalize codex "$TMP/weird.jsonl" > "$TMP/o.jsonl"
eq "codex weird input: 37 unknown (was 36 before round 4: +1 agent_message with a numeric text)" "$(count "$TMP/o.jsonl" '.type == "unknown"')" "37"
eq "codex weird input: a non-string agent_message text gives no message" "$(count "$TMP/o.jsonl" '.type == "message"')" "0"
# a final line without a newline is still read
printf '%s' '{"type":"system","subtype":"init","session_id":"abc"}' > "$TMP/nonl.jsonl"
eq "a last line without a newline is read" "$(normalize claude "$TMP/nonl.jsonl" | wc -l | tr -d ' ')" "1"
# a huge line does not break the normalizers
jq -n -c '{type:"assistant",message:{content:[{type:"text",text:([range(200000)|"z"]|join(""))}]}}' > "$TMP/huge.jsonl"
normalize claude "$TMP/huge.jsonl" > "$TMP/o.jsonl"
eq "a 200000-character text is clipped to 4000 and marked truncated" "$(jq -s -c '[(.[0].text | length), .[0].truncated]' "$TMP/o.jsonl")" "[4000,true]"

# ---- hostile fixtures (untrusted text bounded and stripped) --------------------------------------------------------------
for n in claude-hostile codex-hostile; do
  o="$TMP/out/$n.jsonl"
  eq "$n: a 10000-char message is clipped to 4000 with truncated true" "$(jq -s -c '[.[] | select(.type == "message")][0] | [(.text | length), .truncated]' "$o")" "[4000,true]"
  eq "$n: a short message keeps newline and tab, loses ESC and NUL" "$(jq -s -c '[.[] | select(.type == "message")][1].text' "$o")" '"before [31mred hidden ]0;title after\nkept\ttab"'
  check "$n: ESC and NUL never reach the output (decoded)" \
    jq -s -e 'all(.[]; [.. | strings] | all(test("[\u0000-\u0008\u000b-\u001f\u007f-\u009f]") | not))' "$o"
  check "$n: ESC and NUL never reach the output (escaped forms)" test "$(grep -ciE 'u001b|u0000|\\x1b' "$o")" = "0"
  check "$n: no text field is longer than 300 except message text" \
    jq -s -e 'all(.[]; (.message // "" | length) <= 300 and (.kind // "" | length) <= 64 and (.name // "" | length) <= 64 and (.raw_type // "" | length) <= 64)' "$o"
done
eq "claude-hostile: a long tool name is clipped to 64" "$(jq -s '[.[] | select(.type == "tool_call")][0].name | length' "$TMP/out/claude-hostile.jsonl")" "64"
eq "claude-hostile: the tool input (a command) is never copied" "$(grep -c 'rm -rf' "$TMP/out/claude-hostile.jsonl")" "0"
eq "codex-hostile: the failed command is a failed tool_result without its command" "$(count "$TMP/out/codex-hostile.jsonl" '.type == "tool_result" and .is_error == true')" "1"
eq "codex-hostile: the hostile item type is an unknown, clipped" "$(count "$TMP/out/codex-hostile.jsonl" '.type == "unknown" and (.raw_type | length) <= 64')" "1"

# ---- options: ts, exit_code, signal ----------------------------------------------------------------------------------------
normalize claude "$SPIKE/fixtures/claude/sample.jsonl" --arg ts 2026-10-27T00:00:00Z > "$TMP/o.jsonl"
check "--arg ts sets ts on every event" jq -s -e 'all(.[]; .ts == "2026-10-27T00:00:00Z")' "$TMP/o.jsonl"
check "ts is null by default" jq -s -e 'all(.[]; .ts == null)' "$TMP/out/claude-sample.jsonl"
for cli in claude codex; do
  src="$SPIKE/fixtures/$cli/sample.jsonl"
  lines=$(wc -l < "$src" | tr -d ' ')
  normalize "$cli" "$src" --argjson exit_code 0 > "$TMP/o.jsonl"
  eq "$cli: --argjson exit_code 0 appends one exited event last" "$(jq -s -c '.[-1] | [.type, .code, .seq, .raw]' "$TMP/o.jsonl")" "[\"exited\",0,$((lines + 1)),\"process_exit\"]"
  eq "$cli: exactly one exited event" "$(count "$TMP/o.jsonl" '.type == "exited"')" "1"
  eq "$cli: exit_code leaves the other events unchanged" "$(sed '$d' "$TMP/o.jsonl" | cmp - "$TMP/out/$cli-sample.jsonl" > /dev/null 2>&1 && echo same || echo different)" "same"
  eq "$cli: exited validates" "$(validate "$TMP/o.jsonl")" "0"
  normalize "$cli" "$src" --argjson exit_code 137 --arg signal KILL > "$TMP/o.jsonl"
  eq "$cli: exit code and signal" "$(jq -s -c '.[-1] | [.code, .signal]' "$TMP/o.jsonl")" "[137,\"KILL\"]"
  eq "$cli: no exited event without the option" "$(count "$TMP/out/$cli-sample.jsonl" '.type == "exited"')" "0"
  normalize "$cli" /dev/null --argjson exit_code 2 > "$TMP/o.jsonl"
  eq "$cli: an empty run with an exit code is just exited" "$(jq -s -c '[.[] | [.type, .code, .seq]]' "$TMP/o.jsonl")" '[["exited",2,1]]'
done

# ---- round 2: the raw-key coverage check is not vacuous ---------------------------------------------------------------------
# key_listed unit tests (a trailing /* is a wildcard only for keys that start with the part before the star)
for k in 'system/init' 'system/api_retry' 'assistant' 'assistant:text' 'user:tool_result' 'rate_limit_event' 'result/success' \
  'result/error_max_turns' 'system/status' 'user:text' 'assistant:thinking'; do
  check "key_listed claude: $k is listed" key_listed claude "$k"
done
for k in 'brand_new_type' 'system/whatever' 'system' 'result' 'resultx/success' 'user:image' 'user' 'assistant:server_tool_use' 'rate_limit_event/x' ''; do
  check "key_listed claude: $k is NOT listed" test "$(key_listed claude "$k" && echo listed || echo no)" = "no"
done
for k in 'thread.started' 'item.completed:agent_message' 'turn.completed' 'error' 'item.updated' 'item.completed:todo_list'; do
  check "key_listed codex: $k is listed" key_listed codex "$k"
done
for k in 'brand.new' 'item.completed:future_item_kind' 'turn.cancelled' 'item.started:agent_message_x'; do
  check "key_listed codex: $k is NOT listed" test "$(key_listed codex "$k" && echo listed || echo no)" = "no"
done
# a brand-new raw type in a fixture is reported when the normalizer does not turn it into unknown
printf '%s\n' '{"type":"brand_new_type","x":1}' '{"type":"system","subtype":"whatever"}' > "$TMP/newtypes.jsonl"
normalize claude "$TMP/newtypes.jsonl" > "$TMP/o.jsonl"
eq "a brand-new claude raw type and system/whatever both yield unknown with their raw type" \
  "$(jq -s -c '[.[] | select(.type == "unknown") | .raw_type]' "$TMP/o.jsonl")" '["brand_new_type","system/whatever"]'
eq "raw keys of those lines are reported as problems when the output has no unknown for them" \
  "$(rawkey_problems claude "$TMP/newtypes.jsonl" /dev/null | grep -c '^raw key')" "2"
eq "and are not reported when the normalizer yields unknown for them" \
  "$(rawkey_problems claude "$TMP/newtypes.jsonl" "$TMP/o.jsonl" | grep -c '^raw key')" "0"

# mutation: a scratch copy of the normalizer with one mapped key removed must fail the coverage check on a fixture that
# contains that key (the real normalizer's output is used, as in the main loop, so the key is not an unknown)
mutate_mapped() { # cli key-regex out-file : scratch copy of <cli>.jq with that key renamed inside mapped_keys only
  sed "/^def mapped_keys/,/^];/ s|\"$2\"|\"zz/removed\"|" "$NORM/$1.jq" > "$3"
}
for m in 'claude|assistant:tool_use|claude-routine' 'claude|system/init|claude-routine' 'claude|rate_limit_event|claude-routine' \
  'claude|result/\*|claude-routine' 'claude|assistant:text|claude-routine' 'claude|user:tool_result|claude-routine' \
  'codex|turn\.completed|codex-item-warning' 'codex|thread\.started|codex-item-warning' 'codex|item\.completed:agent_message|codex-item-warning'; do
  IFS='|' read -r mcli mkey mname <<< "$m"
  mfile="$FIXN/$mname.jsonl"
  mj="$TMP/mutant-$mcli.jq"
  mutate_mapped "$mcli" "$mkey" "$mj"
  check "mutation $mcli/$mkey: the scratch copy differs from the real normalizer" test "$(cmp -s "$mj" "$NORM/$mcli.jq" && echo same || echo different)" = "different"
  check "mutation $mcli/$mkey: the scratch copy still compiles" jq -c -n -R -f "$mj" < /dev/null
  eq "mutation $mcli/$mkey: the real normalizer passes the coverage check on $mname" \
    "$(rawkey_problems "$mcli" "$mfile" "$TMP/out/$mname.jsonl" | grep -c '^raw key')" "0"
  mp=$(rawkey_problems "$mcli" "$mfile" "$TMP/out/$mname.jsonl" "$mj" | grep -c '^raw key')
  check "mutation $mcli/$mkey: the coverage check FAILS against the broken copy ($mp problem(s))" test "$mp" -ge 1
done
# the same for the ignored list: dropping an ignored key makes the real output's silent drop a coverage failure
sed '/^def ignored_keys/,/^];/ s|"assistant:thinking"|"zz/removed"|' "$NORM/claude.jq" > "$TMP/mutant-ign.jq"
check "mutation claude ignored assistant:thinking: the coverage check FAILS on claude-routine" \
  test "$(rawkey_problems claude "$FIXN/claude-routine.jsonl" "$TMP/out/claude-routine.jsonl" "$TMP/mutant-ign.jq" | grep -c '^raw key')" -ge 1

# ---- round 2: turn rule and state machine text in the spec ------------------------------------------------------------------
# round 4, fix 1: turns are reserved at dispatch (rule 1 never passes 40); the round 2 wording (count 1 at dispatch, reconcile
# afterwards) must be gone
check "spec: the old wording 'counts 1 turn at dispatch' is gone" test "$(grep -c 'counts 1 turn at dispatch' "$SPEC_FLAT")" = "0"
check "spec: the old wording 'still counts at least 1 turn' is gone" test "$(grep -c 'still counts at least 1 turn' "$SPEC_FLAT")" = "0"
check "spec: the old wording 'reconciles with result.turns' is gone" test "$(grep -c 'reconciles with' "$SPEC_FLAT")" = "0"
check "spec: reserve at dispatch, Claude its --max-turns value, Codex 1" \
  grep -qF 'Reserve at dispatch.** Before every invocation the scheduler reserves that invocation'"'"'s maximum: for Claude its `--max-turns` value, for Codex 1' "$SPEC_FLAT"
check "spec: Claude --max-turns is min(5, 40 minus turns already used or reserved)" \
  grep -qF '`--max-turns` is set to min(5, 40 minus turns already used or reserved)' "$SPEC_FLAT"
check "spec: a Claude invocation is never started with --max-turns 0" grep -qF 'never started with `--max-turns` 0' "$SPEC_FLAT"
check "spec: the scheduler refuses the dispatch when the reservation does not fit under 40" \
  grep -qF 'refuses the dispatch (no child process is started) when the reservation does not fit under 40' "$SPEC_FLAT"
check "spec: a result settles to max(1, the highest turns among results with turns_known true), not the last result" \
  grep -qF 'The reservation is then replaced by max(1, the highest `turns` among the invocation'"'"'s `result` events that have `turns_known` true)' "$SPEC_FLAT"
check "spec: the highest counts, not the last, and a later result never lowers an earlier count" \
  grep -qF 'The highest counts, not the last, so a later `result` can never lower what an earlier one already counted' "$SPEC_FLAT"
check "spec: is_error still follows the last result; the two rules are independent" \
  grep -qF 'The `is_error` flag still follows the last `result` (row 15); the two rules are independent' "$SPEC_FLAT"
check "spec: a result with turns_known false is treated exactly as if no result had arrived (full reservation kept)" \
  grep -qF 'a `result` with `turns_known` false is treated exactly as if no result had arrived' "$SPEC_FLAT"
check "spec: turns_known false when num_turns is missing, a string or negative" \
  grep -qF '(missing, a string or a negative number gives `turns_known` false and `turns` 0)' "$SPEC_FLAT"
check "spec: Codex turns_known is always true" grep -qF 'for Codex always' "$SPEC_FLAT"
check "spec: refuse when 40 minus used-or-reserved is 0 or less, for Claude and Codex alike" \
  grep -qF 'for Claude and for Codex alike when 40 minus turns already used or reserved is 0 or less' "$SPEC_FLAT"
check "spec: the old refusal 'is 0, Codex when it is less than 1' is gone" test "$(grep -c 'Claude when 40 minus turns already used or reserved is 0,' "$SPEC_FLAT")" = "0"
check "spec: --max-turns is always at least 1" grep -qF 'the value is always at least 1' "$SPEC_FLAT"
check "spec worked example: 38 used, Claude given 2, reports 3 -> 41 counted, next dispatch refused" \
  grep -qF 'At 38 used, Claude is given 2 and reports `num_turns` 3: 41 is counted as reported, 40 minus 41 is -1, which is 0 or less, and the next dispatch is refused' "$SPEC_FLAT"
check "spec worked example: a result without num_turns counts the full reservation 5" \
  grep -qF 'whose `result` has no `num_turns` (`turns_known` false) counts 5' "$SPEC_FLAT"
check "spec: check and reserve are one serialized step per task (atomic)" \
  grep -qF 'are one serialized step (one lock per task, nothing can run between the check and the record)' "$SPEC_FLAT"
check "spec: two concurrent dispatches can never both reserve against the same count" \
  grep -qF 'Two concurrent dispatches can never both reserve against the same count' "$SPEC_FLAT"
check "spec: the 40-turn count belongs to the task and a failover never resets it (decision C, pending the human)" \
  grep -qF 'carry across a failover to another provider: a failover never resets the count' "$SPEC_FLAT"
check "spec: the result event has turns_known in the event rules and the Claude and Codex mappings" \
  test "$(grep -c 'turns_known' "$SPEC")" -ge 6
check "spec: with no result the full reservation stays counted" grep -qF 'the full reservation stays counted' "$SPEC_FLAT"
check "spec: no failure path can make a run cheaper than its reservation" grep -qF 'No failure path can make a run cheaper than its reservation' "$SPEC_FLAT"
check "spec: no-result cases named: crash, watchdog, cancel(), Codex bare top-level error" \
  grep -qF '(a crash, the watchdog, `cancel()`, a Codex bare top-level `error`)' "$SPEC_FLAT"
check "spec worked example: at 38 used Claude gets --max-turns 2" grep -qF 'At 38 turns used, Claude gets `--max-turns` 2' "$SPEC_FLAT"
check "spec worked example: at 40 nothing is dispatched" grep -qF 'At 40 turns used or reserved, nothing is dispatched' "$SPEC_FLAT"
check "spec worked example: reserved at 5 and killed before its result counts 5" \
  grep -qF 'A Claude call reserved at 5 and killed before its `result` counts 5' "$SPEC_FLAT"
check "spec: Claude's native cap makes the reservation enforceable" grep -qF "Claude's native cap is what makes the turn reservation enforceable" "$SPEC_FLAT"
check "spec: Codex has no native cap and 1 per exec is the approved rule" grep -qF 'Codex has no native cap; 1 turn per `exec` call is the approved rule' "$SPEC_FLAT"
check "spec: the transition function takes (state, event, invocation_flags)" grep -qF '(state, event, invocation_flags)' "$SPEC_FLAT"
check "spec: row 7 needs a per-invocation limit_seen flag" grep -qF '`limit_seen`' "$SPEC_FLAT"
check "spec: limit_seen wins over a Codex limit error with no turn.failed" grep -qF 'a Codex limit `error` with no `turn.failed`' "$SPEC_FLAT"
check "spec: a rate_limited seen while spawning is not lost" grep -qF 'seen while `spawning` is not lost' "$SPEC"
check "spec: a successful result followed by a non-zero exit is exited, is_error from the exit" \
  grep -qE '^\| 11 \| `running` \| `result\{is_error:false\}` seen, then a non-zero exit.*`exited`.*derived from the exit code' "$SPEC"
check "spec: a successful result followed by death from a non-cancel signal is row 11 (exited)" \
  grep -qE '^\| 11 \| `running` \| `result\{is_error:false\}` seen, then a non-zero exit or death by a signal that was not a `cancel\(\)`.*`exited`' "$SPEC"
check "spec: row 7 covers spawning and running" grep -qE '^\| 7 \| `spawning`, `running` \|' "$SPEC"
# round 4, fix 3: the ordinary events have explicit rows, the exited event is named, the illegal pairs are listed
check "spec: row 12, warning/limit_notice/unknown/error{fatal:false} stay in spawning" \
  grep -qE '^\| 12 \| `spawning` \| `warning`, `limit_notice`, `unknown`, `error\{fatal:false\}` \| `spawning` \|' "$SPEC"
check "spec: row 13, error{fatal:true} stays in spawning until the child ends (decision stated)" \
  grep -qE '^\| 13 \| `spawning` \| `error\{fatal:true\}` \| `spawning` \|.*decision: a fatal error is information, not an exit' "$SPEC"
check "spec: row 14, the ordinary events stay in running" \
  grep -qE '^\| 14 \| `running` \| `message`, `tool_call`, `tool_result`, `warning`, `limit_notice`, `error` \(fatal or not\), `unknown` \| `running` \|' "$SPEC"
check "spec: row 15, result stays running, sets result_seen and is_error, the last result counts" \
  grep -qE '^\| 15 \| `running` \| `result\{is_error\}` \| `running` \| sets `result_seen` and `is_error`.*the last one counts' "$SPEC"
check "spec: row 6 no longer claims a watchdog kill (the watchdog is row 10, killed)" \
  grep -qE '^\| 6 \|.*neither `cancel\(\)` nor the watchdog, which are row 10' "$SPEC"
check "spec: row 10 still reaps the child and drains stdout and stderr to EOF (no zombie, no blocked pipe)" \
  grep -qE '^\| 10 \|.*still reaps the child and drains its stdout and stderr to EOF \(no zombie process, no blocked pipe\)' "$SPEC"
check "spec: row 10 drops the invocation flags" grep -qE '^\| 10 \|.*the invocation flags are dropped' "$SPEC"
check "spec: cancel() with no state is illegal; legal in every state that exists" \
  grep -qF '`cancel()` is legal in every state that exists (rows 10 and 16). Before row 1 there is no state and nothing to cancel, so `cancel()` with no state is illegal.' "$SPEC_FLAT"
check "spec: an invocation ends at the exited event or at cancel() and the function then returns empty flags" \
  grep -qF 'the function then returns empty flags' "$SPEC_FLAT"
check "spec: error and warning keep an empty message by design; kind is never empty (unknown_error)" \
  grep -qF 'By design, `error` and `warning` events keep an empty `message`' "$SPEC_FLAT"
check "spec: an empty Claude assistant error string gives kind unknown_error" grep -qF 'an empty error string gives kind `unknown_error`' "$SPEC_FLAT"
check "spec: settlement happens once, when the invocation ends, never while the child runs" \
  grep -qF 'Settlement happens at the end of the invocation' "$SPEC_FLAT"
check "spec: a mix of known and unknown results keeps max(reservation, highest known)" \
  grep -qF 'the count is max(the reservation, that highest known `turns`): a mix of known and unknown results never frees turns' "$SPEC_FLAT"
check "spec: row 16, cancel in exited or killed is an idempotent no-op" grep -qE '^\| 16 \| `exited`, `killed` \| `cancel\(\)` or watchdog \| unchanged \|' "$SPEC"
check "spec: the exited event is named as the child-ends trigger" grep -qF 'that trigger is the **`exited` event**' "$SPEC_FLAT"
check "spec: the exited event applies the end-of-invocation precedence" grep -qF 'The `exited` event applies it.' "$SPEC_FLAT"
check "spec: an Illegal transitions list exists" grep -qF '**Illegal transitions.**' "$SPEC"
check "spec: illegal: session_started while in running" grep -qF '`session_started` while in `running`' "$SPEC_FLAT"
check "spec: illegal: events in idle, rate_limited, exited and killed, and after a terminal state" \
  grep -qF 'while in `idle` or `rate_limited` (no child is running), and in `exited` or `killed` (events after a terminal state)' "$SPEC_FLAT"
check "spec: illegal: send outside idle, resume outside rate_limited" grep -qF '`send(prompt)` in any state but `idle`; `resume` in any state but `rate_limited`' "$SPEC_FLAT"
check "spec: the flags are limit_seen, result_seen and the is_error of the last result" \
  grep -qF '`result_seen` and `is_error` (that of the last `result`)' "$SPEC_FLAT"
check "spec: row 10 stops feeding events of a cancelled child and keeps the turn reservation" \
  grep -qE '^\| 10 \|.*feeds no further event of that child to the function.*the turn reservation stays' "$SPEC"

# ---- round 2: clip cuts first and cleans after, so 32k control characters stay fast ---------------------------------------
esc32k=$(jq -n -r '[range(32000) | "\u001b"] | join("")')
jq -n -c --arg e "$esc32k" '
  {type:"system",subtype:"init",session_id:$e},
  {type:"assistant",message:{content:[{type:"text",text:$e},{type:"tool_use",id:$e,name:$e}]}},
  {type:"user",message:{content:[{type:"tool_result",tool_use_id:$e}]}},
  {type:"assistant",error:$e,message:{content:[]}},
  {type:"system",subtype:"api_retry",error:$e},
  {type:"result",subtype:$e,stop_reason:$e},
  {type:$e}' > "$TMP/esc-claude.jsonl"
jq -n -c --arg e "$esc32k" '
  {type:"thread.started",thread_id:$e},
  {type:"item.completed",item:{id:$e,type:"agent_message",text:$e}},
  {type:"item.completed",item:{id:$e,type:"command_execution",exit_code:0}},
  {type:"item.completed",item:{id:$e,type:"error",message:$e}},
  {type:"item.completed",item:{id:"x",type:$e}},
  {type:"error",message:$e},
  {type:"turn.failed",error:{message:$e}},
  {type:$e}' > "$TMP/esc-codex.jsonl"
for cli in claude codex; do
  t0=$(jq -n 'now')
  normalize "$cli" "$TMP/esc-$cli.jsonl" > "$TMP/o.jsonl"
  t1=$(jq -n 'now')
  eq "$cli: 32k ESC characters in every text field finish in under 10 s" "$(jq -n --argjson a "$t0" --argjson b "$t1" '(($b - $a) < 10)')" "true"
  eq "$cli: 32k ESC output has no control characters and validates" \
    "$(jq -s '[.. | strings | select(test("[\u0000-\u0008\u000b-\u001f\u007f-\u009f]"))] | length' "$TMP/o.jsonl")/$(validate "$TMP/o.jsonl")" "0/0"
  check "$cli: 32k ESC message text is 4000 spaces and truncated" \
    jq -s -e '[.[] | select(.type == "message")][0] | (.text | length) == 4000 and (.text | test("^ +$")) and .truncated == true' "$TMP/o.jsonl"
done
# clipping cuts to the limit, then cleans: same lengths and content as before for an ordinary string with a control character
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"ab\u0001cd\tef\ngh"}]}}' > "$TMP/clipsmall.jsonl"
eq "clip keeps newline and tab, replaces other control characters with a space" \
  "$(normalize claude "$TMP/clipsmall.jsonl" | jq -c '.text')" '"ab cd\tef\ngh"'

# ---- round 2: codex tool items without an id, declined, string exit codes ----------------------------------------------------
printf '%s\n' '{"type":"item.started","item":{"type":"command_execution","status":"in_progress"}}' \
  '{"type":"item.completed","item":{"type":"command_execution","exit_code":0,"status":"completed"}}' \
  '{"type":"item.started","item":{"id":"","type":"file_change"}}' \
  '{"type":"item.completed","item":{"id":"","type":"file_change","status":"completed"}}' > "$TMP/noid.jsonl"
normalize codex "$TMP/noid.jsonl" > "$TMP/o.jsonl"
eq "codex tool items without an id: one tool_call and one tool_result each, with the same id" \
  "$(jq -s -c '[.[] | select(.type == "tool_call" or .type == "tool_result") | [.type, .id]]' "$TMP/o.jsonl")" \
  '[["tool_call","line2"],["tool_result","line2"],["tool_call","line4"],["tool_result","line4"]]'
eq "codex tool items without an id: the result ids all match an earlier tool_call" "$(validate "$TMP/o.jsonl")" "0"
printf '%s\n' '{"type":"item.completed","item":{"id":"d1","type":"command_execution","status":"declined"}}' \
  '{"type":"item.completed","item":{"id":"d2","type":"mcp_tool_call","status":"completed"}}' > "$TMP/declined.jsonl"
normalize codex "$TMP/declined.jsonl" > "$TMP/o.jsonl"
eq "codex declined status is a tool_result error, completed is not" "$(jq -s -c '[.[] | select(.type == "tool_result") | .is_error]' "$TMP/o.jsonl")" '[true,false]'
{
  eci=0
  for ec in '"0"' '"2"' '"x"' '""' 'null' '3' '0' '[1]' '"0.0"'; do
    eci=$((eci + 1))
    printf '{"type":"item.completed","item":{"id":"e%s","type":"command_execution","exit_code":%s}}\n' "$eci" "$ec"
  done
} > "$TMP/exitcodes.jsonl"
normalize codex "$TMP/exitcodes.jsonl" > "$TMP/o.jsonl"
eq "codex exit_code: string 0 ok, string 2 error, non-numeric error, empty error, null ok, 3 error, 0 ok, array error, 0.0 ok" \
  "$(jq -s -c '[.[] | select(.type == "tool_result") | .is_error]' "$TMP/o.jsonl")" '[false,true,true,true,false,true,false,true,false]'

# ---- round 2: claude api_error_status as a string, integers for whole-number fields -------------------------------------------
{
  printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":"429","num_turns":1}'
  printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":429,"num_turns":1}'
  printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":"500","num_turns":1}'
  printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":"abc","num_turns":1}'
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"api_error_status":"429","num_turns":1}'
} > "$TMP/r429s.jsonl"
normalize claude "$TMP/r429s.jsonl" > "$TMP/o.jsonl"
eq "claude api_error_status 429 as string or number: both map to claude_result_429; 500, abc and a success do not" \
  "$(jq -s -c '[.[] | if .type == "rate_limited" then "429" else "result" end]' "$TMP/o.jsonl")" '["429","result","429","result","result","result","result"]'
{
  printf '%s\n' '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","utilization":0.9,"resetsAt":1790003600.7}}'
  printf '%s\n' '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1790003600.7}}'
  printf '%s\n' '{"type":"result","subtype":"success","num_turns":2.0,"duration_ms":3100.9,"usage":{"input_tokens":1.5,"output_tokens":2}}'
} > "$TMP/fractions.jsonl"
normalize claude "$TMP/fractions.jsonl" > "$TMP/o.jsonl"
eq "claude: fractional reset_at and duration_ms are floored to integers; utilization stays a number" \
  "$(jq -s -c '[.[0].reset_at, .[0].utilization, .[1].reset_at, .[2].duration_ms, .[2].turns, .[2].tokens.input]' "$TMP/o.jsonl")" '[1790003600,0.9,1790003600,3100,2,1]'
eq "those events validate against the schema" "$(validate "$TMP/o.jsonl")" "0"
check "schema: reset_at, retry_after_s, duration_ms, turns and the token fields are integers" \
  jq -e '."$defs" as $d
    | ($d.limit_notice.allOf[1].properties.reset_at.type == "integer")
    and ($d.rate_limited.allOf[1].properties.reset_at.type == "integer")
    and ($d.rate_limited.allOf[1].properties.retry_after_s.type == "integer")
    and ($d.result.allOf[1].properties.duration_ms.type == "integer")
    and ($d.result.allOf[1].properties.turns.type == "integer")
    and ([$d.tokens.properties[].type] | all(. == "integer"))
    and ($d.limit_notice.allOf[1].properties.utilization.type == "number")' "$SCHEMA"
printf '%s\n' '{"type":"rate_limited","provider":"claude","seq":1,"ts":null,"raw":"x","raw_kind":"k","reset_at":1.5}' > "$TMP/fracevent.jsonl"
eq "validator: a fractional reset_at fails the schema" "$(validate "$TMP/fracevent.jsonl")" "1"

# ---- round 2: the observed-capture email check ignores harmless at-signs -------------------------------------------------------
printf '%s\n' '{"text":"installed @types/node and @scope/pkg"}' > "$TMP/at-harmless.txt"
printf '%s\n' '{"text":"contact someone@example.com now"}' > "$TMP/at-email.txt"
eq "email check: @types/node is harmless" "$(email_hits "$TMP/at-harmless.txt")" "0"
eq "email check: an email-shaped string is caught" "$(email_hits "$TMP/at-email.txt")" "1"

# ---- round 4, fix 2: a missing or mistyped required field becomes unknown, never an empty id or empty text -----------------
# each case is "raw key|one raw line"; the normalizer must give exactly one unknown with that raw key as raw and raw_type
bad_field_cases=(
  'claude|assistant:tool_use|{"type":"assistant","message":{"content":[{"type":"tool_use","name":"X"}]}}'
  'claude|assistant:tool_use|{"type":"assistant","message":{"content":[{"type":"tool_use","id":5,"name":"X"}]}}'
  'claude|assistant:tool_use|{"type":"assistant","message":{"content":[{"type":"tool_use","id":"","name":"X"}]}}'
  'claude|assistant:tool_use|{"type":"assistant","message":{"content":[{"type":"tool_use","id":null,"name":"X"}]}}'
  'claude|assistant:tool_use|{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1"}]}}'
  'claude|assistant:tool_use|{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":7}]}}'
  'claude|assistant:tool_use|{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":""}]}}'
  'claude|assistant:tool_use|{"type":"assistant","message":{"content":[{"type":"tool_use"}]}}'
  'claude|assistant:text|{"type":"assistant","message":{"content":[{"type":"text"}]}}'
  'claude|assistant:text|{"type":"assistant","message":{"content":[{"type":"text","text":5}]}}'
  'claude|assistant:text|{"type":"assistant","message":{"content":[{"type":"text","text":null}]}}'
  'claude|assistant:text|{"type":"assistant","message":{"content":[{"type":"text","text":{"n":1}}]}}'
  'claude|assistant:text|{"type":"assistant","message":{"content":[{"type":"text","text":["a"]}]}}'
  'claude|user:tool_result|{"type":"user","message":{"content":[{"type":"tool_result"}]}}'
  'claude|user:tool_result|{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":5}]}}'
  'claude|user:tool_result|{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":""}]}}'
  'claude|user:tool_result|{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":null,"is_error":true}]}}'
  'claude|user:tool_result|{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":["t1"]}]}}'
  'codex|item.completed:agent_message|{"type":"item.completed","item":{"id":"m1","type":"agent_message"}}'
  'codex|item.completed:agent_message|{"type":"item.completed","item":{"id":"m1","type":"agent_message","text":5}}'
  'codex|item.completed:agent_message|{"type":"item.completed","item":{"id":"m1","type":"agent_message","text":null}}'
  'codex|item.completed:agent_message|{"type":"item.completed","item":{"id":"m1","type":"agent_message","text":{"nested":"object"}}}'
  'codex|item.completed:agent_message|{"type":"item.completed","item":{"id":"m1","type":"agent_message","text":["a"]}}'
)
bad_n=0
for c in "${bad_field_cases[@]}"; do
  IFS='|' read -r bcli bkey bline <<< "$c"
  bad_n=$((bad_n + 1))
  printf '%s\n' "$bline" > "$TMP/badfield.jsonl"
  normalize "$bcli" "$TMP/badfield.jsonl" > "$TMP/o.jsonl"
  eq "malformed field case $bad_n ($bcli $bkey): exactly one event, an unknown with raw and raw_type $bkey" \
    "$(jq -s -c --arg k "$bkey" '[.[] | [.type, .raw, .raw_type]] == [["unknown", $k, $k]]' "$TMP/o.jsonl")" "true"
  check "malformed field case $bad_n ($bcli $bkey): keys are key names (an array of strings)" \
    jq -s -e '.[0].keys | type == "array" and all(.[]; type == "string")' "$TMP/o.jsonl"
  eq "malformed field case $bad_n ($bcli $bkey): the unknown validates against the schema" "$(validate "$TMP/o.jsonl")" "0"
done
eq "the malformed-field case list has 23 entries" "$bad_n" "23"
# valid shapes still map, and an empty string text is a valid string
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"X"},{"type":"text","text":"hi"},{"type":"text","text":""}]}}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}' \
  '{"type":"assistant","message":{"content":"plain"}}' > "$TMP/valid.jsonl"
normalize claude "$TMP/valid.jsonl" > "$TMP/o.jsonl"
eq "claude valid shapes still map: tool_call, message, empty-string message, tool_result, string content" \
  "$(jq -s -c '[.[] | [.type, (.id // .text), (if .type == "tool_result" then .is_error else (.name // .truncated) end)]]' "$TMP/o.jsonl")" \
  '[["tool_call","t1","X"],["message","hi",false],["message","",false],["tool_result","t1",false],["message","plain",false]]'
eq "claude valid shapes: 0 unknown and the events validate" "$(count "$TMP/o.jsonl" '.type == "unknown"')/$(validate "$TMP/o.jsonl")" "0/0"
printf '%s\n' '{"type":"item.completed","item":{"id":"m1","type":"agent_message","text":"hi"}}' \
  '{"type":"item.completed","item":{"id":"m2","type":"agent_message","text":""}}' > "$TMP/valid.jsonl"
normalize codex "$TMP/valid.jsonl" > "$TMP/o.jsonl"
eq "codex valid agent_message and empty-string agent_message both map to message" \
  "$(jq -s -c '[.[] | [.type, .text, .truncated]]' "$TMP/o.jsonl")" '[["message","hi",false],["message","",false]]'
eq "codex valid messages: the events validate" "$(validate "$TMP/o.jsonl")" "0"
# a tool_use name of a string type but only control characters is still a (cleaned, non-empty) name
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"\u0001"}]}}' > "$TMP/ctl.jsonl"
eq "a control-character-only name is a string, so the tool_call stays (cleaned to a space)" "$(normalize claude "$TMP/ctl.jsonl" | jq -c '[.type, .name]')" '["tool_call"," "]'
# the deliberate round 2 rule stays: Codex tool items without an id get line<N>
eq "codex tool items without an id still get line<N> ids (round 2 rule unchanged)" \
  "$(normalize codex "$TMP/noid.jsonl" | jq -s -c '[.[] | select(.type == "tool_call") | .id]')" '["line2","line4"]'
# golden: the one committed fixture line with a malformed required field
eq "golden codex-malformed: line 16 (agent_message with an object text) is an unknown, not a message" \
  "$(sed -n '/"seq":16,/p' "$EXPECTED/codex-malformed.jsonl" | jq -c '[.type, .raw_type]')" '["unknown","item.completed:agent_message"]'
eq "golden codex-malformed: the only message events are the valid line 17" "$(jq -s -c '[.[] | select(.type == "message") | .seq]' "$EXPECTED/codex-malformed.jsonl")" "[17]"

# ---- round 4, fix 3: the state machine accepts the ordinary events of a real run, proven by replaying every fixture ------------
# ===== REFERENCE TRANSITION FUNCTION =====================================================================================
# Implements the table in docs/spec/adapter-interface.md ("Session state machine", rows 1 to 16) and the explicit illegal list,
# and nothing more. The trailing "# ROWn" tags name the spec row; the mutation proof edits the line tagged ROW14.
# input: none (called as transition($state; $event; $flags)); $state is null before row 1.
# Triggers: the 11 event types, plus the commands start, send, cancel, resume.
cat > "$TMP/reference.jq" <<'EOF'
def flags0: {limit_seen: false, reset_at: null, result_seen: false, is_error: null};
def inl($l): . as $x | any($l[]; . == $x);
def clean_exit($e): ($e.code == 0) and (($e.signal // null) == null);
def transition($state; $e; $f):
  def ok($s; $nf): {ok: true, state: $s, flags: $nf};
  def bad: {ok: false, state: $state, flags: $f};
  def with_limit: $f | .limit_seen = true | .reset_at = ([.reset_at, $e.reset_at] | map(select(. != null)) | max);
  ($e.type) as $t
  | if $t == "start" then (if $state == null then ok("spawning"; flags0) else bad end)                          # ROW1
    elif $t == "send" then (if $state == "idle" then ok("spawning"; flags0) else bad end)                       # ROW9
    elif $t == "resume" then (if $state == "rate_limited" then ok("idle"; $f) else bad end)                     # ROW8
    elif $t == "cancel" then
      (if ($state | inl(["spawning", "running", "idle", "rate_limited"])) then ok("killed"; flags0)                 # ROW10
       elif ($state | inl(["exited", "killed"])) then ok($state; $f)                                            # ROW16
       else bad end)
    elif $state == "spawning" then
      if $t == "session_started" then ok("running"; $f)                                                         # ROW2
      elif $t == "rate_limited" then ok("spawning"; with_limit)                                                 # ROW7
      elif ($t | inl(["warning", "limit_notice", "unknown"])) then ok("spawning"; $f)                           # ROW12
      elif $t == "error" and $e.fatal == false then ok("spawning"; $f)                                          # ROW12
      elif $t == "error" and $e.fatal == true then ok("spawning"; $f)                                           # ROW13
      elif $t == "exited" then (if $f.limit_seen then ok("rate_limited"; flags0) else ok("exited"; flags0) end)         # ROW7 ROW3
      else bad end
    elif $state == "running" then
      if $t == "rate_limited" then ok("running"; with_limit)                                                    # ROW7
      elif $t == "result" then ok("running"; $f | .result_seen = true | .is_error = $e.is_error)                # ROW15
      elif ($t | inl(["message", "tool_call", "tool_result", "warning", "limit_notice", "error", "unknown"])) then ok("running"; $f)   # ROW14
      elif $t == "exited" then
        (if $f.limit_seen then ok("rate_limited"; flags0)                                                           # ROW7
         elif $f.result_seen and $f.is_error == false and (clean_exit($e) | not) then ok("exited"; flags0)          # ROW11
         elif $f.result_seen and $f.is_error == false then ok("idle"; flags0)                                       # ROW4
         elif $f.result_seen then ok("exited"; flags0)                                                              # ROW5
         else ok("exited"; flags0) end)                                                                             # ROW6
      else bad end
    else bad end;
EOF
# ===== END REFERENCE TRANSITION FUNCTION =================================================================================
{
  cat "$TMP/reference.jq"
  echo '($f // flags0) as $fl | transition($s; $e; $fl) | if .ok then .state else "illegal" end'
} > "$TMP/one.jq"
{
  cat "$TMP/reference.jq"
  echo 'transition($s; $e; $f) | .flags'
} > "$TMP/oneflags.jq"
{
  cat "$TMP/reference.jq"
  cat <<'EOF'
def replay: reduce .[] as $e ({state: "spawning", flags: flags0, illegal: []};
  transition(.state; $e; .flags) as $r
  | if $r.ok then .state = $r.state | .flags = $r.flags
    else .illegal += [{seq: $e.seq, type: $e.type, state: .state}] end);
replay
EOF
} > "$TMP/replay.jq"
tr_one() { # state-json event-json [flags-json] : prints the new state, or "illegal"
  jq -n -c -r --argjson s "$1" --argjson e "$2" --argjson f "${3:-null}" -f "$TMP/one.jq"
}
tr_flags() { # state-json event-json flags-json : prints the flags after the transition
  jq -n -c --argjson s "$1" --argjson e "$2" --argjson f "$3" -f "$TMP/oneflags.jq"
}
replay_json() { # json-array-of-events : prints "<end state>/<number of illegal transitions>" (the replay starts in spawning, after row 1)
  printf '%s' "$1" | jq -c -f "$TMP/replay.jq" | jq -r '"\(.state)/\(.illegal | length)"'
}
replay_flags() { printf '%s' "$1" | jq -c -f "$TMP/replay.jq" | jq -c '.flags'; }

# the matrix: every (state, trigger) pair against an independent statement of the table (a bash case, written from the spec rows)
matrix_event() {
  case "$1" in
    error_nonfatal) echo '{"type":"error","fatal":false}' ;;
    error_fatal) echo '{"type":"error","fatal":true}' ;;
    result_ok) echo '{"type":"result","is_error":false}' ;;
    result_err) echo '{"type":"result","is_error":true}' ;;
    exited_clean) echo '{"type":"exited","code":0}' ;;
    *) echo "{\"type\":\"$1\"}" ;;
  esac
}
matrix_expect() { # state trigger : the table's target state; "illegal" for every pair the table does not allow
  case "$1:$2" in
    none:start) echo spawning ;;
    spawning:cancel | running:cancel | idle:cancel | rate_limited:cancel | killed:cancel) echo killed ;;
    exited:cancel) echo exited ;;
    idle:send) echo spawning ;;
    rate_limited:resume) echo idle ;;
    spawning:session_started) echo running ;;
    spawning:warning | spawning:limit_notice | spawning:unknown | spawning:error_nonfatal | spawning:error_fatal | spawning:rate_limited) echo spawning ;;
    spawning:exited_clean) echo exited ;;
    running:message | running:tool_call | running:tool_result | running:warning | running:limit_notice | running:unknown) echo running ;;
    running:error_nonfatal | running:error_fatal | running:rate_limited | running:result_ok | running:result_err) echo running ;;
    running:exited_clean) echo exited ;;
    *) echo illegal ;;
  esac
}
matrix_triggers="start send resume cancel session_started message tool_call tool_result warning limit_notice rate_limited error_nonfatal error_fatal result_ok result_err unknown exited_clean"
matrix_total=0
for st in none spawning running idle rate_limited exited killed; do
  mism=""
  for tg in $matrix_triggers; do
    matrix_total=$((matrix_total + 1))
    if [ "$st" = none ]; then sj=null; else sj="\"$st\""; fi
    got=$(tr_one "$sj" "$(matrix_event "$tg")")
    want=$(matrix_expect "$st" "$tg")
    [ "$got" = "$want" ] || mism="$mism [$tg: want $want got $got]"
  done
  eq "state machine matrix, state $st: every trigger matches the table" "$mism" ""
done
eq "state machine matrix covered 7 states x 17 triggers" "$matrix_total" "119"
# the named illegal cases of the brief
eq "illegal: a message in idle" "$(tr_one '"idle"' '{"type":"message"}')" "illegal"
eq "illegal: session_started in running" "$(tr_one '"running"' '{"type":"session_started"}')" "illegal"
eq "illegal: an event after a terminal state (killed): all 11 event types" \
  "$(for t in session_started message tool_call tool_result warning limit_notice rate_limited error result exited unknown; do tr_one '"killed"' "{\"type\":\"$t\",\"fatal\":false,\"is_error\":false}"; done | sort -u | paste -sd' ' -)" "illegal"
eq "illegal: an event after a terminal state (exited): all 11 event types" \
  "$(for t in session_started message tool_call tool_result warning limit_notice rate_limited error result exited unknown; do tr_one '"exited"' "{\"type\":\"$t\",\"fatal\":false,\"is_error\":false}"; done | sort -u | paste -sd' ' -)" "illegal"
eq "illegal: message, tool_call, tool_result and result before session_started (spawning)" \
  "$(for t in message tool_call tool_result result; do tr_one '"spawning"' "{\"type\":\"$t\",\"is_error\":false}"; done | sort -u | paste -sd' ' -)" "illegal"
# an illegal transition is reported by the replay and changes neither the state nor the flags
eq "replay reports session_started in running as illegal and stays running" "$(replay_json '[{"type":"session_started","seq":1},{"type":"session_started","seq":2}]')" "running/1"
eq "replay reports a message after an idle end as illegal" \
  "$(replay_json '[{"type":"session_started"},{"type":"result","is_error":false},{"type":"exited","code":0},{"type":"message"}]')" "idle/1"
eq "replay reports any event after cancel (killed) as illegal, the exited event of the killed child included" \
  "$(replay_json '[{"type":"cancel"},{"type":"message"},{"type":"exited","code":137}]')" "killed/2"
eq "replay: a second exited event is illegal" "$(replay_json '[{"type":"session_started"},{"type":"exited","code":1},{"type":"exited","code":1}]')" "exited/1"
eq "replay: message and result in spawning are illegal" "$(replay_json '[{"type":"message"},{"type":"result","is_error":false}]')" "spawning/2"
# the ordinary events of a normal run: no illegal transition
eq "ordinary spawning events (warning, limit_notice, unknown, both errors) stay in spawning" \
  "$(replay_json '[{"type":"warning"},{"type":"limit_notice"},{"type":"unknown"},{"type":"error","fatal":false},{"type":"error","fatal":true}]')" "spawning/0"
eq "decision: error{fatal:true} in spawning stays spawning until the child ends; then it is row 3 (exited)" \
  "$(replay_json '[{"type":"error","fatal":true},{"type":"exited","code":1}]')" "exited/0"
eq "ordinary running events stay in running" \
  "$(replay_json '[{"type":"session_started"},{"type":"message"},{"type":"tool_call"},{"type":"tool_result"},{"type":"warning"},{"type":"limit_notice"},{"type":"error","fatal":false},{"type":"error","fatal":true},{"type":"unknown"}]')" "running/0"
# the exited event and the precedence (rows 3 to 7, 11)
ss='{"type":"session_started"}'
eq "row 3: exited before session_started -> exited" "$(replay_json '[{"type":"exited","code":1}]')" "exited/0"
eq "row 4: success result then exit 0 -> idle" "$(replay_json "[$ss,{\"type\":\"result\",\"is_error\":false},{\"type\":\"exited\",\"code\":0}]")" "idle/0"
eq "row 5: error result then exit 0 -> exited" "$(replay_json "[$ss,{\"type\":\"result\",\"is_error\":true},{\"type\":\"exited\",\"code\":0}]")" "exited/0"
eq "row 5: error result then exit 1 -> exited" "$(replay_json "[$ss,{\"type\":\"result\",\"is_error\":true},{\"type\":\"exited\",\"code\":1}]")" "exited/0"
eq "row 6: no result, exit 0 -> exited" "$(replay_json "[$ss,{\"type\":\"exited\",\"code\":0}]")" "exited/0"
eq "row 6: no result, exit 1 -> exited" "$(replay_json "[$ss,{\"type\":\"exited\",\"code\":1}]")" "exited/0"
eq "row 7: rate_limited then exit with no result -> rate_limited" "$(replay_json "[$ss,{\"type\":\"rate_limited\"},{\"type\":\"exited\",\"code\":1}]")" "rate_limited/0"
eq "row 7: rate_limited then success result then exit 0 -> rate_limited (limit_seen wins)" \
  "$(replay_json "[$ss,{\"type\":\"rate_limited\"},{\"type\":\"result\",\"is_error\":false},{\"type\":\"exited\",\"code\":0}]")" "rate_limited/0"
eq "row 7: rate_limited seen while spawning is not lost" "$(replay_json '[{"type":"rate_limited"},{"type":"exited","code":1}]')" "rate_limited/0"
eq "row 11: success result then exit 1 -> exited" "$(replay_json "[$ss,{\"type\":\"result\",\"is_error\":false},{\"type\":\"exited\",\"code\":1}]")" "exited/0"
eq "row 11: success result then death by a signal -> exited" "$(replay_json "[$ss,{\"type\":\"result\",\"is_error\":false},{\"type\":\"exited\",\"signal\":\"KILL\"}]")" "exited/0"
eq "row 11: success result then an exited event with neither code nor signal -> exited (not a clean exit)" \
  "$(replay_json "[$ss,{\"type\":\"result\",\"is_error\":false},{\"type\":\"exited\"}]")" "exited/0"
eq "several results: the last one counts (error, then success -> idle)" \
  "$(replay_json "[$ss,{\"type\":\"result\",\"is_error\":true},{\"type\":\"result\",\"is_error\":false},{\"type\":\"exited\",\"code\":0}]")" "idle/0"
eq "several results: the last one counts (success, then error -> exited)" \
  "$(replay_json "[$ss,{\"type\":\"result\",\"is_error\":false},{\"type\":\"result\",\"is_error\":true},{\"type\":\"exited\",\"code\":0}]")" "exited/0"
eq "flags: result sets result_seen and is_error; no other event changes them" \
  "$(replay_flags "[$ss,{\"type\":\"message\"},{\"type\":\"result\",\"is_error\":true},{\"type\":\"warning\"}]")" '{"limit_seen":false,"reset_at":null,"result_seen":true,"is_error":true}'
eq "flags: limit_seen keeps the highest reset_at" \
  "$(replay_flags "[$ss,{\"type\":\"rate_limited\",\"reset_at\":5},{\"type\":\"rate_limited\",\"reset_at\":9},{\"type\":\"rate_limited\",\"reset_at\":7},{\"type\":\"rate_limited\"}]")" '{"limit_seen":true,"reset_at":9,"result_seen":false,"is_error":null}'
eq "row 9 (send from idle) starts a new invocation with empty flags" \
  "$(tr_flags '"idle"' '{"type":"send"}' '{"limit_seen":true,"reset_at":9,"result_seen":true,"is_error":false}')" '{"limit_seen":false,"reset_at":null,"result_seen":false,"is_error":null}'
eq "rows 1, 8 and 9 in a row: start, then resume from rate_limited and send from idle" \
  "$(tr_one null '{"type":"start"}')/$(tr_one '"rate_limited"' '{"type":"resume"}')/$(tr_one '"idle"' '{"type":"send"}')" "spawning/idle/spawning"

# replay every fixture's normalized output with an exited event appended, from the state after row 1 (spawning).
# The exit code per fixture: 1 for a fixture that is a failed or limited run (its last result is an error or it hit a limit, so a
# real CLI exits non-zero), 0 for a successful run. For claude-limits and codex-failure the code does not matter: limit_seen
# wins over every other row. For codex-hostile and codex-malformed the last result is an error (row 5), also whatever the code.
replay_code() {
  case "$1" in
    claude-limits | codex-failure | codex-hostile | codex-malformed | codex-prestart-error) echo 1 ;;
    *) echo 0 ;;
  esac
}
# The end state each fixture must reach.
#  claude-sample, claude-routine, claude-hostile, codex-sample, codex-item-warning: one successful result, exit 0, no limit
#    -> row 4, idle. (claude-hostile has an error{fatal:false} in running; that is row 14 and changes nothing.)
#  claude-limits, codex-failure: rate_limited events were seen -> row 7, rate_limited at exit.
#  codex-hostile: its only result is an error (the failed turn) and no rate_limited -> row 5, exited.
#  codex-malformed: results false, false, true, true: the LAST one counts (is_error true) and no rate_limited -> row 5, exited.
#    Its first two lines are unknown events in spawning (row 12) before the real thread.started on line 3.
#  codex-prestart-error: a fatal top-level error before thread.started (the plain message does not match the limit hint, so no
#    rate_limited), then the child exits 1. The error is row 13 (stays in spawning), the exited event is row 3 -> exited.
#  an observed*.jsonl capture: one successful result, exit 0 -> idle.
expected_end() {
  case "$1" in
    claude-sample | claude-routine | claude-hostile | codex-sample | codex-item-warning) echo idle ;;
    claude-limits | codex-failure) echo rate_limited ;;
    codex-hostile | codex-malformed | codex-prestart-error) echo exited ;;
    claude-observed* | codex-observed*) echo idle ;;
    *) echo "NO-EXPECTATION-FOR-$1" ;;
  esac
}
replayed=0
for e in "${entries[@]}"; do
  IFS='|' read -r cli file name <<< "$e"
  code=$(replay_code "$name")
  case "$name" in claude-observed* | codex-observed*) code=0 ;; esac
  normalize "$cli" "$file" --argjson exit_code "$code" > "$TMP/replay-events.jsonl"
  res=$(jq -s -c -f "$TMP/replay.jq" "$TMP/replay-events.jsonl")
  nev=$(wc -l < "$TMP/replay-events.jsonl" | tr -d ' ')
  replayed=$((replayed + 1))
  eq "$name: replay (exit $code) has no illegal transition" "$(printf '%s' "$res" | jq -c '.illegal')" "[]"
  eq "$name: replay (exit $code) ends in $(expected_end "$name")" "$(printf '%s' "$res" | jq -r '.state')" "$(expected_end "$name")"
  check "$name: the replay saw all $nev events, the last one the appended exited event" \
    jq -s -e --argjson n "$nev" 'length == $n and .[-1].type == "exited" and .[-1].code == '"$code" "$TMP/replay-events.jsonl"
done
check "the replay covered at least the 10 committed fixtures" test "$replayed" -ge 10
# row 13 is exercised by a committed fixture, not only by unit tests: removing it must fail a replay
eq "codex-prestart-error: its first event is a fatal error in spawning, no session_started, no rate_limited (row 13, then row 3)" \
  "$(jq -s -c '[.[] | .type + ":" + ((.fatal // "") | tostring)]' "$TMP/out/codex-prestart-error.jsonl")" '["error:true"]'

# ---- round 5, blocker 1: an unknown turn count must not release the reservation (turns_known) ------------------------------
# num_turns missing, a string, negative, null, a boolean, an array or an object: turns_known false and turns 0
tk_n=0
for nt in '' ',"num_turns":"5"' ',"num_turns":-1' ',"num_turns":null' ',"num_turns":true' ',"num_turns":[3]' ',"num_turns":{"n":3}' ',"num_turns":"3.0"'; do
  tk_n=$((tk_n + 1))
  printf '{"type":"result","subtype":"success","is_error":false%s,"usage":{"input_tokens":1,"output_tokens":1}}\n' "$nt" > "$TMP/tk.jsonl"
  normalize claude "$TMP/tk.jsonl" > "$TMP/o.jsonl"
  eq "turns_known case $tk_n (num_turns ${nt:-missing}): turns_known false and turns 0" \
    "$(jq -s -c '[.[0].turns_known, .[0].turns]' "$TMP/o.jsonl")" "[false,0]"
  eq "turns_known case $tk_n (num_turns ${nt:-missing}): the result validates" "$(validate "$TMP/o.jsonl")" "0"
done
eq "turns_known: 8 unknown-count cases" "$tk_n" "8"
for nt in 0 1 3 5 41 2.5; do
  printf '{"type":"result","subtype":"success","is_error":false,"num_turns":%s}\n' "$nt" > "$TMP/tk.jsonl"
  normalize claude "$TMP/tk.jsonl" > "$TMP/o.jsonl"
  eq "turns_known: a numeric num_turns $nt gives turns_known true" "$(jq -s -r '.[0].turns_known' "$TMP/o.jsonl")" "true"
  eq "turns_known: num_turns $nt gives turns $(jq -n --argjson n "$nt" '$n | ceil') (rounded up, never down)" "$(jq -s -r '.[0].turns' "$TMP/o.jsonl")" "$(jq -n --argjson n "$nt" '$n | ceil')"
done
# an error result with an unknown count (a failed run) is still turns_known false
printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true}' > "$TMP/tk.jsonl"
normalize claude "$TMP/tk.jsonl" > "$TMP/o.jsonl"
eq "turns_known: an error result without num_turns is turns_known false" "$(jq -s -c '[.[0].is_error, .[0].turns_known]' "$TMP/o.jsonl")" "[true,false]"
# Codex: turns_known is always true, for turn.completed and turn.failed, even with odd usage
printf '%s\n' '{"type":"turn.completed"}' '{"type":"turn.completed","usage":[1]}' '{"type":"turn.failed"}' '{"type":"turn.failed","error":5}' > "$TMP/tk.jsonl"
normalize codex "$TMP/tk.jsonl" > "$TMP/o.jsonl"
eq "turns_known: every Codex result has turns_known true and turns 1" "$(jq -s -c '[.[] | select(.type == "result") | [.turns_known, .turns]] | unique' "$TMP/o.jsonl")" "[[true,1]]"
check "schema: turns_known is a required boolean on result" \
  jq -e '."$defs".result.allOf[1] | (.required | index("turns_known") != null) and (.properties.turns_known.type == "boolean")' "$SCHEMA"
check "schema: tool_call id and name and tool_result id have minLength 1; error and warning kind too" \
  jq -e '."$defs" as $d | ($d.tool_call.allOf[1].properties.id.minLength == 1) and ($d.tool_call.allOf[1].properties.name.minLength == 1) and ($d.tool_result.allOf[1].properties.id.minLength == 1) and ($d.error.allOf[1].properties.kind.minLength == 1) and ($d.warning.allOf[1].properties.kind.minLength == 1)' "$SCHEMA"
eq "validator: an event with turns_known missing fails the schema" \
  "$(printf '%s\n' '{"type":"result","provider":"claude","seq":1,"ts":null,"raw":"x","is_error":false,"turns":2,"tokens":{"input":1,"output":1,"cache_read":0,"cache_write":0,"reasoning":0},"tokens_known":true,"cost_usd":null,"cost_is_estimate":true}' > "$TMP/notk.jsonl"; validate "$TMP/notk.jsonl")" "1"
eq "validator: a tool_call with an empty id fails the schema" \
  "$(printf '%s\n' '{"type":"tool_call","provider":"claude","seq":1,"ts":null,"raw":"x","id":"","name":"X"}' > "$TMP/emptyid.jsonl"; validate "$TMP/emptyid.jsonl")" "1"

# ---- round 5, reviewer item 4: an empty error string keeps a non-empty kind -------------------------------------------------
printf '%s\n' '{"type":"assistant","error":"","message":{"content":[]}}' '{"type":"assistant","error":"\u0001"}' '{"type":"assistant","error":"billing_error"}' > "$TMP/emptyerr.jsonl"
normalize claude "$TMP/emptyerr.jsonl" > "$TMP/o.jsonl"
eq "an empty assistant error string: error kind unknown_error, fatal false, empty message; a control-only string stays a cleaned kind" \
  "$(jq -s -c '[.[] | select(.type == "error") | [.kind, .fatal, .message]]' "$TMP/o.jsonl")" '[["unknown_error",false,""],[" ",false," "],["billing_error",false,"billing_error"]]'
eq "those error events validate (kind minLength 1, empty message allowed)" "$(validate "$TMP/o.jsonl")" "0"
printf '%s\n' '{"type":"error"}' '{"type":"error","message":""}' '{"type":"turn.failed"}' > "$TMP/emptymsg.jsonl"
normalize codex "$TMP/emptymsg.jsonl" > "$TMP/o.jsonl"
eq "a Codex fatal error without message text stays an error with an empty message (never unknown)" \
  "$(jq -s -c '[.[] | select(.type == "error") | [.kind, .fatal, .message]]' "$TMP/o.jsonl")" '[["stream_error",true,""],["stream_error",true,""],["turn_failed",true,""]]'
eq "and validates" "$(validate "$TMP/o.jsonl")" "0"

# ---- round 5, reviewer item 2: the reference matches the spec on cancel() and on dropping the flags ----------------------------
eq "cancel() with no state is illegal (the spec says legal in every state that exists)" "$(tr_one null '{"type":"cancel"}')" "illegal"
eq "cancel() in every existing state is legal" \
  "$(for st in spawning running idle rate_limited exited killed; do tr_one "\"$st\"" '{"type":"cancel"}'; done | paste -sd' ' -)" "killed killed killed killed exited killed"
full_flags='{"limit_seen":true,"reset_at":9,"result_seen":true,"is_error":false}'
empty_flags='{"limit_seen":false,"reset_at":null,"result_seen":false,"is_error":null}'
eq "flags are dropped at the exited event: rate_limited end (row 7)" "$(tr_flags '"running"' '{"type":"exited","code":0}' "$full_flags")" "$empty_flags"
eq "flags are dropped at the exited event: idle end (row 4)" "$(tr_flags '"running"' '{"type":"exited","code":0}' '{"limit_seen":false,"reset_at":null,"result_seen":true,"is_error":false}')" "$empty_flags"
eq "flags are dropped at the exited event: exited end (rows 5, 6, 11)" "$(tr_flags '"running"' '{"type":"exited","code":1}' '{"limit_seen":false,"reset_at":null,"result_seen":true,"is_error":true}')" "$empty_flags"
eq "flags are dropped at the exited event in spawning (rows 3 and 7)" "$(tr_flags '"spawning"' '{"type":"exited","code":1}' "$full_flags")" "$empty_flags"
eq "flags are dropped at cancel() of a live invocation (row 10)" "$(tr_flags '"running"' '{"type":"cancel"}' "$full_flags")" "$empty_flags"
eq "a whole limited invocation leaves empty flags behind" \
  "$(replay_flags "[$ss,{\"type\":\"rate_limited\",\"reset_at\":9},{\"type\":\"result\",\"is_error\":true},{\"type\":\"exited\",\"code\":1}]")" "$empty_flags"

# ---- no live provider use ------------------------------------------------------------------------------------------------
check "this test never sets SPIKE_LIVE" test "$(grep -cE '^[[:space:]]*(export[[:space:]]+)?SPIKE_LIVE=' "$HERE/test_normalize.sh")" = "0"
check "the normalizers mention no provider CLI invocation" test "$(grep -vE '^[[:space:]]*#' "$NORM/claude.jq" "$NORM/codex.jq" | grep -cE 'claude -p|codex exec|SPIKE_LIVE')" = "0"
check "fixtures hold no at-sign and no home-directory path" test "$(cat "$FIXN"/*.jsonl "$EXPECTED"/*.jsonl | grep -cE '@|/Users/|/home/')" = "0"

echo "test_normalize: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
