#!/bin/bash
# Offline tests for spike/run-both.sh (T-007).
#   /bin/bash spike/tests/test_run_both.sh        (exit 0 = all passed)
#
# Never sets SPIKE_LIVE, never starts a provider CLI. Three kinds of proof:
#   1. the REAL script and the REAL gate: without SPIKE_LIVE it exits 3 and a fake claude/codex on the PATH (which would write a
#      marker file if started) stays unstarted; --dry-run exits 0 and prints the plan; unknown arguments exit 2;
#   2. static review of the script text (one call each, fixed order, a sleep of at least 5 s between, no loop/background/retry/resume,
#      no config override, no direct CLI start);
#   3. the functions of the script (extracted between its markers) on the T-004 golden outputs and on hostile capture inputs, and the
#      whole flow in a SANDBOX COPY of spike/ whose two run scripts and preflight are fakes that write a log and copy a fixture. The
#      sandbox copy of lib/common.sh has ONE appended line that makes the live gate a no-op, because a test must not set the live
#      opt-in; that is safe here because nothing in the sandbox can start a provider CLI (the fakes are the only "run" scripts).
set -u
unset CDPATH

HERE="$(cd "$(dirname "$0")" && pwd -P)"
SPIKE="$(cd "$HERE/.." && pwd -P)"
REPO_TOP="$(cd "$SPIKE/.." && pwd -P)"
RUN="$SPIKE/run-both.sh"
SELF="$HERE/test_run_both.sh"
EXP="$SPIKE/normalize/expected"

JQ_BIN="$(command -v jq)"
if [ -z "$JQ_BIN" ]; then echo "jq is required to run this suite" >&2; exit 1; fi
PATH="/usr/bin:/bin:$(dirname -- "$JQ_BIN")"
export PATH
unset SPIKE_LIVE

TMP="$(mktemp -d "${TMPDIR:-/tmp}/run-both-test.XXXXXX")" || exit 2
TMP="$(cd "$TMP" && pwd -P)" || exit 2
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }
check() { # check <name> <command...>
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok; else bad "$name"; fi
}
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1 (expected [$2], got [$3])"; fi; }
expect() { # expect <name> <json> <jq filter that must print true>
  local out
  out="$(printf '%s' "$2" | jq -r "$3" 2>/dev/null)"
  if [ "$out" = "true" ]; then ok; else bad "$1 (got: $out)"; fi
}
has() { case "$2" in *"$3"*) ok ;; *) bad "$1 (missing [$3])" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1 (found [$3])" ;; *) ok ;; esac; }
code_lines() { grep -v '^[[:space:]]*#' "$1"; } # non-comment lines
lineno() { grep -n -- "$2" "$1" | head -n 1 | cut -d: -f1; } # first line number of a fixed string

# ---- syntax, mode ------------------------------------------------------------------------------------------------------------
check "bash -n run-both.sh" /bin/bash -n "$RUN"
check "bash -n test_run_both.sh" /bin/bash -n "$SELF"
check "run-both.sh is executable" test -x "$RUN"
check "run-both.sh starts with #!/bin/bash and set -u and umask 077" test "$(head -n 1 "$RUN")" = "#!/bin/bash" -a "$(grep -c '^set -u$' "$RUN")" = "1" -a "$(grep -c '^umask 077$' "$RUN")" = "1"

# ---- static review (rules 1, 10, 3, 2, 6) ---------------------------------------------------------------------------------
CL_CALL='"$HERE/claude/run.sh"'
CX_CALL='"$HERE/codex/run.sh"'
eq "exactly one call of claude/run.sh" "1" "$(code_lines "$RUN" | grep -cF -- "$CL_CALL")"
eq "exactly one call of codex/run.sh" "1" "$(code_lines "$RUN" | grep -cF -- "$CX_CALL")"
eq "exactly one preflight call" "1" "$(code_lines "$RUN" | grep -cF -- '"$HERE/preflight.sh"')"
check "no resume.sh call" test "$(code_lines "$RUN" | grep -c 'resume')" = "0"
check "no loop keyword (for, while, until, select)" test "$(code_lines "$RUN" | grep -cE '(^|[;&|(]|then|do)[[:space:]]*(for|while|until|select)[[:space:]]')" = "0"
check "no background job (a lone ampersand) in code" test "$(code_lines "$RUN" | grep -cE '(^|[^&>])&($|[^&>0-9])')" = "0"
check "no wait, disown, nohup, setsid, coproc, xargs, parallel" test "$(code_lines "$RUN" | grep -cE '(^|[^A-Za-z_-])(wait|disown|nohup|setsid|coproc|xargs|parallel)([^A-Za-z_-]|$)')" = "0"
check "no cron, crontab, at, batch, launchctl, systemd-run, timer" test "$(code_lines "$RUN" | grep -ciE '(^|[^A-Za-z_-])(cron|crontab|at|batch|launchctl|systemd-run|systemctl)([^A-Za-z_-]|$)')" = "0"
check "no retry, again or redo wording in code" test "$(code_lines "$RUN" | grep -vE '^[[:space:]]*(printf|spike_err)' | grep -ciE 'retry|retries|redo|again')" = "0"
check "no -c, --config or --profile option outside jq lines" test "$(code_lines "$RUN" | grep -vE 'jq |wc ' | grep -cE '(^|[[:space:]])(-c|--config|--profile)([[:space:]=]|$)')" = "0"
check "no config-home variable or CLI home path (rules 2 and 4)" test "$(grep -cE '(CLAUDE|CODEX|GROK|KIMI_CODE|GEMINI)_(CONFIG_DIR|HOME)|credentials|oauth|security find|Keychain' "$RUN")" = "0"
check "no SPIKE_LIVE assignment in the script, the test or the report" test "$(cat "$RUN" "$SELF" "$SPIKE/PHASE0-REPORT.md" | grep -cE 'SPIKE_LIV[E]=|export[[:space:]]+SPIKE_LIV[E]')" = "0"
check "no provider CLI is started by name (no PTY, no TUI)" test "$(code_lines "$RUN" | grep -cE '(^|[;&|(`]|\$\()[[:space:]]*((exec|command|env|nohup|time)[[:space:]]+)*(claude|codex|[^[:space:]]*/claude|[^[:space:]]*/codex)([[:space:])`;|&]|$)')" = "0"
check "no pty, expect, script or osascript use" test "$(code_lines "$RUN" | grep -cE '(^|[^A-Za-z_-])(pty|expect|script|osascript|tmux|screen)([^A-Za-z_-]|$)')" = "0"

