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
  '{"type":"result","provider":"codex","seq":1,"ts":null,"raw":"x","is_error":false,"turns":1,"tokens":{"input":1,"output":1,"cache_read":1,"cache_write":1},"tokens_known":true,"cost_usd":null,"cost_is_estimate":true}' \
  '{"type":"result","provider":"codex","seq":1,"ts":null,"raw":"x","is_error":false,"turns":1,"tokens":{"input":1,"output":1,"cache_read":1,"cache_write":1,"reasoning":0},"tokens_known":true,"cost_usd":null,"cost_is_estimate":false}' \
  '{"type":"bogus","provider":"codex","seq":1,"ts":null,"raw":"x"}' \
  > "$TMP/badevents.jsonl"
bad=$(jq -s --slurpfile sch "$SCHEMA" -f "$TMP/validate.jq" "$TMP/badevents.jsonl" | jq 'length')
eq "validator self-test: 1 good event, 6 bad events caught" "$bad" "6"
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

# raw keys of a fixture, derived independently of the normalizers (well-formed lines only)
claude_rawkeys='
  def blocks: (.message.content? // null) | if type == "string" then [{type: "text"}] elif type == "array" then . else [] end;
  [ inputs | (try fromjson catch null) | select(type == "object" and (.type | type) == "string")
    | . as $o
    | (if ($o.type == "system" or $o.type == "result") and ($o.subtype | type) == "string" then "\($o.type)/\($o.subtype)" else $o.type end),
      (if $o.type == "assistant" and ($o.error | type) == "string" then "assistant" else empty end),
      (if $o.type == "assistant" or $o.type == "user" then ($o | blocks[] | select(type == "object" and (.type | type) == "string") | "\($o.type):\(.type)") else empty end)
  ] | unique | .[]'
codex_rawkeys='
  [ inputs | (try fromjson catch null) | select(type == "object" and (.type | type) == "string")
    | if .type == "item.updated" then "item.updated"
      elif (.type == "item.started" or .type == "item.completed") then (if (.item | type) == "object" and (.item.type | type) == "string" then "\(.type):\(.item.type)" else empty end)
      else .type end
  ] | unique | .[]'
key_listed() { # cli key : 0 if the key is mapped (a trailing /* is a wildcard) or ignored
  local cli=$1 key=$2
  jq -n -e --arg dump keys --arg k "$key" -f "$NORM/$cli.jq" < /dev/null \
    | jq -e --arg k "$key" '(.mapped_keys + .ignored_keys) | any(. == $k or (endswith("/*") and ($k | startswith(.[0:-1]))))' > /dev/null
}

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
  if [ "$name" != "codex-malformed" ]; then
    eq "$name: session_started appears once" "$(count "$out" '.type == "session_started"')" "1"
    check "$name: session_started is the first event" jq -s -e '.[0].type == "session_started"' "$out"
  fi
  # every tool_result has an earlier tool_call with the same id
  check "$name: every tool_result id has an earlier tool_call" \
    jq -s -e '. as $all | all(range(0; length); . as $i | $all[$i] | if .type == "tool_result" then (.id as $id | [$all[0:$i][] | select(.type == "tool_call" and .id == $id)] | length > 0) else true end)' "$out"
  # every result has numeric turns and five numeric token fields
  check "$name: every result has numeric tokens" \
    jq -s -e 'all(.[] | select(.type == "result"); (.turns | type == "number") and (.tokens | [.input, .output, .cache_read, .cache_write, .reasoning] | all(type == "number")) and (.tokens_known | type == "boolean") and .cost_is_estimate == true)' "$out"
  # tokens_known is false only for turn.failed (Codex), whatever fixture; the broken-line fixture has odd usage shapes
  if [ "$name" != "codex-malformed" ]; then
    check "$name: tokens_known is false only for turn.failed" \
      jq -s -e 'all(.[] | select(.type == "result" and .tokens_known == false); .raw == "turn.failed")' "$out"
  fi

  # every raw key is mapped, ignored, or yields unknown (derived independently of the normalizer)
  if [ "$cli" = claude ]; then keysprog=$claude_rawkeys; else keysprog=$codex_rawkeys; fi
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    case "$key" in *[!\ -~]*) continue ;; esac # hostile keys with control characters are covered by the hostile tests
    [ "${#key}" -le 64 ] || continue
    if key_listed "$cli" "$key"; then
      pass
    elif jq -s -e --arg k "$key" 'any(.[]; .type == "unknown" and .raw_type == $k)' "$out" > /dev/null; then
      pass
    else
      fail "$name: raw key '$key' is neither mapped, ignored, nor yields unknown"
    fi
  done < <(jq -n -r -R "$keysprog" < "$file")

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
    check "$name (observed): no secrets-looking or at-sign data in the capture" test "$(grep -c '@' "$file")" = "0"
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
printf '%s\n' '{"type":"system","subtype":"init"}' '{"type":"assistant","message":{"content":[{"type":"server_tool_use"},{"type":"tool_use","id":"t1","name":"X"},"str",null,7]}}' \
  '{"type":"user","message":{"content":[{"type":"image"},{"type":"text","text":"x"},{"type":"tool_result","tool_use_id":"t1","is_error":true}]}}' > "$TMP/odd.jsonl"
normalize claude "$TMP/odd.jsonl" > "$TMP/o.jsonl"
eq "claude odd shapes: init without id, unknown block types, invalid blocks" \
  "$(jq -s -c '[.[] | [.type, .raw_type // .name // ""]]' "$TMP/o.jsonl")" \
  '[["unknown","system/init"],["unknown","assistant:server_tool_use"],["tool_call","X"],["unknown","assistant:invalid_block"],["unknown","assistant:invalid_block"],["unknown","assistant:invalid_block"],["unknown","user:image"],["tool_result",""]]'

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
eq "claude weird input: garbage makes no error event, only the one unknown-status rate_limited" "$(count "$TMP/o.jsonl" '.type == "error"')/$(count "$TMP/o.jsonl" '.type == "rate_limited"')" "0/1"
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

# ---- no live provider use ------------------------------------------------------------------------------------------------
check "this test never sets SPIKE_LIVE" test "$(grep -cE '^[[:space:]]*(export[[:space:]]+)?SPIKE_LIVE=' "$HERE/test_normalize.sh")" = "0"
check "the normalizers mention no provider CLI invocation" test "$(grep -vE '^[[:space:]]*#' "$NORM/claude.jq" "$NORM/codex.jq" | grep -cE 'claude -p|codex exec|SPIKE_LIVE')" = "0"
check "fixtures hold no at-sign and no home-directory path" test "$(cat "$FIXN"/*.jsonl "$EXPECTED"/*.jsonl | grep -cE '@|/Users/|/home/')" = "0"

echo "test_normalize: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
