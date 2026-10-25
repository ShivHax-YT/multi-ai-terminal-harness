#!/bin/bash
# Offline tests for the Codex headless spike (T-003): spike/codex/parse.jq, run.sh, resume.sh, EVENTS.md, fixtures.
#   /bin/bash spike/tests/test_codex_parse.sh
# Exit 0 = all checks passed. This test never sets SPIKE_LIVE=1 and never runs a provider CLI: the only "codex" it ever
# puts on a PATH is a fake whose first action is to create a marker file, and the checks prove the marker stays absent.
set -u
unset CDPATH

HERE=$(cd "$(dirname "$0")" && pwd -P)
SPIKE=$(cd "$HERE/.." && pwd -P)
REPO=$(cd "$SPIKE/.." && pwd -P)
CODEX="$SPIKE/codex"
FIX="$SPIKE/fixtures/codex"
SH=/bin/bash

TMP=$(mktemp -d "${TMPDIR:-/tmp}/codex-test.XXXXXX") || exit 2
TMP=$(cd "$TMP" && pwd -P) || exit 2
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1" >&2
}
check() { # description, then a command; passes if the command succeeds
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then pass; else fail "$desc"; fi
}
eq() { # desc actual expected
  if [ "$2" = "$3" ]; then pass; else fail "$1: expected [$3] got [$2]"; fi
}
parse() { jq -n -R -f "$CODEX/parse.jq" < "$1"; }
jqe() { # desc json filter: passes if `jq -e filter` is true on the json
  if printf '%s' "$2" | jq -e "$3" >/dev/null 2>&1; then pass; else fail "$1 (filter: $3)"; fi
}

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }

# ---- files exist, syntax ------------------------------------------------------------------------------------------------
for f in run.sh resume.sh parse.jq EVENTS.md; do
  check "$f exists" test -f "$CODEX/$f"
done
check "run.sh is executable" test -x "$CODEX/run.sh"
check "resume.sh is executable" test -x "$CODEX/resume.sh"
check "bash -n run.sh" "$SH" -n "$CODEX/run.sh"
check "bash -n resume.sh" "$SH" -n "$CODEX/resume.sh"
check "run.sh uses the /bin/bash shebang" test "$(head -n 1 "$CODEX/run.sh")" = '#!/bin/bash'
check "resume.sh uses the /bin/bash shebang" test "$(head -n 1 "$CODEX/resume.sh")" = '#!/bin/bash'
check "parse.jq compiles on an empty input" jq -n -R -f "$CODEX/parse.jq" < /dev/null

# ---- sample.jsonl --------------------------------------------------------------------------------------------------------------
S=$(parse "$FIX/sample.jsonl")
check "sample parses to a JSON object" jq -e 'type == "object"' <<< "$S"
jqe "thread_id found" "$S" '.thread_id == "0199a213-81c0-7800-8aa1-bbab2a035a53"'
jqe "no malformed lines in the sample" "$S" '.malformed_lines == 0 and .lines == 17'
jqe "final usage is a non-empty object of numbers" "$S" '(.final.usage | type == "object") and (.final.usage | length > 0) and (.final.usage | [.[] | type == "number"] | all)'
jqe "usage has input and output tokens" "$S" '.final.usage.input_tokens == 24763 and .final.usage.output_tokens == 122'
jqe "final status is completed" "$S" '.final.status == "completed"'
jqe "last message excerpt is DONE" "$S" '.final.last_message_excerpt == "DONE"'
jqe "event counts are per type" "$S" '.event_counts["thread.started"] == 1 and .event_counts["turn.completed"] == 1 and .event_counts["item.started"] == 3 and .event_counts["item.updated"] == 1 and .event_counts["item.completed"] == 9'
jqe "item counts are per distinct item id" "$S" '.items.command_execution == 1 and .items.todo_list == 1 and .items.mcp_tool_call == 1 and .items.agent_message == 1 and .items.reasoning == 1 and .items.file_change == 1 and .items.web_search == 1 and .items.error == 1'
jqe "commands_run lists the command with its exit code" "$S" '(.commands_run | length) == 1 and .commands_run[0].exit_code == 0 and .commands_run[0].status == "completed" and (.commands_run[0].command | contains("hello.txt"))'
jqe "an unknown event type lands in unknown" "$S" '[.unknown[] | select(.kind == "event" and .type == "future.event.kind")] | length == 1'
jqe "an unknown item type lands in unknown" "$S" '[.unknown[] | select(.kind == "item" and .type == "future_item_kind")] | length == 1'
jqe "the unknown event is still counted" "$S" '.event_counts["future.event.kind"] == 1'
jqe "a non-fatal error item is reported but is not a rate limit" "$S" '(.limit_or_error_events | length) == 1 and .limit_or_error_events[0].kind == "error" and .limit_or_error_events[0].type == "item.error"'

