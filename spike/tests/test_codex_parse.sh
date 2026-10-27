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

# rate-limit heuristic: a 5xx retry-exhaustion text and "try again later" are ordinary errors; real limit wording is flagged
printf '%s\n' \
  '{"type":"error","message":"exceeded retry limit, last status: 503 Service Unavailable"}' \
  '{"type":"error","message":"stream disconnected before completion, please try again later"}' \
  '{"type":"turn.failed","error":{"message":"request failed after 5 attempts, try again in a few minutes (status 502)"}}' \
  '{"type":"error","message":"You have hit your usage limit. Upgrade to Pro or try again later."}' \
  '{"type":"error","message":"Rate limit reached for requests"}' \
  '{"type":"turn.failed","error":{"message":"unexpected status 429 Too Many Requests"}}' \
  '{"type":"error","message":"insufficient_quota"}' > "$TMP/heur.jsonl"
H=$(parse "$TMP/heur.jsonl")
jqe "heuristic: 5xx retry-exhaustion and try-again texts are plain errors" "$H" '[.limit_or_error_events[0,1,2].kind] == ["error","error","error"]'
jqe "heuristic: real limit wording is flagged as rate_limit" "$H" '[.limit_or_error_events[3,4,5,6].kind] == ["rate_limit","rate_limit","rate_limit","rate_limit"]'
jqe "heuristic: every carrier is listed once" "$H" '.limit_or_error_events | length == 7'

# limit_or_error_events is built from de-duplicated items: one error item seen in several events is one entry
printf '%s\n' \
  '{"type":"item.started","item":{"id":"e1","type":"error","message":"rate limit hit"}}' \
  '{"type":"item.updated","item":{"id":"e1","type":"error","message":"rate limit hit"}}' \
  '{"type":"item.completed","item":{"id":"e1","type":"error","message":"rate limit hit"}}' \
  '{"type":"error","message":"plain failure"}' \
  '{"type":"item.completed","item":{"id":"e2","type":"error","message":"second warning"}}' \
  '{"type":"item.completed","item":{"id":"e2","type":"error","message":"second warning"}}' > "$TMP/dedup.jsonl"
D=$(parse "$TMP/dedup.jsonl")
jqe "dedup: three events of one error item give one entry" "$D" '[.limit_or_error_events[] | select(.type == "item.error" and .message == "rate limit hit")] | length == 1'
jqe "dedup: two error items and one error event give three entries in stream order" "$D" '[.limit_or_error_events[] | .message] == ["rate limit hit","plain failure","second warning"]'
jqe "dedup: the item count agrees" "$D" '.items.error == 2'