gap="$(grep -E '^GAP_SECS=[0-9]+$' "$RUN" | head -n 1 | cut -d= -f2)"
if [ -n "$gap" ] && [ "$gap" -ge 5 ]; then ok; else bad "GAP_SECS is at least 5 (got [$gap])"; fi
check "GAP_SECS is readonly and assigned once" test "$(grep -cE '^(readonly )?GAP_SECS=|GAP_SECS=' "$RUN")" = "1" -a "$(grep -c '^readonly GAP_SECS' "$RUN")" = "1"
L_PRE="$(lineno "$RUN" '"$HERE/preflight.sh"')"
L_CL="$(lineno "$RUN" "$CL_CALL")"
L_SLEEP="$(lineno "$RUN" 'sleep "$GAP_SECS"')"
L_CX="$(lineno "$RUN" "$CX_CALL")"
if [ -n "$L_PRE" ] && [ -n "$L_CL" ] && [ -n "$L_SLEEP" ] && [ -n "$L_CX" ] && [ "$L_PRE" -lt "$L_CL" ] && [ "$L_CL" -lt "$L_SLEEP" ] && [ "$L_SLEEP" -lt "$L_CX" ]; then ok; else bad "preflight, claude call, sleep and codex call appear in that order"; fi
# the signal flag is checked before the codex call: a stop_if_signalled call sits between the sleep and the codex call, and another
# between the claude call and the sleep
between() { awk -v a="$2" -v b="$3" 'NR > a && NR < b && /^stop_if_signalled$/ {n++} END {exit !n}' "$1"; }
if between "$RUN" "$L_SLEEP" "$L_CX"; then ok; else bad "stop_if_signalled sits between the sleep and the codex call"; fi
if between "$RUN" "$L_CL" "$L_SLEEP"; then ok; else bad "stop_if_signalled sits between the claude call and the sleep"; fi
check "the signal trap sets a flag and is installed after the gate" test "$(lineno "$RUN" '^spike_require_live$')" -lt "$(lineno "$RUN" "trap 'SIGNAL_RC=130' INT")"
check "traps exist for INT, TERM and HUP with 130/143/129" test "$(grep -cE "^trap 'SIGNAL_RC=(130|143|129)' (INT|TERM|HUP)$" "$RUN")" = "3"
check "the live gate is the first statement after sourcing common.sh" test "$(awk '/^\. "\$HERE\/lib\/common.sh"$/ {f=1; next} f && NF && $0 !~ /^#/ {print; exit}' "$RUN")" = "spike_require_live"
check "dry-run exit happens before common.sh is sourced" test "$(lineno "$RUN" 'exit 0')" -lt "$(lineno "$RUN" '^\. "\$HERE/lib/common.sh"$')" 2>/dev/null
check "ROOT is under spike/captures/run-both" grep -q '^ROOT="\$HERE/captures/run-both/\$STAMP"$' "$RUN"
check "ROOT is created with mkdir (no -p), so an existing one is refused" grep -q '^mkdir "\$ROOT" ||' "$RUN"
check "the normalized files are written under noclobber" grep -q 'set -C; jq' "$RUN"
check "git runs with a closed environment and fsmonitor forced off" grep -q 'GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false' "$RUN"

# ---- the hello constants equal the text inside each merged run.sh TASK (the brief's drift guard) -----------------------------
CLAUDE_HELLO="$(grep -E "^CLAUDE_HELLO='" "$RUN" | head -n 1 | sed "s/^CLAUDE_HELLO='//; s/'\$//")"
CODEX_HELLO="$(grep -E "^CODEX_HELLO='" "$RUN" | head -n 1 | sed "s/^CODEX_HELLO='//; s/'\$//")"
check "CLAUDE_HELLO is non-empty" test -n "$CLAUDE_HELLO"
check "CODEX_HELLO is non-empty" test -n "$CODEX_HELLO"
check "CLAUDE_HELLO appears verbatim in the TASK= line of spike/claude/run.sh" test "$(grep '^TASK=' "$SPIKE/claude/run.sh" | grep -cF -- "$CLAUDE_HELLO")" = "1"
check "CODEX_HELLO appears verbatim in the TASK= line of spike/codex/run.sh" test "$(grep '^TASK=' "$SPIKE/codex/run.sh" | grep -cF -- "$CODEX_HELLO")" = "1"

# ---- fake CLIs on a sandbox PATH (they write a marker if ever started) -------------------------------------------------------
FAKEBIN="$TMP/fakebin"
GATEBOX="$TMP/gatebox"
MARK_C="$TMP/claude-was-started"
MARK_X="$TMP/codex-was-started"
mkdir -p "$FAKEBIN" "$GATEBOX/tmp" "$GATEBOX/home"
printf '#!/bin/bash\necho started > "%s"\nexit 0\n' "$MARK_C" > "$FAKEBIN/claude"
printf '#!/bin/bash\necho started > "%s"\nexit 0\n' "$MARK_X" > "$FAKEBIN/codex"
chmod +x "$FAKEBIN/claude" "$FAKEBIN/codex"

CAPDIR="$SPIKE/captures/run-both"
before="$(ls -A "$CAPDIR" 2>/dev/null)"
gated() { # gated <args...>: the real script, no live opt-in
  env -u SPIKE_LIVE PATH="$FAKEBIN:$PATH" HOME="$GATEBOX/home" TMPDIR="$GATEBOX/tmp" /bin/bash "$RUN" "$@" >"$TMP/gate.out" 2>"$TMP/gate.err" </dev/null
  echo $?
}
eq "without SPIKE_LIVE: exit 3" "3" "$(gated)"
eq "without SPIKE_LIVE and --keep: exit 3" "3" "$(gated --keep)"
check "the refusal is printed on stderr" grep -q 'refusing to run' "$TMP/gate.err"
check "the fake claude was never started (gate)" test ! -e "$MARK_C"
check "the fake codex was never started (gate)" test ! -e "$MARK_X"
eq "no spike/captures/run-both entry appears without SPIKE_LIVE" "$before" "$(ls -A "$CAPDIR" 2>/dev/null)"
check "no scratch repo was created without SPIKE_LIVE" test -z "$(ls -A "$GATEBOX/tmp")"