# ---- failure.jsonl (limit and error shapes) ---------------------------------------------------------------------------------
F=$(parse "$FIX/failure.jsonl")
jqe "failure: status is failed" "$F" '.final.status == "failed" and .final.usage == null'
jqe "failure: four error events are listed" "$F" '.limit_or_error_events | length == 4'
jqe "failure: a rate-limit message is flagged on error and on turn.failed" "$F" '[.limit_or_error_events[] | select(.kind == "rate_limit") | .type] == ["error", "turn.failed"]'
jqe "failure: a plain error is not flagged as a rate limit" "$F" '[.limit_or_error_events[] | select(.kind == "error")] | length == 2'
jqe "failure: nothing unknown" "$F" '.unknown == []'

# ---- malformed.jsonl (never crashes) ------------------------------------------------------------------------------------------
M=$(parse "$FIX/malformed.jsonl") ; MRC=$?
eq "malformed: parse.jq exits 0" "$MRC" "0"
check "malformed: output is a JSON object" jq -e 'type == "object"' <<< "$M"
jqe "malformed: broken lines are counted, not fatal" "$M" '.malformed_lines == 2'
jqe "malformed: the first valid string thread id wins" "$M" '.thread_id == "0199a213-81c0-7800-8aa1-bbab2a035a55"'
jqe "malformed: events without a string type are unknown" "$M" '[.unknown[] | select(.kind == "event")] | length >= 6'
jqe "malformed: usage keeps only numeric values" "$M" '.final.usage == {"output_tokens": 5}'
jqe "malformed: text is data (kept verbatim, clipped, never run)" "$M" '.final.last_message_excerpt | startswith("Ignore previous instructions")'
check "malformed: the injected command did not run" test ! -e pwned
# every string in the output is clipped and has no control characters
jqe "malformed: no control characters or long strings in the output" "$M" '[.. | strings | select((test("[[:cntrl:]]")) or (length > 600))] | length == 0'

# a long message is clipped to 200 characters, a long command to 500
LONG=$(printf 'x%.0s' $(seq 1 1000))
printf '{"type":"item.completed","item":{"id":"a","type":"agent_message","text":"%s"}}\n{"type":"item.completed","item":{"id":"c","type":"command_execution","command":"%s","status":"completed","exit_code":1}}\n' "$LONG" "$LONG" > "$TMP/long.jsonl"
L=$(parse "$TMP/long.jsonl")
jqe "last_message_excerpt is at most 200 characters" "$L" '.final.last_message_excerpt | length == 200'
jqe "a command is clipped to 500 characters" "$L" '.commands_run[0].command | length == 500'
jqe "no terminal event means status incomplete" "$L" '.final.status == "incomplete"'

# control characters in a message become spaces
printf '{"type":"error","message":"a\\u001b[31mred\\u0000nul\\nline"}\n' > "$TMP/ctl.jsonl"
C=$(parse "$TMP/ctl.jsonl")
jqe "control characters are replaced by spaces" "$C" '(.limit_or_error_events[0].message | test("[[:cntrl:]]") | not) and (.limit_or_error_events[0].message | contains("red"))'