# ---- malformed.jsonl (never crashes) ------------------------------------------------------------------------------------------
# run the parser from an empty scratch directory, so a payload that was executed (the fixture holds "$(touch pwned)") would
# create its marker exactly there
mkdir "$TMP/pwdir"
M=$(cd "$TMP/pwdir" && parse "$FIX/malformed.jsonl") ; MRC=$?
eq "malformed: parse.jq exits 0" "$MRC" "0"
check "malformed: output is a JSON object" jq -e 'type == "object"' <<< "$M"
jqe "malformed: broken lines are counted, not fatal" "$M" '.malformed_lines == 2'
jqe "malformed: the first valid string thread id wins" "$M" '.thread_id == "0199a213-81c0-7800-8aa1-bbab2a035a55"'
jqe "malformed: events without a string type are unknown" "$M" '[.unknown[] | select(.kind == "event")] | length >= 6'
jqe "malformed: usage keeps only numeric values" "$M" '.final.usage == {"output_tokens": 5}'
jqe "malformed: text is data (kept verbatim, clipped, never run)" "$M" '.final.last_message_excerpt | startswith("Ignore previous instructions")'
check "malformed: the injected command did not run (marker absent where it would land)" test ! -e "$TMP/pwdir/pwned"
eq "malformed: the parser created nothing in its working directory" "$(ls -A "$TMP/pwdir" | wc -l | tr -d ' ')" "0"
check "malformed: no marker in the temp root either" test ! -e "$TMP/pwned"
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
# The allow-list: the exact spike_run_live_split line (watchdog, capture file, registered copy, then the codex arguments).
# `-C` and `--sandbox` are options of `codex exec` only (verified with --help, codex-cli 0.162.0): they come before `resume`.
EXPECT_RUN='spike_run_live_split "$WATCHDOG_SECS" "$CAP/raw.jsonl" "$CAP/stderr.txt" "$SPIKE_VERIFIED_COPY" exec --json --sandbox workspace-write -C "$WT" "$TASK"'
EXPECT_RESUME='spike_run_live_split "$WATCHDOG_SECS" "$CAP/resume.raw.jsonl" "$CAP/resume.stderr.txt" "$SPIKE_VERIFIED_COPY" exec --json --sandbox workspace-write -C "$WT" resume "$THREAD_ID" "$PROMPT"'
for s in run.sh resume.sh; do
  f="$CODEX/$s"
  # rules 2 and 3: the exact argument vector on the single spike_run_live_split line is the allow-list; nothing may be appended
  # (the call is one line on purpose: the whole call, including the last argument, is compared)
  case "$s" in run.sh) EXPECT=$EXPECT_RUN ;; *) EXPECT=$EXPECT_RESUME ;; esac
  eq "$s: exactly one spike_run_live_split line" "$(grep -cE '^[[:space:]]*spike_run_live_split ' "$f")" "1"
  eq "$s: the spike_run_live_split line is exactly the allow-listed argument vector" "$(grep -E '^[[:space:]]*spike_run_live_split ' "$f")" "$EXPECT"
  # explicit rejections (defense in depth; the whole file is searched, comments included)
  for flag in --config --profile --dangerously --oss --local-provider --approve-for-me --enable --disable \
    --ignore-user-config --strict-config --ignore-rules; do
    check "$s: does not contain $flag" test "$(grep -c -e "$flag" "$f")" = "0"
  done
  check "$s: no -c flag" test "$(grep -cE "(^|[[:space:]\"'])-c([[:space:]\"'=]|$)" "$f")" = "0"
  check "$s: no attached -ckey=value" test "$(grep -cE "(^|[[:space:]\"'])-c[^[:space:]\"']" "$f")" = "0"
  check "$s: no -p flag" test "$(grep -cE "(^|[[:space:]\"'])-p([[:space:]\"'=]|$)" "$f")" = "0"
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
  eq "$s: exactly one spike_run_live_split call" "$(grep -cE '^[[:space:]]*spike_run_live_split ' "$f")" "1"
  check "$s: no loop keywords" test "$(grep -cE '^[[:space:]]*(while|until|for|select)[[:space:]]' "$f")" = "0"
  check "$s: no eval" test "$(grep -cE '(^|[[:space:];])eval[[:space:]]' "$f")" = "0"
  check "$s: no retry or sleep wording in code" test "$(grep -vE '^[[:space:]]*#' "$f" | grep -ciE 'retry|sleep')" = "0"
  # the pinned runner API: the registered copy is the only thing started, with the watchdog
  check "$s: runs the registered copy" grep -q 'spike_run_live_split "\$WATCHDOG_SECS" .* "\$SPIKE_VERIFIED_COPY"' "$f"
  check "$s: watchdog is 120 s" grep -q '^WATCHDOG_SECS=120$' "$f"
  check "$s: registers codex through the runner" grep -q '^spike_register_cli codex$' "$f"
  check "$s: sign-in by status exit code only" grep -q 'spike_run_status 30 /dev/null "\$SPIKE_VERIFIED_COPY" login status' "$f"
  # rule 3: codex exec only
  check "$s: the argument vector starts with exec --json --sandbox workspace-write -C" grep -qF ' exec --json --sandbox workspace-write -C "$WT" ' "$f"
  check "$s: never runs a bare codex or claude command" test "$(grep -vE '^[[:space:]]*#' "$f" | grep -cE "^[[:space:]]*(codex|claude)[[:space:]]|[|;&(][[:space:]]*(codex|claude)[[:space:]]")" = "0"
  check "$s: never sets SPIKE_LIVE" test "$(grep -vE '^[[:space:]]*#' "$f" | grep -cE "^[[:space:]]*(export[[:space:]]+|declare[[:space:]]+-x[[:space:]]+)?SPIKE_LIVE=|env[[:space:]]+SPIKE_LIVE=")" = "0"
done
check "resume.sh resumes by thread id" grep -qF -e ' -C "$WT" resume "$THREAD_ID" "$PROMPT"' "$CODEX/resume.sh"
check "run.sh task text is the brief's" grep -qF "TASK='Create a file named hello.txt whose only line is the three words hello from codex with no punctuation. Then reply DONE.'" "$CODEX/run.sh"
check "resume.sh prompt is the brief's" grep -qF "PROMPT='Append a second line to hello.txt that is only the word resumed with no punctuation. Reply DONE.'" "$CODEX/resume.sh"
check "parse.jq has no input/env/ltrimstr surprises: no \$ENV, no env, no input_filename" test "$(grep -vE '^[[:space:]]*#' "$CODEX/parse.jq" | grep -cE '\$ENV|\benv\b|input_filename|\$__prog')" = "0"

# ---- the allow-list check itself catches an appended or inserted argument ----------------------------------------------------
argv_line_ok() { # file expected-line: passes only when the single spike_run_live_split line equals the expectation exactly
  [ "$(grep -cE '^[[:space:]]*spike_run_live_split ' "$1")" = "1" ] && [ "$(grep -E '^[[:space:]]*spike_run_live_split ' "$1")" = "$2" ]
}
check "allow-list self-test: the real run.sh passes" argv_line_ok "$CODEX/run.sh" "$EXPECT_RUN"
check "allow-list self-test: the real resume.sh passes" argv_line_ok "$CODEX/resume.sh" "$EXPECT_RESUME"
for extra in '--enable foo' '--disable foo' '--ignore-user-config' '--strict-config' '--ignore-rules' '-ckey=value' '-c key=value' '--profile x' '--yolo'; do
  sed -e "s|^\(spike_run_live_split .*-C \"\$WT\"\)|\1 $extra|" "$CODEX/run.sh" > "$TMP/mut_run.sh"
  if argv_line_ok "$TMP/mut_run.sh" "$EXPECT_RUN"; then fail "allow-list self-test: run.sh with [$extra] after -C was accepted"; else pass; fi
  sed -e "s|^\(spike_run_live_split .*-C \"\$WT\"\)|\1 $extra|" "$CODEX/resume.sh" > "$TMP/mut_resume.sh"
  if argv_line_ok "$TMP/mut_resume.sh" "$EXPECT_RESUME"; then fail "allow-list self-test: resume.sh with [$extra] after -C was accepted"; else pass; fi
  sed -e "s|^\(spike_run_live_split .*\)\$|\1 $extra|" "$CODEX/run.sh" > "$TMP/mut_run2.sh"
  if argv_line_ok "$TMP/mut_run2.sh" "$EXPECT_RUN"; then fail "allow-list self-test: run.sh with [$extra] at the end was accepted"; else pass; fi
done

# ---- hello_ok (post-gate byte check) is exercised offline by extracting the function from the script ------------------------
hello_case() { # script label content-printf-format expect(0|1)
  local script=$1 label=$2 content=$3 want=$4 d got
  d=$(mktemp -d "$TMP/hello.XXXXXX")
  [ "$content" = "@none" ] || printf "$content" > "$d/hello.txt"
  awk '/^hello_ok\(\) \{/ { p = 1 } p { print } p && /^\}/ { exit }' "$CODEX/$script" > "$d/fn.sh"
  [ -s "$d/fn.sh" ] || { fail "$script: hello_ok function not found"; return; }
  "$SH" -c '. "$1"; hello_ok "$2"' _ "$d/fn.sh" "$d"
  got=$?
  [ "$got" -ne 0 ] && got=1
  eq "$script hello_ok: $label" "$got" "$want"
}
hello_case run.sh "exact, no trailing newline" 'hello from codex' 0
hello_case run.sh "exact, one trailing newline" 'hello from codex\n' 0
hello_case run.sh "two trailing newlines are refused" 'hello from codex\n\n' 1
hello_case run.sh "an extra line is refused" 'hello from codex\nmore\n' 1
hello_case run.sh "a leading blank line is refused" '\nhello from codex\n' 1
hello_case run.sh "different content is refused" 'hello from codex!\n' 1
hello_case run.sh "an empty file is refused" '' 1
hello_case run.sh "a missing file is refused" '@none' 1
hello_case resume.sh "two lines, no trailing newline" 'hello from codex\nresumed' 0
hello_case resume.sh "two lines, one trailing newline" 'hello from codex\nresumed\n' 0
hello_case resume.sh "a blank line before the second line is refused" 'hello from codex\n\nresumed\n' 1
hello_case resume.sh "an extra trailing blank line is refused" 'hello from codex\nresumed\n\n' 1
hello_case resume.sh "a third line is refused" 'hello from codex\nresumed\nmore\n' 1
hello_case resume.sh "only the first line is refused" 'hello from codex\n' 1
hello_case resume.sh "a different second line is refused" 'hello from codex\nresumed twice\n' 1
hello_case resume.sh "a missing file is refused" '@none' 1

# ---- completion_verdict (post-gate decision) is exercised offline by extracting the function from each script --------------
GOODID="0199a213-81c0-7800-8aa1-bbab2a035a53"
verdict_case() { # script label want(0|1) args...
  local script=$1 label=$2 want=$3 d got out
  shift 3
  d=$(mktemp -d "$TMP/verdict.XXXXXX")
  awk '/^completion_verdict\(\) \{/ { p = 1 } p { print } p && /^\}/ { exit }' "$CODEX/$script" > "$d/fn.sh"
  [ -s "$d/fn.sh" ] || { fail "$script: completion_verdict function not found"; return; }
  out=$("$SH" -c '. "$1"; shift; completion_verdict "$@"' _ "$d/fn.sh" "$@")
  got=$?
  [ "$got" -ne 0 ] && got=1
  eq "$script completion_verdict: $label" "$got" "$want"
  if [ "$want" = "1" ]; then check "$script completion_verdict: [$label] prints a reason" test -n "$out"; fi
}
verdict_case run.sh "all good" 0 0 0 completed "$GOODID"
verdict_case run.sh "CLI exit non-zero" 1 1 0 completed "$GOODID"
verdict_case run.sh "watchdog timeout (124)" 1 124 0 completed "$GOODID"
verdict_case run.sh "parse.jq failed (jq exit non-zero) even if the status text says completed" 1 0 5 completed "$GOODID"
verdict_case run.sh "status failed" 1 0 0 failed "$GOODID"
verdict_case run.sh "status incomplete" 1 0 0 incomplete "$GOODID"
verdict_case run.sh "status empty" 1 0 0 "" "$GOODID"
verdict_case run.sh "missing thread id" 1 0 0 completed ""
verdict_case run.sh "thread id none" 1 0 0 completed "none" 
verdict_case run.sh "thread id with a bad character" 1 0 0 completed "0199a213;81c0"
verdict_case run.sh "thread id too short" 1 0 0 completed "abc"
verdict_case run.sh "thread id too long" 1 0 0 completed "$(printf 'a%.0s' $(seq 1 65))"
verdict_case run.sh "everything wrong" 1 124 5 "" ""
verdict_case resume.sh "all good, same id" 0 0 0 completed "$GOODID" "$GOODID"
verdict_case resume.sh "CLI exit non-zero" 1 1 0 completed "$GOODID" "$GOODID"
verdict_case resume.sh "watchdog timeout (124)" 1 124 0 completed "$GOODID" "$GOODID"
verdict_case resume.sh "parse.jq failed" 1 0 5 completed "$GOODID" "$GOODID"
verdict_case resume.sh "status failed" 1 0 0 failed "$GOODID" "$GOODID"
verdict_case resume.sh "status incomplete" 1 0 0 incomplete "$GOODID" "$GOODID"
verdict_case resume.sh "missing thread id" 1 0 0 completed "" "$GOODID"
verdict_case resume.sh "thread id differs from the first run's" 1 0 0 completed "0199a213-81c0-7800-8aa1-bbab2a035a99" "$GOODID"
verdict_case resume.sh "bad thread id" 1 0 0 completed "bad id!!!" "bad id!!!"
# the scripts feed the verdict with the parser's real exit status and the parsed status/thread id
for s in run.sh resume.sh; do
  check "$s: PARSE_RC is taken right after the parse.jq call" "$SH" -c 'grep -A1 "parse.jq\" < .*raw.jsonl\" > " "$1" | grep -q "^PARSE_RC=\$?$"' _ "$CODEX/$s"
  check "$s: the verdict is called with the run status, the parse status, the parsed status and the thread id" grep -q 'completion_verdict "\$RUN_RC" "\$PARSE_RC" "\$STATUS"' "$CODEX/$s"
  check "$s: a failing verdict sets OK=0" grep -q '^REASONS="\$(completion_verdict .*)" || {$' "$CODEX/$s"
done

# ---- resume.sh refuses linked capture files before reading them (rule 4) ---------------------------------------------------
LK=$(mktemp -d "$TMP/links.XXXXXX")
awk '/^link_count\(\) \{/ { p = 1 } p { print } p && /^\}/ { exit }' "$CODEX/resume.sh" > "$LK/fn.sh"
awk '/^safe_input\(\) \{/ { p = 1 } p { print } p && /^\}/ { exit }' "$CODEX/resume.sh" >> "$LK/fn.sh"
check "link_count and safe_input found in resume.sh" test "$(grep -c '^link_count()\|^safe_input()' "$LK/fn.sh")" = "2"
safe_rc() { # file: exit status of safe_input; the output goes to $LK/out and $LK/err
  "$SH" -c '. "$1"; . "$2"; safe_input "$3"' _ "$SPIKE/lib/common.sh" "$LK/fn.sh" "$1" > "$LK/out" 2> "$LK/err" < /dev/null
}
link_count_of() { "$SH" -c '. "$1"; link_count "$2"' _ "$LK/fn.sh" "$1"; }
CANARY="CANARY-TEXT-must-never-be-printed-7f3a9c"
mkdir "$LK/elsewhere" "$LK/cap"
printf '%s\n' "$CANARY" > "$LK/elsewhere/secret.txt"
printf '{"type":"thread.started","thread_id":"0199a213-81c0-7800-8aa1-bbab2a035a53"}\n' > "$LK/cap/raw.jsonl"
printf '%s\n' "$LK/wt" > "$LK/cap/worktree.txt"
safe_rc "$LK/cap/raw.jsonl"; eq "safe_input: a plain single-link file is accepted" "$?" "0"
safe_rc "$LK/cap/worktree.txt"; eq "safe_input: a plain worktree.txt is accepted" "$?" "0"
eq "link_count: a plain file has one link" "$(link_count_of "$LK/cap/raw.jsonl")" "1"
ln "$LK/elsewhere/secret.txt" "$LK/cap/linked.jsonl"
eq "link_count: a hard-linked file has two links" "$(link_count_of "$LK/cap/linked.jsonl")" "2"
safe_rc "$LK/cap/linked.jsonl"; check "safe_input: a hard link to a canary file is refused" test "$?" -ne 0
check "safe_input: the canary text reached neither stdout nor stderr" test "$(cat "$LK/out" "$LK/err" | grep -c "$CANARY")" = "0"
check "safe_input: nothing is printed at all" test ! -s "$LK/out" -a ! -s "$LK/err"
# a hard link made from the capture's own file (the other name lives anywhere)
ln "$LK/cap/raw.jsonl" "$LK/elsewhere/second-name"
safe_rc "$LK/cap/raw.jsonl"; check "safe_input: a capture file that gained another hard link is refused" test "$?" -ne 0
rm -f "$LK/elsewhere/second-name"
ln -s "$LK/elsewhere/secret.txt" "$LK/cap/sym.jsonl"
safe_rc "$LK/cap/sym.jsonl"; check "safe_input: a symlink to the canary is refused" test "$?" -ne 0
check "safe_input: the canary text did not leak through the symlink case" test "$(cat "$LK/out" "$LK/err" | grep -c "$CANARY")" = "0"
safe_rc "$LK/cap"; check "safe_input: a directory is refused" test "$?" -ne 0
safe_rc "$LK/cap/missing.jsonl"; check "safe_input: a missing file is refused" test "$?" -ne 0
# the wiring: both inputs are checked before any read of them, and the resume.* pre-existence check covers planted names
SI=$(grep -n '^safe_input "\$CAP/raw.jsonl"' "$CODEX/resume.sh" | head -n 1 | cut -d: -f1)
RJ=$(grep -n 'parse.jq" < "\$CAP/raw.jsonl"' "$CODEX/resume.sh" | head -n 1 | cut -d: -f1)
RW=$(grep -n 'head -n 1 "\$CAP/worktree.txt"' "$CODEX/resume.sh" | head -n 1 | cut -d: -f1)
check "safe_input runs on raw.jsonl and worktree.txt before either is read" test -n "$SI" -a -n "$RJ" -a -n "$RW" -a "${SI:-999999}" -lt "${RJ:-0}" -a "${SI:-999999}" -lt "${RW:-0}"
check "the safe_input call names both capture files" grep -q '^safe_input "\$CAP/raw.jsonl" && safe_input "\$CAP/worktree.txt"' "$CODEX/resume.sh"
check "no capture file is read anywhere before the check" test "$(head -n "$((SI - 1))" "$CODEX/resume.sh" | grep -vE '^[[:space:]]*#' | grep -cE '(<|cat|head|tail|jq|sed|awk)[^|]*\$CAP/(raw\.jsonl|worktree\.txt)')" = "0"
mkdir "$LK/cap3"
: > "$LK/cap3/resume.raw.jsonl"
ln -s "$LK/elsewhere/nothing-here" "$LK/cap3/resume.stderr.txt"
check "a planted resume.* name (file or dangling symlink) is seen by the glob check" "$SH" -c 'compgen -G "$1/resume.*"' _ "$LK/cap3"
check "resume.sh refuses any pre-existing resume.* name" grep -q 'compgen -G "\$CAP/resume\.\*"' "$CODEX/resume.sh"

# ---- the one-resume reservation is atomic (mkdir), made before the CLI call, and never removed ----------------------------
RD=$(mktemp -d "$TMP/resv.XXXXXX")
awk '/^reserve_resume\(\) \{/ { p = 1 } p { print } p && /^\}/ { exit }' "$CODEX/resume.sh" > "$RD/fn.sh"
check "reserve_resume function found" test -s "$RD/fn.sh"
mkdir "$RD/cap"
"$SH" -c '. "$1"; reserve_resume "$2"' _ "$RD/fn.sh" "$RD/cap"
eq "first reservation succeeds" "$?" "0"
check "the reservation directory exists" test -d "$RD/cap/resume.lock"
"$SH" -c '. "$1"; reserve_resume "$2"' _ "$RD/fn.sh" "$RD/cap"
check "second reservation of the same capture fails" test "$?" -ne 0
# two racing reservations: exactly one wins
mkdir "$RD/cap2"
for i in 1 2 3 4 5 6; do
  ( "$SH" -c '. "$1"; reserve_resume "$2" && echo won' _ "$RD/fn.sh" "$RD/cap2" > "$RD/race.$i" 2>/dev/null ) &
done
wait
eq "six racing reservations: exactly one wins" "$(cat "$RD"/race.* | grep -c '^won$')" "1"
RLINE=$(grep -n '^reserve_resume "\$CAP"' "$CODEX/resume.sh" | head -n 1 | cut -d: -f1)
LLINE=$(grep -nE '^[[:space:]]*spike_run_live_split ' "$CODEX/resume.sh" | head -n 1 | cut -d: -f1)
check "the reservation call comes before the live CLI call" test -n "$RLINE" -a -n "$LLINE" -a "${RLINE:-999999}" -lt "${LLINE:-0}"
check "resume.sh never removes the reservation (no rm/rmdir)" test "$(grep -vE '^[[:space:]]*#' "$CODEX/resume.sh" | grep -cE '(^|[[:space:];|&])(rm|rmdir)[[:space:]]')" = "0"
check "resume.sh refuses an existing lock early" grep -q 'resume.lock' "$CODEX/resume.sh"

# ---- no heuristic split: stdout and stderr go to separate files through the runner, nothing is split afterwards -----------------
for s in run.sh resume.sh; do
  check "$s: no awk split of a combined file" test "$(grep -vE '^[[:space:]]*#' "$CODEX/$s" | grep -cE 'awk -v|combined')" = "0"
  check "$s: plain spike_run_live is not called" test "$(grep -vE '^[[:space:]]*#' "$CODEX/$s" | grep -cE '(^|[^_[:alnum:]])spike_run_live[[:space:]]')" = "0"
  check "$s: the split call names separate stdout and stderr files" grep -qE '^spike_run_live_split "\$WATCHDOG_SECS" "\$CAP/(resume\.)?raw\.jsonl" "\$CAP/(resume\.)?stderr\.txt" ' "$CODEX/$s"
done

printf 'test_codex_parse: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