eq "an unknown argument exits 2" "2" "$(gated --bogus)"
eq "a stray word exits 2" "2" "$(gated run)"
eq "an unknown argument exits 2 even with --dry-run" "2" "$(gated --dry-run --bogus)"
check "no fake CLI started and nothing created after bad arguments" test ! -e "$MARK_C" -a ! -e "$MARK_X" -a "$before" = "$(ls -A "$CAPDIR" 2>/dev/null)"

# ---- --dry-run ---------------------------------------------------------------------------------------------------------------
eq "--dry-run exits 0 without SPIKE_LIVE" "0" "$(gated --dry-run)"
DRY="$(cat "$TMP/gate.out")"
D_PRE="$(printf '%s\n' "$DRY" | grep -n 'spike/preflight.sh' | head -n 1 | cut -d: -f1)"
D_CL="$(printf '%s\n' "$DRY" | grep -n 'spike/claude/run.sh' | head -n 1 | cut -d: -f1)"
D_SL="$(printf '%s\n' "$DRY" | grep -nE '^ *[0-9]+\. sleep [0-9]+$' | head -n 1 | cut -d: -f1)"
D_CX="$(printf '%s\n' "$DRY" | grep -n 'spike/codex/run.sh' | head -n 1 | cut -d: -f1)"
if [ -n "$D_PRE" ] && [ -n "$D_CL" ] && [ -n "$D_SL" ] && [ -n "$D_CX" ] && [ "$D_PRE" -lt "$D_CL" ] && [ "$D_CL" -lt "$D_SL" ] && [ "$D_SL" -lt "$D_CX" ]; then ok; else bad "dry-run prints preflight, claude, sleep, codex in order"; fi
secs="$(printf '%s\n' "$DRY" | grep -E '^ *[0-9]+\. sleep [0-9]+$' | head -n 1 | sed 's/.*sleep //')"
if [ -n "$secs" ] && [ "$secs" -ge 5 ]; then ok; else bad "dry-run prints a wait of at least 5 s (got [$secs])"; fi
has "dry-run prints the normalize commands" "$DRY" 'spike/normalize/claude.jq'
has "dry-run prints the normalize commands (codex)" "$DRY" 'spike/normalize/codex.jq'
has "dry-run uses placeholder paths" "$DRY" '<ROOT>'
check "dry-run started no fake CLI" test ! -e "$MARK_C" -a ! -e "$MARK_X"
eq "dry-run created no captures entry" "$before" "$(ls -A "$CAPDIR" 2>/dev/null)"
check "dry-run created no scratch repo" test -z "$(ls -A "$GATEBOX/tmp")"
eq "--dry-run --keep exits 0" "0" "$(gated --dry-run --keep)"
eq "dry-run output is the same with SPIKE_LIVE unset" "$DRY" "$(cat "$TMP/gate.out")"

# ---- ROOT is under spike/captures and git ignores it ---------------------------------------------------------------------------
if git -C "$REPO_TOP" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  check "git ignores spike/captures/run-both/<stamp>/claude/<ts>/raw.jsonl" git -C "$REPO_TOP" check-ignore -q -- "spike/captures/run-both/20260101T000000Z/claude/20260101T000001Z/raw.jsonl"
  check "git ignores spike/captures/run-both/<stamp>/run-both.json" git -C "$REPO_TOP" check-ignore -q -- "spike/captures/run-both/20260101T000000Z/run-both.json"
else
  ok
  ok
fi

# ---- the functions of the script (extracted between the markers) ------------------------------------------------------------
FUNCS="$TMP/funcs.sh"
sed -n '/^# ---- begin functions/,/^# ---- end functions/p' "$RUN" > "$FUNCS"
check "the functions block is extracted and not empty" test "$(wc -l < "$FUNCS" | tr -d ' ')" -gt 40
FBOX="$TMP/fbox"
mkdir -p "$FBOX/tmp" "$FBOX/home"
export HOME="$FBOX/home"
export TMPDIR="$FBOX/tmp"
# shellcheck disable=SC1091
. "$SPIKE/lib/common.sh"
# shellcheck disable=SC1090
. "$FUNCS"
for fn in printable safe_input read_wt hello_ok changed_files build_row table; do
  check "function $fn is defined" test "$(type -t "$fn")" = "function"
done

# -- the row builder on the T-004 golden outputs
row() { build_row "$1" "$2" "$3" "$4" "$5"; }
R="$(row claude 0 yes "hello.txt" "$EXP/claude-sample.jsonl")"
expect "claude-sample: PASS" "$R" '.verdict == "PASS" and .provider == "claude" and .run_exit == 0'
expect "claude-sample: session is the first 4 characters and three dots" "$R" '.session == "1111..."'
expect "claude-sample: turns, tokens, estimated cost" "$R" '.turns == 2 and .tokens == {input: 300, output: 49, cache_read: 120, cache_write: 0} and .cost_usd_estimate == 0.0123'
expect "claude-sample: counts" "$R" '.rate_limited == 0 and .unknown == 0 and .needs_mapping == false and .hello_ok == true'
expect "claude-sample: warnings counted" "$R" '.warnings >= 1'
expect "claude-sample: changed files listed" "$R" '.changed == ["hello.txt"]'
expect "claude-sample: no reasons when PASS" "$R" '.reasons == []'
for f in claude-routine codex-sample codex-item-warning; do
  cli="${f%%-*}"
  R="$(row "$cli" 0 yes "" "$EXP/$f.jsonl")"
  expect "$f: PASS" "$R" '.verdict == "PASS" and .rate_limited == 0'