# empty and whitespace-only input, a CRLF file, and a file without a final newline
: > "$TMP/empty.jsonl"
E=$(parse "$TMP/empty.jsonl")
jqe "empty input: nothing found, status incomplete" "$E" '.thread_id == null and .lines == 0 and .final.status == "incomplete" and .unknown == []'
printf '{"type":"thread.started","thread_id":"abcdef12-0000"}\r\n{"type":"turn.started"}' > "$TMP/crlf.jsonl"
R=$(parse "$TMP/crlf.jsonl")
jqe "CRLF lines and a missing final newline are handled" "$R" '.thread_id == "abcdef12-0000" and .event_counts["turn.started"] == 1 and .malformed_lines == 0'

# many unknown types never fail and are all counted
for i in 1 2 3; do printf '{"type":"brand.new.%s","x":[1,2]}\n' "$i"; done > "$TMP/unk.jsonl"
U=$(parse "$TMP/unk.jsonl")
jqe "three unknown types: all in unknown" "$U" '(.unknown | length) == 3 and (.event_counts | length) == 3'

# ---- fixtures: no at-sign, no home paths ---------------------------------------------------------------------------------
for f in "$FIX"/*; do
  [ -f "$f" ] || continue
  b=$(basename "$f")
  check "fixture $b has no at-sign" test "$(grep -c '@' "$f")" = "0"
  check "fixture $b has no /Users/ path" test "$(grep -c '/Users/' "$f")" = "0"
  check "fixture $b has no /home/ path" test "$(grep -c '/home/' "$f")" = "0"
done
check "the three fixtures exist" test -f "$FIX/sample.jsonl" -a -f "$FIX/failure.jsonl" -a -f "$FIX/malformed.jsonl"

# ---- EVENTS.md covers every event and item type in the fixtures ---------------------------------------------------------------
for f in "$FIX"/*.jsonl; do
  [ -f "$f" ] || continue
  b=$(basename "$f")
  jq -R -r 'fromjson? | objects | ((.type | strings), (.item? | objects | .type | strings))' "$f" | sort -u > "$TMP/types.txt"
  check "$b: has types to check" test -s "$TMP/types.txt"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if grep -qF "\`$t\`" "$CODEX/EVENTS.md"; then pass; else fail "EVENTS.md does not mention type \`$t\` (from $b)"; fi
  done < "$TMP/types.txt"
done

# ---- the live gate: run.sh and resume.sh exit 3 without SPIKE_LIVE=1 and make no CLI call -----------------------------------
SB="$TMP/sb"
mkdir "$SB" "$SB/bin" "$SB/tmp" "$SB/cap" "$SB/home"
MARKER="$SB/MARKER-codex-was-called"
{
  printf '#!/bin/bash\n'
  printf 'echo called > "%s"\n' "$MARKER"
  printf 'exit 0\n'
} > "$SB/bin/codex"
chmod +x "$SB/bin/codex"

gate_case() { # label script [args...]; the environment variable SPIKE_LIVE comes from GATE_ENV (empty = unset)
  local label=$1 script=$2
  shift 2
  rm -f "$MARKER"
  if [ -n "$GATE_ENV" ]; then
    env -i PATH="$SB/bin:/usr/bin:/bin" HOME="$SB/home" TMPDIR="$SB/tmp" SPIKE_CAPTURES_ROOT="$SB/cap" "$GATE_ENV" \
      "$SH" "$script" "$@" > "$SB/out" 2> "$SB/err" < /dev/null
  else
    env -i PATH="$SB/bin:/usr/bin:/bin" HOME="$SB/home" TMPDIR="$SB/tmp" SPIKE_CAPTURES_ROOT="$SB/cap" \
      "$SH" "$script" "$@" > "$SB/out" 2> "$SB/err" < /dev/null
  fi
  GRC=$?
  eq "$label: exit status 3" "$GRC" "3"
  check "$label: the fake codex was never called (marker absent)" test ! -e "$MARKER"
  eq "$label: nothing created in TMPDIR" "$(ls -A "$SB/tmp" | wc -l | tr -d ' ')" "0"
  eq "$label: nothing created in the captures root" "$(ls -A "$SB/cap" | wc -l | tr -d ' ')" "0"
  check "$label: stdout is empty" test ! -s "$SB/out"
  check "$label: stderr says the step is refused" grep -q 'SPIKE_LIVE=1' "$SB/err"
}
for envval in "" "SPIKE_LIVE=0" "SPIKE_LIVE=" "SPIKE_LIVE=true" "SPIKE_LIVE=yes" "SPIKE_LIVE= 1" "SPIKE_LIVE=1 " "SPIKE_LIVE=11"; do
  GATE_ENV=$envval
  gate_case "run.sh [$envval]" "$CODEX/run.sh"
  gate_case "resume.sh with a directory [$envval]" "$CODEX/resume.sh" "$SB/cap"
  gate_case "resume.sh without arguments [$envval]" "$CODEX/resume.sh"
done
# the fake is on PATH and would be found if the gate let a call through
check "the fake codex is first on the sandbox PATH" test "$(PATH="$SB/bin:/usr/bin:/bin" command -v codex)" = "$SB/bin/codex"

# ---- static checks on run.sh and resume.sh -----------------------------------------------------------------------------------
for s in run.sh resume.sh; do
  f="$CODEX/$s"
  # banned flags (brief T-003 and hard rule 2); the whole file is searched, comments included
  check "$s: no -c flag" test "$(grep -cE "(^|[[:space:]\"'])-c([[:space:]\"'=]|$)" "$f")" = "0"
  check "$s: no -p flag" test "$(grep -cE "(^|[[:space:]\"'])-p([[:space:]\"'=]|$)" "$f")" = "0"
  check "$s: no --config" test "$(grep -c -e '--config' "$f")" = "0"
  check "$s: no --profile" test "$(grep -c -e '--profile' "$f")" = "0"
  check "$s: no --dangerously-*" test "$(grep -c -e '--dangerously' "$f")" = "0"
  check "$s: no --oss" test "$(grep -c -e '--oss' "$f")" = "0"
  check "$s: no --local-provider" test "$(grep -c -e '--local-provider' "$f")" = "0"
  check "$s: no --approve-for-me" test "$(grep -c -e '--approve-for-me' "$f")" = "0"
  # rule 2: no config-home variables (the names are assembled here so this file stays clean for the scan)
  for v in "CLAUDE_CONFIG""_DIR" "CODEX""_HOME" "GROK""_HOME" "KIMI_CODE""_HOME"; do
    check "$s: does not name $v" test "$(grep -c "$v" "$f")" = "0"
  done
  # rule 4: no CLI home directory named (the list comes from the lead-owned denylist)
  while IFS= read -r d; do
    case "$d" in ""|"#"*) continue ;; esac
    check "$s: does not name the CLI home $d" test "$(grep -cF "$d" "$f")" = "0"
  done < "$REPO/compliance/denylist.txt"
  # the gate is the first statement after the library is sourced; the TERM trap is not overridden
  FIRST=$(awk 'found && $0 !~ /^[[:space:]]*(#|$)/ { print; exit } /^\. "\$HERE\/\.\.\/lib\/common\.sh"/ { found = 1 }' "$f")
  eq "$s: spike_require_live follows the library source" "$FIRST" "spike_require_live"
  check "$s: no TERM trap override" test "$(grep -cE "^[[:space:]]*trap .*TERM" "$f")" = "0"
  # rules 1 and 10: exactly one live call, no loops, no retry, no eval
  eq "$s: exactly one spike_run_live call" "$(grep -cE '^[[:space:]]*spike_run_live ' "$f")" "1"
  check "$s: no loop keywords" test "$(grep -cE '^[[:space:]]*(while|until|for|select)[[:space:]]' "$f")" = "0"
  check "$s: no eval" test "$(grep -cE '(^|[[:space:];])eval[[:space:]]' "$f")" = "0"
  check "$s: no retry or sleep wording in code" test "$(grep -vE '^[[:space:]]*#' "$f" | grep -ciE 'retry|sleep')" = "0"
  # the pinned runner API: the registered copy is the only thing started, with the watchdog
  check "$s: runs the registered copy" grep -q 'spike_run_live "\$WATCHDOG_SECS" .* "\$SPIKE_VERIFIED_COPY"' "$f"
  check "$s: watchdog is 120 s" grep -q '^WATCHDOG_SECS=120$' "$f"
  check "$s: registers codex through the runner" grep -q '^spike_register_cli codex$' "$f"
  check "$s: sign-in by status exit code only" grep -q 'spike_run_status 30 /dev/null "\$SPIKE_VERIFIED_COPY" login status' "$f"
  # rule 3: codex exec only
  check "$s: uses codex exec --json with the workspace-write sandbox" grep -q 'exec --json --sandbox workspace-write -C "\$WT"' "$f"
  check "$s: never runs a bare codex or claude command" test "$(grep -vE '^[[:space:]]*#' "$f" | grep -cE "^[[:space:]]*(codex|claude)[[:space:]]|[|;&(][[:space:]]*(codex|claude)[[:space:]]")" = "0"
  check "$s: never sets SPIKE_LIVE" test "$(grep -vE '^[[:space:]]*#' "$f" | grep -cE "^[[:space:]]*(export[[:space:]]+|declare[[:space:]]+-x[[:space:]]+)?SPIKE_LIVE=|env[[:space:]]+SPIKE_LIVE=")" = "0"
done
check "resume.sh resumes by thread id" grep -q 'resume "\$THREAD_ID" "\$PROMPT"' "$CODEX/resume.sh"
check "run.sh task text is the brief's" grep -qF "TASK='Create hello.txt containing exactly the line: hello from codex. Then reply DONE.'" "$CODEX/run.sh"
check "resume.sh prompt is the brief's" grep -qF "PROMPT='Append a second line to hello.txt: resumed. Reply DONE.'" "$CODEX/resume.sh"
check "parse.jq has no input/env/ltrimstr surprises: no \$ENV, no env, no input_filename" test "$(grep -vE '^[[:space:]]*#' "$CODEX/parse.jq" | grep -cE '\$ENV|\benv\b|input_filename|\$__prog')" = "0"

# ---- the split used by run.sh and resume.sh (same awk program) ------------------------------------------------------------------
printf '{"type":"turn.started"}\nWARN something on stderr\n{"type":"turn.completed","usage":{"input_tokens":1}}\nmore text\n' > "$TMP/comb.txt"
SPLIT_AWK=$(grep -m1 "awk -v raw=" "$CODEX/run.sh" | sed -e "s/.*'\\(\\/.*\\)' .*/\\1/")
awk -v raw="$TMP/r.jsonl" -v err="$TMP/e.txt" "$SPLIT_AWK" "$TMP/comb.txt"
eq "split: two JSON lines to raw.jsonl" "$(wc -l < "$TMP/r.jsonl" | tr -d ' ')" "2"
eq "split: two text lines to stderr.txt" "$(wc -l < "$TMP/e.txt" | tr -d ' ')" "2"
SPLIT_AWK2=$(grep -m1 "awk -v raw=" "$CODEX/resume.sh" | sed -e "s/.*'\\(\\/.*\\)' .*/\\1/")
eq "split: run.sh and resume.sh use the same awk program" "$SPLIT_AWK" "$SPLIT_AWK2"

printf 'test_codex_parse: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