done
R="$(row codex 0 yes "" "$EXP/codex-sample.jsonl")"
expect "codex-sample: session is 0199..." "$R" '.session == "0199..."'
expect "codex-sample: one turn and numeric tokens" "$R" '.turns == 1 and (.tokens.input | type) == "number" and (.tokens.output | type) == "number"'
R="$(row codex 0 yes "" "$EXP/codex-item-warning.jsonl")"
expect "codex-item-warning: 1 warning does not fail" "$R" '.warnings == 1 and .verdict == "PASS"'
R="$(row claude 1 yes "" "$EXP/claude-limits.jsonl")"
expect "claude-limits: FAIL with 3 rate_limited" "$R" '.verdict == "FAIL" and .rate_limited == 3'
R="$(row claude 0 yes "" "$EXP/claude-limits.jsonl")"
expect "claude-limits: FAIL even with exit 0 and hello (error result, rate limits)" "$R" '.verdict == "FAIL" and (.reasons | length) >= 2'
R="$(row codex 0 yes "" "$EXP/codex-failure.jsonl")"
expect "codex-failure: FAIL (two results, is_error, rate_limited)" "$R" '.verdict == "FAIL" and .rate_limited >= 1'
R="$(row codex 0 yes "" "$EXP/codex-malformed.jsonl")"
expect "codex-malformed: unknown events are counted" "$R" '.unknown > 0 and .needs_mapping == true'
R="$(row claude 1 yes "" "$EXP/claude-sample.jsonl")"
expect "a PASSing stream with run.sh exit 1 is FAIL" "$R" '.verdict == "FAIL" and (.reasons | index("run.sh did not exit 0")) != null'
R="$(row claude 0 no "" "$EXP/claude-sample.jsonl")"
expect "a PASSing stream without an exact hello.txt is FAIL" "$R" '.verdict == "FAIL" and .hello_ok == false'
R="$(row claude abc yes "" "$EXP/claude-sample.jsonl")"
expect "a non-numeric exit status is FAIL (never PASS)" "$R" '.verdict == "FAIL"'
R="$(row claude 0 yes "" "$TMP/does-not-exist.jsonl")"
expect "a missing normalized file is FAIL with zero counts" "$R" '.verdict == "FAIL" and .session == "none" and .turns == null and .rate_limited == 0'
: > "$TMP/empty.jsonl"
R="$(row codex 0 yes "" "$TMP/empty.jsonl")"
expect "an empty normalized file is FAIL" "$R" '.verdict == "FAIL"'
# a clean stream plus one unknown event: still PASS, needs mapping
{ cat "$EXP/codex-sample.jsonl"; printf '%s\n' '{"type":"unknown","provider":"codex","seq":99,"ts":null,"raw":"brand_new","raw_type":"brand_new","keys":[]}'; } > "$TMP/with-unknown.jsonl"
R="$(row codex 0 yes "" "$TMP/with-unknown.jsonl")"
expect "unknown > 0 does not fail the run but needs mapping" "$R" '.verdict == "PASS" and .unknown == 3 and .needs_mapping == true'
# two session_started events or two results are FAIL
{ cat "$EXP/claude-sample.jsonl"; grep '"session_started"' "$EXP/claude-sample.jsonl"; } > "$TMP/two-sessions.jsonl"
R="$(row claude 0 yes "" "$TMP/two-sessions.jsonl")"
expect "two session_started events: FAIL" "$R" '.verdict == "FAIL"'
{ cat "$EXP/claude-sample.jsonl"; grep '"type":"result"' "$EXP/claude-sample.jsonl"; } > "$TMP/two-results.jsonl"
R="$(row claude 0 yes "" "$TMP/two-results.jsonl")"
expect "two results: FAIL" "$R" '.verdict == "FAIL"'
# a hostile session id is cut to four safe characters
{ printf '%s\n' '{"type":"session_started","provider":"claude","seq":1,"ts":null,"raw":"system/init","session_id":"\u001b[31mab\u0007cdef"}'; grep '"type":"result"' "$EXP/claude-sample.jsonl"; } > "$TMP/hostile-sid.jsonl"
R="$(row claude 0 yes "" "$TMP/hostile-sid.jsonl")"
expect "hostile session id: four characters, escapes replaced" "$R" '(.session | length) == 7 and (.session | test("^[A-Za-z0-9?-]{4}[.]{3}$"))'
# result with tokens_known false is not "numeric tokens"
R="$(row codex 0 yes "" "$EXP/codex-failure.jsonl")"
expect "tokens_known false is not numeric tokens" "$R" '.verdict == "FAIL"'

# -- the table
good_json="$TMP/good.json"
{ printf '{"rows":['; row claude 0 yes "hello.txt" "$EXP/claude-sample.jsonl"; printf ','; row codex 0 yes "hello.txt" "$EXP/codex-sample.jsonl"; printf ']}\n'; } > "$good_json"
T="$(table "$good_json")"
has "table: header has provider" "$T" 'provider'
has "table: header has verdict" "$T" 'verdict'
has "table: header has tokens in/out and cache columns" "$T" 'cache_r'
has "table: claude row with its redacted session" "$T" '1111...'
has "table: codex row with its redacted session" "$T" '0199...'
eq "table: no FAIL note when both PASS" "0" "$(printf '%s\n' "$T" | grep -c 'FAIL')"
eq "table: two PASS verdicts" "2" "$(printf '%s\n' "$T" | grep -c 'PASS')"
lacks "table: the full session id is never printed" "$T" '11111111-1111'
bad_json="$TMP/bad.json"
{ printf '{"rows":['; row claude 0 yes "" "$EXP/claude-limits.jsonl"; printf ','; row codex 0 yes "" "$TMP/with-unknown.jsonl"; printf ']}\n'; } > "$bad_json"
T2="$(table "$bad_json")"
has "table: a FAIL row shows FAIL" "$T2" 'FAIL'
has "table: unknown events print needs mapping (T-004)" "$T2" 'needs mapping (T-004)'
has "table: a FAIL note names the reason" "$T2" 'note: claude FAIL:'
# printable filter: control characters in a changed file name never reach the table
esc="$(printf '\033[31m')"
{ printf '{"rows":['; row claude 0 yes "name${esc}x" "$EXP/claude-sample.jsonl"; printf ']}\n'; } > "$TMP/esc.json"
T3="$(table "$TMP/esc.json")"
eq "table output holds no escape character" "0" "$(printf '%s' "$T3" | LC_ALL=C grep -c "$(printf '\033')")"
eq "printable keeps newlines and drops escapes" "ab
c" "$(printf 'a\033b\nc\007' | printable)"

# -- safe_input / read_wt / hello_ok on hostile inputs (rule 4). The CLI-home directory name is read from the lead-owned denylist.
DENY_NAME="$(grep -vE '^[[:space:]]*(#|$)' "$REPO_TOP/compliance/denylist.txt" | head -n 1)"
check "a denylist entry was found for the fake CLI home" test -n "$DENY_NAME"
CLIHOME="$HOME/$DENY_NAME"
mkdir -p "$CLIHOME"
CANARY="canary-$$-must-never-be-printed"
printf '%s\n' "$CANARY" > "$CLIHOME/canary.txt"
WTROOT="$(spike_root)"
mkdir -p "$WTROOT/run-test/repo-wt/w1"
WT1="$(cd "$WTROOT/run-test/repo-wt/w1" && pwd -P)"
printf '%s\n' "$WT1" > "$TMP/wt-ok.txt"
eq "read_wt accepts a worktree under the scratch root" "$WT1" "$(read_wt "$TMP/wt-ok.txt")"
check "safe_input accepts a regular file" safe_input "$TMP/wt-ok.txt"
ln -s "$TMP/wt-ok.txt" "$TMP/wt-link.txt"
check "safe_input refuses a symlink" test "$(safe_input "$TMP/wt-link.txt"; echo $?)" = "1"
check "read_wt refuses a symlink" test "$(read_wt "$TMP/wt-link.txt" >/dev/null 2>&1; echo $?)" != "0"
ln "$TMP/wt-ok.txt" "$TMP/wt-hard.txt"
check "safe_input refuses a hard link" test "$(safe_input "$TMP/wt-hard.txt"; echo $?)" = "1"
check "read_wt refuses a hard link" test "$(read_wt "$TMP/wt-hard.txt" >/dev/null 2>&1; echo $?)" != "0"
rm -f "$TMP/wt-hard.txt"
check "safe_input refuses a directory" test "$(safe_input "$TMP"; echo $?)" = "1"
check "safe_input refuses a missing file" test "$(safe_input "$TMP/nope"; echo $?)" = "1"
check "safe_input refuses an empty argument" test "$(safe_input ""; echo $?)" = "1"
# the same two capture file names the real run scripts write (worktree.path for claude, worktree.txt for codex), as a symlink, a
# hard link and a CLI-home file; the canary text is never printed
for name in worktree.path worktree.txt; do
  d="$TMP/cap-$name"
  mkdir -p "$d"
  out="$TMP/$name.out"
  ln -s "$CLIHOME/canary.txt" "$d/$name"
  read_wt "$d/$name" > "$out" 2>&1
  check "read_wt refuses a symlink to a CLI-home file as $name" test "$?" != "0"
  check "the canary is not printed for a symlinked $name" test "$(grep -c "$CANARY" "$out")" = "0"
  rm -f "$d/$name"
  cp "$CLIHOME/canary.txt" "$d/$name"
  ln "$d/$name" "$d/$name.hard"
  read_wt "$d/$name" > "$out" 2>&1
  check "read_wt refuses a hard-linked $name" test "$?" != "0"
  check "the canary is not printed for a hard-linked $name" test "$(grep -c "$CANARY" "$out")" = "0"
  rm -f "$d/$name" "$d/$name.hard"
  # a real file that lives inside the CLI home
  ln "$CLIHOME/canary.txt" "$CLIHOME/canary.link" 2>/dev/null
  read_wt "$CLIHOME/canary.txt" > "$out" 2>&1
  check "read_wt refuses a file inside a CLI home ($name run)" test "$?" != "0"
  check "the canary is not printed for a CLI-home file ($name run)" test "$(grep -c "$CANARY" "$out")" = "0"
  rm -f "$CLIHOME/canary.link"
done
check "safe_input refuses a file inside a CLI home" test "$(safe_input "$CLIHOME/canary.txt"; echo $?)" = "1"
# path rules of read_wt
printf '%s\n' "$TMP/not-under-scratch" > "$TMP/wt-out.txt"
check "read_wt refuses a path outside the scratch root" test "$(read_wt "$TMP/wt-out.txt" >/dev/null 2>&1; echo $?)" != "0"
printf '%s\n' "$WTROOT/run-test/repo-wt/w1/../../../../.." > "$TMP/wt-dots.txt"
check "read_wt refuses a path that climbs out with .." test "$(read_wt "$TMP/wt-dots.txt" >/dev/null 2>&1; echo $?)" != "0"
printf '%s\n' "relative/path" > "$TMP/wt-rel.txt"
check "read_wt refuses a relative path" test "$(read_wt "$TMP/wt-rel.txt" >/dev/null 2>&1; echo $?)" != "0"
printf '%s\r\n' "$WT1" > "$TMP/wt-cr.txt"
check "read_wt refuses a control character (CR) in the path" test "$(read_wt "$TMP/wt-cr.txt" >/dev/null 2>&1; echo $?)" != "0"
printf '%s\033\n' "$WT1" > "$TMP/wt-esc.txt"
check "read_wt refuses a control character (ESC) in the path" test "$(read_wt "$TMP/wt-esc.txt" >/dev/null 2>&1; echo $?)" != "0"
: > "$TMP/wt-empty.txt"
check "read_wt refuses an empty file" test "$(read_wt "$TMP/wt-empty.txt" >/dev/null 2>&1; echo $?)" != "0"
ln -s "$HOME" "$WTROOT/run-test/home-link"
printf '%s\n' "$WTROOT/run-test/home-link" > "$TMP/wt-sym.txt"
check "read_wt refuses a scratch-root path that resolves into the home (outside the root)" test "$(read_wt "$TMP/wt-sym.txt" >/dev/null 2>&1; echo $?)" != "0"
head -c 5000 /dev/zero | tr '\0' 'a' > "$TMP/wt-big.txt"
check "read_wt refuses an oversized file" test "$(read_wt "$TMP/wt-big.txt" >/dev/null 2>&1; echo $?)" != "0"

# -- hello_ok: byte exact
W="$WT1"
put() { printf "$1" > "$W/hello.txt"; }
put 'hello from claude\n'
check "hello_ok: text plus one newline" hello_ok "$W" "$CLAUDE_HELLO"
put 'hello from claude'
check "hello_ok: text without newline" hello_ok "$W" "$CLAUDE_HELLO"
put 'hello from claude\n\n'
check "hello_ok refuses an extra blank line" test "$(hello_ok "$W" "$CLAUDE_HELLO"; echo $?)" = "1"
put 'hello from claude \n'
check "hello_ok refuses a trailing space" test "$(hello_ok "$W" "$CLAUDE_HELLO"; echo $?)" = "1"
put 'hello from claude\r\n'
check "hello_ok refuses a carriage return" test "$(hello_ok "$W" "$CLAUDE_HELLO"; echo $?)" = "1"
put 'hello from claude\n\0'
check "hello_ok refuses a NUL byte" test "$(hello_ok "$W" "$CLAUDE_HELLO" 2>/dev/null; echo $?)" = "1"
put 'hello from claude\nextra\n'
check "hello_ok refuses a second line" test "$(hello_ok "$W" "$CLAUDE_HELLO"; echo $?)" = "1"
put 'Hello from claude\n'
check "hello_ok refuses a different case" test "$(hello_ok "$W" "$CLAUDE_HELLO"; echo $?)" = "1"
put 'hello from codex\n'
check "hello_ok: the codex text matches CODEX_HELLO" hello_ok "$W" "$CODEX_HELLO"
check "hello_ok: the codex text is not accepted for claude" test "$(hello_ok "$W" "$CLAUDE_HELLO"; echo $?)" = "1"
rm -f "$W/hello.txt"
check "hello_ok refuses a missing file" test "$(hello_ok "$W" "$CLAUDE_HELLO"; echo $?)" = "1"
ln -s "$CLIHOME/canary.txt" "$W/hello.txt"
check "hello_ok refuses a symlinked hello.txt (to a CLI-home file)" test "$(hello_ok "$W" "$CANARY"; echo $?)" = "1"
rm -f "$W/hello.txt"
printf '%s\n' "$CANARY" > "$TMP/outside.txt"
ln "$TMP/outside.txt" "$W/hello.txt"
check "hello_ok refuses a hard-linked hello.txt" test "$(hello_ok "$W" "$CANARY"; echo $?)" = "1"
rm -f "$W/hello.txt"

# -- changed_files: git status only, and a hostile repo config cannot start a program
REPOX="$WTROOT/run-test/gitrepo"
mkdir -p "$REPOX"
git -C "$REPOX" init -q -b main
printf 'x\n' > "$REPOX/README.md"
git -C "$REPOX" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false add README.md
git -C "$REPOX" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m init
printf 'hello\n' > "$REPOX/hello.txt"
printf 'change\n' >> "$REPOX/README.md"
MARKF="$TMP/fsmonitor-ran"
printf '#!/bin/bash\necho ran > "%s"\nprintf "\\0"\n' "$MARKF" > "$TMP/fsm.sh"
chmod +x "$TMP/fsm.sh"
git -C "$REPOX" config core.fsmonitor "$TMP/fsm.sh"
printf '#!/bin/bash\necho ran > "%s"\n' "$MARKF" > "$REPOX/.git/hooks/pre-commit"
CH="$(changed_files "$REPOX")"
has "changed_files lists the untracked file" "$CH" 'hello.txt'
has "changed_files lists the modified file" "$CH" 'README.md'
check "a core.fsmonitor program in the repo config did not run" test ! -e "$MARKF"
CH2="$(changed_files "$TMP/not-a-repo-dir" 2>/dev/null)"
eq "changed_files on a non-repo prints nothing" "" "$CH2"
printf 'x\n' > "$REPOX/$(printf 'weird\033name')"
CH3="$(changed_files "$REPOX")"
eq "changed_files output holds no escape character" "0" "$(printf '%s' "$CH3" | LC_ALL=C grep -c "$(printf '\033')")"

# ---- the whole flow in a sandbox copy (fake preflight and fake run scripts) ---------------------------------------------------
SBN=0
mk_sandbox() { # mk_sandbox -> sets SB
  SBN=$((SBN + 1))
  SB="$TMP/sb$SBN"
  mkdir -p "$SB/spike/lib" "$SB/spike/claude" "$SB/spike/codex" "$SB/spike/normalize" "$SB/compliance" "$SB/bin" "$SB/fast" "$SB/tmp" "$SB/home"
  cp "$SPIKE/lib/common.sh" "$SB/spike/lib/common.sh"
  cp "$SPIKE/lib/runner.pl" "$SB/spike/lib/runner.pl"
  cp "$SPIKE/normalize/claude.jq" "$SPIKE/normalize/codex.jq" "$SB/spike/normalize/"
  cp "$REPO_TOP/compliance/denylist.txt" "$SB/compliance/denylist.txt"
  # TEST DOUBLE: the sandbox copy of the library has its live gate turned into a no-op, so the flow can run without the test ever
  # setting the live opt-in. The only run scripts in the sandbox are the fakes below.
  printf '\nspike_require_live() { :; }\n' >> "$SB/spike/lib/common.sh"
  cp "$RUN" "$SB/spike/run-both.sh"
  printf 'captures/\n' > "$SB/spike/.gitignore"
  git -C "$SB" init -q
  cp "$FAKEBIN/claude" "$SB/bin/claude"
  cp "$FAKEBIN/codex" "$SB/bin/codex"
  printf '#!/bin/bash\necho "sleep $*" >> "$FAKE_LOG"\nexit 0\n' > "$SB/fast/sleep"
  printf '#!/bin/bash\ncase "$*" in *%%Y%%m%%dT*) echo 20260101T000000Z ;; *) exec /bin/date "$@" ;; esac\n' > "$SB/fast/date"
  cat > "$SB/spike/preflight.sh" <<'EOF'
#!/bin/bash
printf 'preflight %s\n' "$(date +%s)" >> "$FAKE_LOG"
printf 'fake preflight report\n'
exit "${FAKE_PRE_RC:-0}"
EOF
  cat > "$SB/spike/claude/run.sh" <<'EOF'
#!/bin/bash
set -u
HERE="$(cd -P "${BASH_SOURCE[0]%/*}" && pwd -P)"
. "$HERE/../lib/common.sh"
printf 'claude start %s\n' "$(date +%s)" >> "$FAKE_LOG"
printf 'claude root %s\n' "${SPIKE_CAPTURES_ROOT:-none}" >> "$FAKE_LOG"
REPO="$(spike_scratch_repo)"
WT="$(spike_worktree_add "$REPO" claude-1)"
CAP="$(spike_capture_dir claude)"
CAP="${CAP%/}"
printf '%s\n' "$WT" > "$CAP/worktree.path"
cp "$FAKE_CLAUDE_RAW" "$CAP/raw.jsonl"
case "${FAKE_CLAUDE_HELLO:-ok}" in
  ok) printf 'hello from claude\n' > "$WT/hello.txt" ;;
  bad) printf 'hello from claude\nextra\n' > "$WT/hello.txt" ;;
esac
[ "${FAKE_CLAUDE_TWOCAPS:-}" = "1" ] && mkdir "$SPIKE_CAPTURES_ROOT/claude/20990101T000000Z"
[ -n "${FAKE_CLAUDE_SIGNAL:-}" ] && kill -"$FAKE_CLAUDE_SIGNAL" "$PPID"
printf 'claude end %s\n' "$(date +%s)" >> "$FAKE_LOG"
exit "${FAKE_CLAUDE_RC:-0}"
EOF
  cat > "$SB/spike/codex/run.sh" <<'EOF'
#!/bin/bash
set -u
HERE="$(cd -P "${BASH_SOURCE[0]%/*}" && pwd -P)"
. "$HERE/../lib/common.sh"
printf 'codex start %s\n' "$(date +%s)" >> "$FAKE_LOG"
printf 'codex root %s\n' "${SPIKE_CAPTURES_ROOT:-none}" >> "$FAKE_LOG"
REPO="$(spike_scratch_repo)"
WT="$(spike_worktree_add "$REPO" codex-1)"
CAP="$(spike_capture_dir codex)"
CAP="${CAP%/}"
printf '%s\n' "$WT" > "$CAP/worktree.txt"
cp "$FAKE_CODEX_RAW" "$CAP/raw.jsonl"
case "${FAKE_CODEX_HELLO:-ok}" in
  ok) printf 'hello from codex\n' > "$WT/hello.txt" ;;
  bad) printf 'hello from codex\nextra\n' > "$WT/hello.txt" ;;
esac
printf 'codex end %s\n' "$(date +%s)" >> "$FAKE_LOG"
exit "${FAKE_CODEX_RC:-0}"
EOF
  chmod +x "$SB/spike/run-both.sh" "$SB/spike/preflight.sh" "$SB/spike/claude/run.sh" "$SB/spike/codex/run.sh" "$SB/fast/sleep" "$SB/fast/date"
  : > "$SB/log"
}
# run_sb <path-prefix> <env pairs without spaces> -- <args>: runs the sandbox copy, prints the exit status, output in $SB/out
run_sb() {
  local pfx="$1" pairs="$2"
  shift 3
  # shellcheck disable=SC2086
  env -i PATH="$pfx$SB/bin:/usr/bin:/bin" HOME="$SB/home" TMPDIR="$SB/tmp" USER=tester LOGNAME=tester FAKE_LOG="$SB/log" \
    FAKE_CLAUDE_RAW="$SPIKE/fixtures/claude/sample.jsonl" FAKE_CODEX_RAW="$SPIKE/fixtures/codex/sample.jsonl" $pairs \
    /bin/bash "$SB/spike/run-both.sh" "$@" > "$SB/out" 2> "$SB/err" < /dev/null
  echo $?
}
logcount() { grep -c "^$1" "$SB/log"; }
root_of() { ls -d "$SB/spike/captures/run-both"/*/ 2>/dev/null | head -n 1 | sed 's:/$::'; }
scratch_left() { ls -A "$SB/tmp/harness-spike" 2>/dev/null | wc -l | tr -d ' '; }

# A. both pass, real sleep: order, spacing of at least 5 s, one call each, table, JSON, cleanup
mk_sandbox
rc="$(run_sb "" "" --)"
eq "A: both PASS: exit 0" "0" "$rc"
OUT="$(cat "$SB/out")"
eq "A: claude run.sh called once" "1" "$(logcount 'claude start')"
eq "A: codex run.sh called once" "1" "$(logcount 'codex start')"
eq "A: preflight called once" "1" "$(logcount 'preflight')"
order="$(grep -oE '^(preflight|claude start|claude end|codex start|codex end)' "$SB/log" | tr '\n' ',')"
eq "A: order is preflight, claude start, claude end, codex start, codex end (never parallel)" "preflight,claude start,claude end,codex start,codex end," "$order"
ce="$(grep '^claude end' "$SB/log" | awk '{print $3}')"
cs="$(grep '^codex start' "$SB/log" | awk '{print $3}')"
if [ -n "$ce" ] && [ -n "$cs" ] && [ $((cs - ce)) -ge 5 ]; then ok; else bad "A: at least 5 s between the claude end and the codex start (got $((cs - ce)))"; fi
ROOTA="$(root_of)"
check "A: ROOT exists under spike/captures/run-both" test -d "$ROOTA"
eq "A: both run scripts got the same capture root, the fresh ROOT" "root $ROOTA,root $ROOTA," "$(grep -E '^(claude|codex) root' "$SB/log" | sed 's/^[a-z]* //' | tr '\n' ',')"
check "A: preflight.txt was written" test -s "$ROOTA/preflight.txt"
check "A: git ignores the run-both root in the sandbox" git -C "$SB" check-ignore -q -- "spike/captures/run-both/x"
check "A: claude.normalized.jsonl exists" test -s "$ROOTA/claude.normalized.jsonl"
check "A: codex.normalized.jsonl exists" test -s "$ROOTA/codex.normalized.jsonl"
check "A: the normalized claude file equals the golden output" cmp -s "$ROOTA/claude.normalized.jsonl" "$EXP/claude-sample.jsonl"
check "A: the normalized codex file equals the golden output" cmp -s "$ROOTA/codex.normalized.jsonl" "$EXP/codex-sample.jsonl"
JSONA="$(cat "$ROOTA/run-both.json")"
expect "A: run-both.json has two PASS rows" "$JSONA" '(.rows | length) == 2 and (.rows | map(.verdict) == ["PASS","PASS"])'
expect "A: run-both.json rows are claude then codex with redacted ids" "$JSONA" '(.rows | map(.provider) == ["claude","codex"]) and .rows[0].session == "1111..." and .rows[1].session == "0199..."'
expect "A: run-both.json lists hello.txt as the changed file" "$JSONA" '(.rows | map(.changed) == [["hello.txt"],["hello.txt"]])'
has "A: the table is printed" "$OUT" 'provider'
eq "A: the table has two PASS verdicts and the PASS summary line" "3" "$(printf '%s\n' "$OUT" | grep -c 'PASS')"
has "A: the capture location is printed" "$OUT" "$ROOTA"
has "A: the preflight report is shown" "$OUT" 'fake preflight report'
eq "A: scratch run dirs were removed" "0" "$(scratch_left)"
check "A: captures stay" test -d "$ROOTA/claude" -a -d "$ROOTA/codex"
check "A: the fake CLIs on the PATH were not started" test ! -e "$MARK_C" -a ! -e "$MARK_X"
check "A: no full session id in the output" test "$(grep -c '11111111-1111' "$SB/out")" = "0"

# B. --keep keeps the scratch run dirs
mk_sandbox
rc="$(run_sb "$SB/fast:" "" -- --keep)"
eq "B: --keep: exit 0" "0" "$rc"
eq "B: --keep leaves both scratch run dirs" "2" "$(scratch_left)"
eq "B: the wait is requested as sleep 5" "1" "$(grep -c '^sleep 5$' "$SB/log")"

# C. claude fails: codex still runs, exit 1
mk_sandbox
rc="$(run_sb "$SB/fast:" "FAKE_CLAUDE_RC=1 FAKE_CLAUDE_RAW=$EXP/claude-limits.jsonl" --)"
eq "C: claude FAIL: exit 1" "1" "$rc"
eq "C: codex still ran once after the claude failure" "1" "$(logcount 'codex start')"
eq "C: claude ran once (no retry)" "1" "$(logcount 'claude start')"
eq "C: the wait happened between them" "1" "$(grep -c '^sleep 5$' "$SB/log")"
ROOTC="$(root_of)"
expect "C: claude FAIL and codex PASS in run-both.json" "$(cat "$ROOTC/run-both.json")" '(.rows | map(.verdict) == ["FAIL","PASS"])'
has "C: the table shows the FAIL note" "$(cat "$SB/out")" 'note: claude FAIL:'

# D. codex fails: exit 1
mk_sandbox
rc="$(run_sb "$SB/fast:" "FAKE_CODEX_RC=1" --)"
eq "D: codex run.sh exit 1: exit 1" "1" "$rc"
expect "D: verdicts PASS then FAIL" "$(cat "$(root_of)/run-both.json")" '(.rows | map(.verdict) == ["PASS","FAIL"])'

# E. hello.txt not exact: FAIL although run.sh exit 0; missing hello: FAIL
mk_sandbox
rc="$(run_sb "$SB/fast:" "FAKE_CLAUDE_HELLO=bad FAKE_CODEX_HELLO=none" --)"
eq "E: bad and missing hello.txt: exit 1" "1" "$rc"
expect "E: both rows FAIL with hello_ok false" "$(cat "$(root_of)/run-both.json")" '(.rows | map(.verdict) == ["FAIL","FAIL"]) and (.rows | map(.hello_ok) == [false,false])'

# F. two capture dirs for one CLI: FAIL for that CLI
mk_sandbox
rc="$(run_sb "$SB/fast:" "FAKE_CLAUDE_TWOCAPS=1" --)"
eq "F: two claude capture dirs: exit 1" "1" "$rc"
expect "F: claude FAIL, codex PASS" "$(cat "$(root_of)/run-both.json")" '(.rows | map(.verdict) == ["FAIL","PASS"])'

# G. preflight fails: nothing else starts
mk_sandbox
rc="$(run_sb "$SB/fast:" "FAKE_PRE_RC=1" --)"
eq "G: preflight non-zero: exit 1" "1" "$rc"
eq "G: claude not started" "0" "$(logcount 'claude start')"
eq "G: codex not started" "0" "$(logcount 'codex start')"
eq "G: no sleep" "0" "$(grep -c '^sleep' "$SB/log")"

# H. a signal during the claude run: codex never starts, exit 143 / 130 / 129, scratch cleaned up
for pair in TERM:143 INT:130 HUP:129; do
  sig="${pair%%:*}"
  want="${pair##*:}"
  mk_sandbox
  rc="$(run_sb "$SB/fast:" "FAKE_CLAUDE_SIGNAL=$sig" --)"
  eq "H: SIG$sig during the claude run: exit $want" "$want" "$rc"
  eq "H: SIG$sig: codex not started" "0" "$(logcount 'codex start')"
  eq "H: SIG$sig: no sleep" "0" "$(grep -c '^sleep' "$SB/log")"
  eq "H: SIG$sig: the claude run was not repeated" "1" "$(logcount 'claude start')"
  eq "H: SIG$sig: scratch run dir removed" "0" "$(scratch_left)"
  check "H: SIG$sig: no run-both.json was written" test ! -e "$(root_of)/run-both.json"
done

# I. an existing ROOT is refused (fixed date), nothing runs
mk_sandbox
mkdir -p "$SB/spike/captures/run-both/20260101T000000Z"
rc="$(run_sb "$SB/fast:" "" --)"
eq "I: an existing ROOT: exit 1" "1" "$rc"
eq "I: nothing was started" "0" "$(logcount 'preflight')"

# J. the sandbox copy itself: dry-run and unknown args work there too, and the copy is byte-identical to the real script
mk_sandbox
cmp -s "$RUN" "$SB/spike/run-both.sh" && ok || bad "J: the sandbox copy equals the real script"
eq "J: dry-run in the sandbox exits 0 and starts nothing" "0" "$(run_sb "$SB/fast:" "" -- --dry-run)"
eq "J: dry-run wrote no log line" "0" "$(wc -l < "$SB/log" | tr -d ' ')"
check "J: dry-run created no captures directory" test ! -e "$SB/spike/captures"

# ---- the live gate in the real library is still intact (the sandbox override is only in the sandbox copy) -----------------------
check "the real lib/common.sh was not changed by the sandbox override" test "$(grep -c 'spike_require_live() { :; }' "$SPIKE/lib/common.sh")" = "0"

# ---- result ------------------------------------------------------------------------------------------------------------------
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
