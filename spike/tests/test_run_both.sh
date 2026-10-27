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

sha() { # sha <file>: the sha256 of a file (sha256sum, or shasum on macOS)
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1"; else shasum -a 256 < "$1"; fi | cut -d' ' -f1
}
# the real library must be byte-for-byte the same after the suite as before it (the sandbox override lives in a copy)
LIB_SHA0="$(sha "$SPIKE/lib/common.sh")"

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
check "no -c, --config or --profile option outside jq lines" test "$(code_lines "$RUN" | grep -vE 'jq |JQ|wc ' | grep -cE '(^|[[:space:]])(-c|--config|--profile)([[:space:]=]|$)')" = "0"
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
check "the normalized files are written under noclobber" grep -q 'set -C; "\$JQ"' "$RUN"
check "git runs with a closed environment and fsmonitor forced off" grep -q 'GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false' "$RUN"
check "git runs with no global config (GIT_CONFIG_GLOBAL=/dev/null) and no system config" test "$(grep -c 'GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null' "$RUN")" -ge 2
check "git status runs with submodules ignored and the git dirs pinned" test "$(grep -c -e '--ignore-submodules=all' -e 'GIT_DIR="\$SG_GD" GIT_COMMON_DIR="\$SG_COMMON"' "$RUN")" -ge 2
check "the wait is /bin/sleep (no PATH lookup of sleep)" test "$(code_lines "$RUN" | grep -c '^/bin/sleep "\$GAP_SECS"$')" = "1" -a "$(code_lines "$RUN" | grep -vE '^[[:space:]]*printf' | grep -cE '(^|[^/A-Za-z_])sleep ')" = "0"
check "every jq call on capture data goes through the probe-checked \$JQ" test "$(code_lines "$RUN" | grep -E '(^|[^A-Za-z_"$/-])jq ' | grep -vcE "printf|spike_err")" = "0"
FILTER_TAIL="2>&1 | ( trap '' INT; printable )"
check "the run scripts' output is filtered with printable and their status taken from PIPESTATUS" test "$(code_lines "$RUN" | grep -E '/(claude|codex)/run.sh" < /dev/null ' | grep -cF -- "$FILTER_TAIL")" = "2" -a "$(code_lines "$RUN" | grep -c 'PIPESTATUS\[0\]')" = "2"
check "the output filter after each run.sh ignores SIGINT (a Ctrl-C must not kill the pipe under the run script)" test "$(code_lines "$RUN" | grep -cF -- "| ( trap '' INT; printable )")" = "2" -a "$(code_lines "$RUN" | grep -cE '(claude|codex)/run.sh.*\| printable$')" = "0"
# no [a-z]-style range in a case pattern (bash 3.2 orders ranges by the locale's collation). A bracket holding a dash between two
# characters is a range; POSIX classes are fine. The pattern text is what comes before the first ) of a case line.
has_range() { printf '%s\n' "$1" | grep -qE '\[[^]]*[^][ :-]-[^]]'; }
check "range detector: [!0-9] is a range" has_range '*[!0-9]*'
check "range detector: [a-z] is a range" has_range '[a-z]'
check "range detector: [A-Za-z0-9._-] holds ranges" has_range '*[!A-Za-z0-9._-]*'
check "range detector: a POSIX class is not a range" test "$(has_range '*[[:cntrl:]]*'; echo $?)" = "1"
check "range detector: an explicit digit list is not a range" test "$(has_range '*[!0123456789]*'; echo $?)" = "1"
check "range detector: a trailing dash is not a range" test "$(has_range '[._-]'; echo $?)" = "1"
CASE_PATS="$(code_lines "$RUN" | grep -E ';;|(^|[^[:alnum:]_])case .* in( |$)' | sed 's/).*//')"
check "the case patterns were found (at least 15 lines)" test "$(printf '%s\n' "$CASE_PATS" | wc -l | tr -d ' ')" -ge 15
check "no [a-z]-style range in any case pattern of run-both.sh" test "$(printf '%s\n' "$CASE_PATS" | grep -cE '\[[^]]*[^][ :-]-[^]]')" = "0"
check "the digit tests use an explicit digit list" test "$(code_lines "$RUN" | grep -cF -- '[!0123456789]')" = "4"
check "process_cli checks the worktree path before it reads hello.txt or lists changed files" test "$(awk '/^process_cli\(\)/ {f=1} f && /wt_path_ok "\$wt"/ && !a {a=NR} f && /hello_ok "\$wt"/ && !b {b=NR} f && /changed_files "\$wt"/ && !c {c=NR} END {exit !(a && b && c && a < b && b < c)}' "$RUN"; echo $?)" = "0"
check "cleanup_one checks the worktree path before the library cleanup" test "$(awk '/^cleanup_one\(\)/ {f=1} f && /wt_path_ok/ && !a {a=NR} f && /spike_cleanup/ && !b {b=NR} END {exit !(a && b && a < b)}' "$RUN"; echo $?)" = "0"
check "run_dir_of checks the run dir name for a slash" test "$(awk '/^run_dir_of\(\)/ {f=1} f && /\*\/\*\) return 1/ {n++} END {print n + 0}' "$RUN")" = "1"
check "the normalizer's exit status is kept (no || after the noclobber subshell)" test "$(code_lines "$RUN" | grep -c 'nrc=\$?')" = "1"

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
# the script resolves its jq through the probe path; the extracted functions use the same variable
JQ="$(spike_tool_path jq)"
check "the probe path finds a native jq" test -n "$JQ"
# shellcheck disable=SC1090
. "$FUNCS"
for fn in printable safe_input read_wt hello_ok git_new_enough config_allowed config_absent_or_allowed wt_path_ok scratch_repo_ok changed_files build_row fail_row valid_row table; do
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
# the flags force FAIL with a fixed reason each, even on a stream that is otherwise a PASS
R="$(build_row claude 0 yes "" "$EXP/claude-sample.jsonl" cfg)"
expect "flag cfg: FAIL with the fixed reason scratch repo config changed" "$R" '.verdict == "FAIL" and .reasons == ["scratch repo config changed"]'
R="$(build_row claude 0 yes "" "$EXP/claude-sample.jsonl" " norm")"
expect "flag norm: FAIL with the fixed reason normalizer failed" "$R" '.verdict == "FAIL" and .reasons == ["normalizer failed"]'
R="$(build_row claude 0 yes "" "$EXP/claude-sample.jsonl" "cfg norm")"
expect "flags cfg and norm: both fixed reasons" "$R" '.verdict == "FAIL" and .reasons == ["scratch repo config changed","normalizer failed"]'
R="$(build_row claude 0 yes "" "$EXP/claude-sample.jsonl" wt)"
expect "flag wt: FAIL with the fixed reason worktree path refused" "$R" '.verdict == "FAIL" and .reasons == ["worktree path refused"]'
R="$(fail_row codex 7)"
expect "fail_row: FAIL, row could not be built, the real run exit kept, zero counts" "$R" '.verdict == "FAIL" and .provider == "codex" and .run_exit == 7 and .reasons == ["row could not be built"] and .session == "none"'
R="$(row claude 0 yes "" "$EXP/claude-sample.jsonl")"
eq "valid_row passes a good row through unchanged" "$R" "$(valid_row claude 0 "$R")"
expect "valid_row replaces an empty row by the fixed FAIL row" "$(valid_row claude 0 "")" '.verdict == "FAIL" and .reasons == ["row could not be built"]'
expect "valid_row replaces text that is not JSON" "$(valid_row codex 3 "oops {")" '.verdict == "FAIL" and .provider == "codex" and .run_exit == 3'
expect "valid_row replaces a row of the other provider" "$(valid_row codex 0 "$R")" '.verdict == "FAIL" and .provider == "codex" and .reasons == ["row could not be built"]'
expect "valid_row replaces an object without a verdict" "$(valid_row claude 0 '{"provider":"claude"}')" '.verdict == "FAIL" and .reasons == ["row could not be built"]'

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

# -- wt_path_ok: the worktree path must be its own physical path and outside every CLI home (rule 4)
check "wt_path_ok accepts a physical directory under the scratch root" wt_path_ok "$WT1"
mkdir -p "$TMP/wt-other"
ln -s "$TMP/wt-other" "$WTROOT/run-test/repo-wt/wlink"
check "wt_path_ok refuses a path that is a symlink to another directory" test "$(wt_path_ok "$WTROOT/run-test/repo-wt/wlink"; echo $?)" = "1"
ln -s "$WTROOT/run-test/repo-wt" "$WTROOT/run-test/rwlink"
check "wt_path_ok refuses a path with a symlink in a middle component" test "$(wt_path_ok "$WTROOT/run-test/rwlink/w1"; echo $?)" = "1"
mkdir -p "$CLIHOME/sub"
check "wt_path_ok refuses a directory inside a CLI home" test "$(wt_path_ok "$CLIHOME/sub"; echo $?)" = "1"
check "wt_path_ok refuses an empty path" test "$(wt_path_ok ""; echo $?)" = "1"

# -- changed_files and the config allowlist, on real scratch repos made by the library (rule 4). The scratch repo's config sits where
# the CLI could write it: git must not run on it at all unless every key is one the setup writes (an allowlist, not a blocklist).
GIT_BIN="$(spike_tool_path git)"
check "the probe path finds a native git" test -n "$GIT_BIN"
tg() { "$GIT_BIN" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
mk_wt() { # mk_wt -> WREPO and WWT: a scratch repo with the worktree claude-1, exactly as the run scripts create them
  WREPO="$(spike_scratch_repo)"
  WWT="$(spike_worktree_add "$WREPO" claude-1)"
}
MARKF="$TMP/marker"
printf '#!/bin/bash\necho ran > "%s"\ncat\n' "$MARKF" > "$TMP/mark.sh"
printf '#!/bin/bash\necho ran > "%s"\nprintf "\\0"\n' "$MARKF" > "$TMP/fsm.sh"
chmod +x "$TMP/mark.sh" "$TMP/fsm.sh"
CANARY_CFG="$TMP/canary.cfg"
printf '%s\n' "$CANARY" > "$CANARY_CFG"

# the allowlist, key by key
for kv in core.repositoryformatversion=0 core.filemode=true core.bare=false core.logallrefupdates=true core.ignorecase=true core.precomposeunicode=true \
  extensions.objectformat=sha256 extensions.refstorage=reftable; do
  : > "$TMP/cfg-one"
  tg config --file "$TMP/cfg-one" "${kv%%=*}" "${kv#*=}"
  check "config_allowed accepts ${kv%%=*}" config_allowed "$GIT_BIN" "$TMP/cfg-one"
done
for kv in filter.x.clean=a filter.x.process=a filter.x.smudge=a include.path=/x includeIf.gitdir:/x/.path=/y core.worktree=/x core.fsmonitor=a \
  core.hooksPath=/x core.sshCommand=a core.pager=a core.attributesFile=/x core.excludesFile=/x extensions.worktreeConfig=true \
  alias.x=a diff.x.textconv=a foo.bar=1 core.foo=1 branch.main.remote=origin user.name=x extensions.foo=1 extensions.objectformat2=1 extensions.compatobjectformat=sha1; do
  : > "$TMP/cfg-one"
  tg config --file "$TMP/cfg-one" "${kv%%=*}" "${kv#*=}"
  check "config_allowed refuses ${kv%%=*}" test "$(config_allowed "$GIT_BIN" "$TMP/cfg-one" >/dev/null 2>&1; echo $?)" != "0"
done
: > "$TMP/cfg-one"
tg config --file "$TMP/cfg-one" core.bare false
tg config --file "$TMP/cfg-one" foo.bar 1
check "config_allowed refuses one unknown key among allowed ones" test "$(config_allowed "$GIT_BIN" "$TMP/cfg-one" >/dev/null 2>&1; echo $?)" != "0"
printf '[core\nbroken\n' > "$TMP/cfg-bad"
check "config_allowed refuses an unparsable file" test "$(config_allowed "$GIT_BIN" "$TMP/cfg-bad" >/dev/null 2>&1; echo $?)" != "0"
check "config_allowed refuses a missing file" test "$(config_allowed "$GIT_BIN" "$TMP/cfg-missing" >/dev/null 2>&1; echo $?)" != "0"
ln -s "$TMP/cfg-one" "$TMP/cfg-link"
check "config_allowed refuses a symlink" test "$(config_allowed "$GIT_BIN" "$TMP/cfg-link" >/dev/null 2>&1; echo $?)" != "0"
check "config_absent_or_allowed accepts a missing file" config_absent_or_allowed "$GIT_BIN" "$TMP/cfg-missing"
check "config_absent_or_allowed refuses a dangling symlink" test "$(ln -s "$TMP/nowhere" "$TMP/cfg-dangling"; config_absent_or_allowed "$GIT_BIN" "$TMP/cfg-dangling" >/dev/null 2>&1; echo $?)" != "0"

# the two extensions a user's global init.* settings can make `git init` write: a real sha256 init writes extensions.objectformat
env GIT_DEFAULT_HASH=sha256 "$GIT_BIN" init -q -b main "$TMP/sha-repo" > /dev/null 2>&1
if "$GIT_BIN" config --file "$TMP/sha-repo/.git/config" --name-only --list 2>/dev/null | grep -qx 'extensions.objectformat'; then
  check "config_allowed accepts the config a real sha256 git init writes" config_allowed "$GIT_BIN" "$TMP/sha-repo/.git/config"
else
  ok # this git cannot write a sha256 repo; the per-key checks above cover the key
fi
# rule 4: the config file is checked with safe_input BEFORE git reads it. The content below is allowlisted, so only the file checks refuse it.
mk_wt
ln "$WREPO/.git/config" "$TMP/cfg-hardlink"
check "config_allowed refuses a hard-linked config (allowlisted content)" test "$(config_allowed "$GIT_BIN" "$WREPO/.git/config" >/dev/null 2>&1; echo $?)" != "0"
check "changed_files refuses a hard-linked repo config: status 3, no git run" test "$(changed_files "$WWT" 2>&1; echo "rc=$?")" = "(not listed: repo config changed)
rc=3"
rm -f "$TMP/cfg-hardlink"
check "config_allowed accepts the same config once the extra link is gone" config_allowed "$GIT_BIN" "$WREPO/.git/config"
cp "$WREPO/.git/config" "$CLIHOME/gitcfg"
check "config_allowed refuses a config file inside a CLI home (allowlisted content)" test "$(config_allowed "$GIT_BIN" "$CLIHOME/gitcfg" >/dev/null 2>&1; echo $?)" != "0"
mk_wt
printf '[core]\n\tbare = false\n' > "$WREPO/.git/worktrees/claude-1/config.worktree"
ln "$WREPO/.git/worktrees/claude-1/config.worktree" "$TMP/cfgwt-hardlink"
CH="$(changed_files "$WWT" 2>&1)"
eq "a hard-linked config.worktree is refused: status 3" "3" "$?"
rm -f "$TMP/cfgwt-hardlink"

# an untouched scratch config lists the changed files (positive)
mk_wt
check "a fresh scratch repo config passes the allowlist (what git init and worktree add write)" config_allowed "$GIT_BIN" "$WREPO/.git/config"
printf 'hello\n' > "$WWT/hello.txt"
printf 'change\n' >> "$WWT/README.md"
CH="$(changed_files "$WWT")"
CRC=$?
eq "changed_files on an untouched scratch config: status 0" "0" "$CRC"
has "changed_files lists the untracked file" "$CH" 'hello.txt'
has "changed_files lists the modified file" "$CH" 'README.md'
lacks "changed_files lists no marker text on an untouched config" "$CH" 'not listed'
printf 'x\n' > "$WWT/$(printf 'weird\033name')"
CH3="$(changed_files "$WWT")"
eq "changed_files output holds no escape character" "0" "$(printf '%s' "$CH3" | LC_ALL=C grep -c "$(printf '\033')")"
has "changed_files still lists the file whose name had an escape character" "$CH3" 'weird'
CH2="$(changed_files "$TMP/not-a-repo-dir" 2>/dev/null)"
CRC=$?
eq "changed_files on a path that is not a scratch worktree: not listed, layout" "(not listed: unexpected worktree layout)" "$CH2"
eq "changed_files on a path that is not a scratch worktree: status 0 (not a FAIL by itself)" "0" "$CRC"
CH2="$(changed_files "$WTROOT/run-test/repo-wt/w1" 2>/dev/null)"
CRC=$?
eq "changed_files on a scratch-shaped path with no repo: refused as a changed config" "(not listed: repo config changed)" "$CH2"
eq "changed_files on a scratch-shaped path with no repo: status 3" "3" "$CRC"

# hostile config: each case must leave the marker absent, print the fixed marker text and return 3
hostile() { # hostile <name> <key> <value>: a new scratch repo whose config the "CLI" edited
  mk_wt
  printf 'hello\n' > "$WWT/hello.txt"
  printf 'change\n' >> "$WWT/README.md"
  rm -f "$MARKF"
  tg config --file "$WREPO/.git/config" "$2" "$3"
  HOUT="$(changed_files "$WWT" 2>&1)"
  HRC=$?
  eq "hostile $1: status 3" "3" "$HRC"
  eq "hostile $1: prints the fixed text and nothing else" "(not listed: repo config changed)" "$HOUT"
  check "hostile $1: the marker file stays absent" test ! -e "$MARKF"
}
# core.fsmonitor and a hook: the control shows the fixture runs a program under a plain git status
mk_wt
printf 'hello\n' > "$WWT/hello.txt"
printf 'change\n' >> "$WWT/README.md"
rm -f "$MARKF"
tg config --file "$WREPO/.git/config" core.fsmonitor "$TMP/fsm.sh"
"$GIT_BIN" -C "$WWT" status --porcelain > /dev/null 2>&1
check "control: a plain git status DOES run the core.fsmonitor program of this fixture" test -e "$MARKF"
rm -f "$MARKF"
HOUT="$(changed_files "$WWT" 2>&1)"
HRC=$?
eq "hostile core.fsmonitor: status 3" "3" "$HRC"
check "hostile core.fsmonitor: the marker file stays absent" test ! -e "$MARKF"
hostile "core.hooksPath" core.hooksPath "$TMP/hooks"
hostile "unknown harmless key foo.bar (the allowlist, not a blocklist)" foo.bar 1
hostile "include.path" include.path "$CANARY_CFG"
lacks "hostile include.path: the canary text is never printed" "$HOUT" "$CANARY"
hostile "core.worktree" core.worktree "$TMP/elsewhere"
hostile "core.sshCommand" core.sshCommand "$TMP/mark.sh"
hostile "extensions.worktreeConfig" extensions.worktreeConfig true

# filter drivers: a same-size change to a tracked file whose .gitattributes sets filter=x makes git run the driver to compare
filter_fixture() { # filter_fixture <key>
  mk_wt
  printf 'aaaa\n' > "$WWT/f.txt"
  touch -t 202001010000 "$WWT/f.txt" # an old mtime: the later rewrite is always stat-dirty, never within the same timestamp tick
  printf 'f.txt filter=x\n' > "$WWT/.gitattributes"
  tg -C "$WWT" add f.txt .gitattributes
  tg -C "$WWT" commit -q -m f
  printf 'bbbb\n' > "$WWT/f.txt"
  rm -f "$MARKF"
  tg config --file "$WREPO/.git/config" "$1" "$TMP/mark.sh"
}
filter_fixture filter.x.clean
"$GIT_BIN" -C "$WWT" status --porcelain > /dev/null 2>&1
check "control: a plain git status DOES run filter.x.clean on the stat-dirty tracked file" test -e "$MARKF"
rm -f "$MARKF"
HOUT="$(changed_files "$WWT" 2>&1)"
HRC=$?
eq "hostile filter.x.clean: status 3" "3" "$HRC"
eq "hostile filter.x.clean: prints the fixed text" "(not listed: repo config changed)" "$HOUT"
check "hostile filter.x.clean: the marker file stays absent" test ! -e "$MARKF"
filter_fixture filter.x.process
"$GIT_BIN" -C "$WWT" status --porcelain > /dev/null 2>&1
check "control: a plain git status DOES start filter.x.process" test -e "$MARKF"
rm -f "$MARKF"
HOUT="$(changed_files "$WWT" 2>&1)"
HRC=$?
eq "hostile filter.x.process: status 3" "3" "$HRC"
check "hostile filter.x.process: the marker file stays absent" test ! -e "$MARKF"

# config.worktree, a symlinked config, a replaced .git directory
mk_wt
printf '[foo]\n\tbar = 1\n' > "$WREPO/.git/worktrees/claude-1/config.worktree"
HOUT="$(changed_files "$WWT" 2>&1)"
eq "hostile config.worktree with an unknown key: status 3" "3" "$?"
eq "hostile config.worktree: fixed text" "(not listed: repo config changed)" "$HOUT"
mk_wt
printf '[core]\n\tbare = false\n' > "$WREPO/.git/worktrees/claude-1/config.worktree"
HOUT="$(changed_files "$WWT" 2>&1)"
eq "a config.worktree holding only allowed keys is accepted" "0" "$?"
mk_wt
cp "$WREPO/.git/config" "$TMP/real-config"
rm -f "$WREPO/.git/config"
ln -s "$TMP/real-config" "$WREPO/.git/config"
HOUT="$(changed_files "$WWT" 2>&1)"
eq "a symlinked repo config is refused: status 3" "3" "$?"
mk_wt
mv "$WREPO/.git" "$WREPO/.git-moved"
ln -s "$WREPO/.git-moved" "$WREPO/.git"
HOUT="$(changed_files "$WWT" 2>&1)"
eq "a .git directory replaced by a symlink is refused: status 3" "3" "$?"

# commondir pinned: the worktree entry's commondir file must be a safe regular file holding exactly ../..
mk_wt
CD="$WREPO/.git/worktrees/claude-1/commondir"
scratch_repo_ok "$GIT_BIN" "$WWT"
eq "scratch_repo_ok accepts the commondir git wrote (../.. and a newline)" "0" "$?"
printf '../..' > "$CD"
scratch_repo_ok "$GIT_BIN" "$WWT"
eq "scratch_repo_ok accepts ../.. without a trailing newline" "0" "$?"
EVILCD="$TMP/evil-cd-repo"
rm -rf "$EVILCD"
tg init -q -b main "$EVILCD"
printf '%s\n' "$EVILCD/.git" > "$CD"
scratch_repo_ok "$GIT_BIN" "$WWT"
eq "scratch_repo_ok refuses a commondir that points at another repo" "3" "$?"
CH="$(changed_files "$WWT" 2>&1)"
eq "changed_files with a redirected commondir: status 3" "3" "$?"
eq "changed_files with a redirected commondir: the fixed text and nothing else" "(not listed: repo config changed)" "$CH"
for cdv in '../../' '../..\n\n' '../.. ' '..' '../../..' '/etc' ''; do
  printf "$cdv" > "$CD"
  scratch_repo_ok "$GIT_BIN" "$WWT"
  eq "scratch_repo_ok refuses a commondir holding [$cdv]" "3" "$?"
done
rm -f "$CD"
scratch_repo_ok "$GIT_BIN" "$WWT"
eq "scratch_repo_ok refuses a missing commondir" "3" "$?"
printf '../..\n' > "$TMP/cd-target"
ln -s "$TMP/cd-target" "$CD"
scratch_repo_ok "$GIT_BIN" "$WWT"
eq "scratch_repo_ok refuses a symlinked commondir (right content)" "3" "$?"
rm -f "$CD"
printf '../..\n' > "$CD"
ln "$CD" "$TMP/cd-hard"
scratch_repo_ok "$GIT_BIN" "$WWT"
eq "scratch_repo_ok refuses a hard-linked commondir (right content)" "3" "$?"
rm -f "$TMP/cd-hard"

# the repo itself pinned: <run>/repo is not a symlink and the physical path of its .git is exactly <run>/repo/.git
mk_wt
V1REPO="$WREPO"
V1WT="$WWT"
mk_wt
mv "$V1REPO" "$(dirname "$V1REPO")/repo.real"
ln -s "$WREPO" "$V1REPO"
scratch_repo_ok "$GIT_BIN" "$V1WT"
eq "scratch_repo_ok refuses a repo that is a symlink to another repo (it has a worktrees/claude-1 entry and an allowlisted config)" "3" "$?"
{ "$GIT_BIN" -C "$WREPO" worktree list; find "$WREPO" | sort; } > "$TMP/other.before" 2>&1
CH="$(changed_files "$V1WT" 2>&1)"
eq "changed_files on a redirected repo: status 3" "3" "$?"
eq "changed_files on a redirected repo: the fixed text" "(not listed: repo config changed)" "$CH"
{ "$GIT_BIN" -C "$WREPO" worktree list; find "$WREPO" | sort; } > "$TMP/other.after" 2>&1
check "nothing in the other repo changed (worktree list and file listing)" cmp -s "$TMP/other.before" "$TMP/other.after"
mk_wt
RUN2="$(dirname "$WREPO")"
mv "$RUN2" "$RUN2.real"
ln -s "$RUN2.real" "$RUN2"
scratch_repo_ok "$GIT_BIN" "$WWT"
eq "scratch_repo_ok refuses a worktree path whose run dir is a symlink (physical path of .git differs)" "3" "$?"

# the worktree's own .git file is never followed. The "CLI" rewrites it to a COPY of the git dirs whose config defines a filter driver
# (the real config stays clean, so the allowlist passes); with the git dirs pinned from the path the copy is never read.
mk_wt
printf 'aaaa\n' > "$WWT/f.txt"
touch -t 202001010000 "$WWT/f.txt" # old mtime: the rewrite below is always stat-dirty
printf 'f.txt filter=x\n' > "$WWT/.gitattributes"
tg -C "$WWT" add f.txt .gitattributes
tg -C "$WWT" commit -q -m f
printf 'bbbb\n' > "$WWT/f.txt"
printf 'hello\n' > "$WWT/hello.txt"
EVIL="$TMP/evil-common"
rm -rf "$EVIL"
cp -R "$WREPO/.git" "$EVIL"
tg config --file "$EVIL/config" filter.x.clean "$TMP/mark.sh"
printf 'gitdir: %s\n' "$EVIL/worktrees/claude-1" > "$WWT/.git"
rm -f "$MARKF"
"$GIT_BIN" -C "$WWT" status --porcelain > /dev/null 2>&1
check "control: a plain git status follows the rewritten .git file and DOES run the copy's filter" test -e "$MARKF"
rm -f "$MARKF"
CH="$(changed_files "$WWT" 2>&1)"
CRC=$?
eq "a rewritten .git file is not followed: status 0" "0" "$CRC"
has "a rewritten .git file is not followed: the real worktree is still listed" "$CH" 'hello.txt'
check "a rewritten .git file is not followed: the marker file stays absent" test ! -e "$MARKF"

# a nested repository (what a submodule is) whose own config defines a filter driver is not entered: status ignores submodules
mk_wt
mkdir -p "$WWT/sub"
tg init -q -b main "$WWT/sub"
printf 'aaaa\n' > "$WWT/sub/f.txt"
touch -t 202001010000 "$WWT/sub/f.txt" # old mtime: the rewrite below is always stat-dirty
printf 'f.txt filter=x\n' > "$WWT/sub/.gitattributes"
tg -C "$WWT/sub" add f.txt .gitattributes
tg -C "$WWT/sub" commit -q -m s
tg -C "$WWT" add sub > /dev/null 2>&1
tg -C "$WWT" commit -q -m sub
printf 'bbbb\n' > "$WWT/sub/f.txt"
tg config --file "$WWT/sub/.git/config" filter.x.clean "$TMP/mark.sh"
rm -f "$MARKF"
"$GIT_BIN" -C "$WWT" status --porcelain > /dev/null 2>&1
check "control: a plain git status DOES run the filter of the nested repository" test -e "$MARKF"
rm -f "$MARKF"
CH="$(changed_files "$WWT" 2>&1)"
check "a nested repository's filter driver is not started" test ! -e "$MARKF"

# git older than 2.32: nothing is listed, no git command beyond --version runs, and it is not a failure by itself
ORIG_STP="$(declare -f spike_tool_path)"
FAKEGIT="$TMP/fakegit"
FAKEGITLOG="$TMP/fakegit.log"
FAKEGITVER="$TMP/fakegit.ver"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nif [ "$1" = "--version" ]; then printf "git version %%s\\n" "$(cat "%s")"; exit 0; fi\nexit 9\n' "$FAKEGITLOG" "$FAKEGITVER" > "$FAKEGIT"
chmod +x "$FAKEGIT"
spike_tool_path() { if [ "$1" = "git" ]; then printf '%s\n' "$FAKEGIT"; else return 1; fi; }
mk_wt
for v in "2.30.1" "2.31.9" "1.9.0" "2.9.9" "nonsense" ""; do
  : > "$FAKEGITLOG"
  printf '%s' "$v" > "$FAKEGITVER"
  CH="$(changed_files "$WWT" 2>&1)"
  CRC=$?
  eq "git version [$v]: not listed, git too old" "(not listed: git too old)" "$CH"
  eq "git version [$v]: status 0 (not a FAIL by itself)" "0" "$CRC"
  eq "git version [$v]: only --version was run, nothing on the repo" "--version" "$(cat "$FAKEGITLOG")"
done
for v in "2.32.0" "2.39.5 (Apple Git-154)" "2.100.0" "3.0.0" "10.1.2"; do
  printf '%s' "$v" > "$FAKEGITVER"
  check "git_new_enough accepts [$v]" git_new_enough "$FAKEGIT"
done
eval "$ORIG_STP"
check "the real spike_tool_path is restored" test "$(spike_tool_path git)" = "$GIT_BIN"


# ---- the whole flow in a sandbox copy (fake preflight and fake run scripts) ---------------------------------------------------
SBN=0
mk_sandbox() { # mk_sandbox -> sets SB; the sandbox copy of run-both.sh is byte-identical to the real one
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
  # fast/ holds shims that only fast sandboxes put on the PATH: a date with a fixed stamp, and a tr that stalls ONCE after the codex fake
  # raised its flag (so a signal can land while the script normalizes). The sleep shim is not found through the PATH: mk_fast rewrites
  # the one /bin/sleep line of the sandbox copy.
  printf '#!/bin/bash\necho "sleep $*" >> "$FAKE_LOG"\n[ -n "${FAKE_SLEEP_SIGNAL:-}" ] && kill -"$FAKE_SLEEP_SIGNAL" "$PPID"\nexit 0\n' > "$SB/fast/sleep"
  printf '#!/bin/bash\ncase "$*" in *%%Y%%m%%dT*) echo 20260101T000000Z ;; *) exec /bin/date "$@" ;; esac\n' > "$SB/fast/date"
  printf '#!/bin/bash\nif [ -n "${FAKE_SLOWFLAG:-}" ] && [ -e "$FAKE_SLOWFLAG" ]; then rm -f "$FAKE_SLOWFLAG"; /bin/sleep 2; fi\nexec /usr/bin/tr "$@"\n' > "$SB/fast/tr"
  # a wc that, on its 2nd `wc -c` call (the second read_wt of the claude capture, after the path shape was accepted), swaps the claude
  # worktree for a symlink to $FAKE_WCSWAP_OTHER: the race the worktree path check closes
  cat > "$SB/fast/wc" <<'EOF'
#!/bin/bash
if [ -n "${FAKE_WCSWAP_OTHER:-}" ] && [ "${1:-}" = "-c" ]; then
  n="$(cat "$FAKE_LOG.wcn" 2>/dev/null)"
  n=$((${n:-0} + 1))
  echo "$n" > "$FAKE_LOG.wcn"
  if [ "$n" = "2" ]; then
    for w in "$TMPDIR"/harness-spike/run-*/repo-wt/claude-1; do
      mv "$w" "$w.real"
      ln -s "$FAKE_WCSWAP_OTHER" "$w"
      echo "swapped $w" >> "$FAKE_LOG"
    done
  fi
fi
exec /usr/bin/wc "$@"
EOF
  cat > "$SB/spike/preflight.sh" <<'EOF'
#!/bin/bash
printf 'preflight %s\n' "$(date +%s)" >> "$FAKE_LOG"
printf 'fake preflight report\n'
[ -n "${FAKE_PRE_SIGNAL:-}" ] && kill -"$FAKE_PRE_SIGNAL" "$PPID"
exit "${FAKE_PRE_RC:-0}"
EOF
  cat > "$SB/spike/claude/run.sh" <<'EOF'
#!/bin/bash
set -u
HERE="$(cd -P "${BASH_SOURCE[0]%/*}" && pwd -P)"
. "$HERE/../lib/common.sh"
printf 'claude start %s\n' "$(date +%s)" >> "$FAKE_LOG"
printf 'claude root %s\n' "${SPIKE_CAPTURES_ROOT:-none}" >> "$FAKE_LOG"
printf 'claude says hello\n'
printf 'claude escape \033[31mred\033[0m end\n'
printf 'claude stderr text\n' >&2
# a run that died before it made any scratch repo or capture directory
[ "${FAKE_CLAUDE_NOCAP:-}" = "1" ] && exit "${FAKE_CLAUDE_RC:-2}"
REPO="$(spike_scratch_repo)"
WT="$(spike_worktree_add "$REPO" claude-1)"
CAP="$(spike_capture_dir claude)"
CAP="${CAP%/}"
printf '%s\n' "$WT" > "$CAP/worktree.path"
printf '%s\n' "$(dirname "$REPO")" > "$CAP/rundir.path"
cp "$FAKE_CLAUDE_RAW" "$CAP/raw.jsonl"
case "${FAKE_CLAUDE_HELLO:-ok}" in
  ok) printf 'hello from claude\n' > "$WT/hello.txt" ;;
  bad) printf 'hello from claude\nextra\n' > "$WT/hello.txt" ;;
esac
[ "${FAKE_CLAUDE_TWOCAPS:-}" = "1" ] && mkdir "$SPIKE_CAPTURES_ROOT/claude/20990101T000000Z"
[ "${FAKE_CLAUDE_PRENORM:-}" = "1" ] && printf 'pre-existing\n' > "$SPIKE_CAPTURES_ROOT/claude.normalized.jsonl"
if [ "${FAKE_CLAUDE_FORGE:-}" = "1" ]; then
  # a second, complete and fresh scratch repo and worktree (a valid cleanup target) that is NOT this run's; the capture's rundir.path
  # still names the real run dir
  VREPO="$(spike_scratch_repo)"
  VWT="$(spike_worktree_add "$VREPO" claude-1)"
  printf 'keep\n' > "$VWT/sentinel"
  printf 'victim %s\n' "$VWT" >> "$FAKE_LOG"
  printf '%s\n' "$VWT" > "$CAP/worktree.path"
fi
if [ "${FAKE_CLAUDE_WTLINK:-}" = "1" ]; then
  mv "$CAP/worktree.path" "$CAP/real-wt.txt"
  ln -s "$CAP/real-wt.txt" "$CAP/worktree.path"
fi
# the "CLI" edits the scratch repo's config
CFG="$REPO/.git/config"
case "${FAKE_HOSTILE:-}" in
  filter | process)
    printf 'aaaa\n' > "$WT/f.txt"
    printf 'f.txt filter=x\n' > "$WT/.gitattributes"
    _spike_git -C "$WT" add f.txt .gitattributes
    _spike_git -C "$WT" commit -q -m f
    printf 'bbbb\n' > "$WT/f.txt"
    if [ "$FAKE_HOSTILE" = "filter" ]; then KEY="filter.x.clean"; else KEY="filter.x.process"; fi
    _spike_git config --file "$CFG" "$KEY" "$FAKE_MARK_SCRIPT"
    ;;
  include) _spike_git config --file "$CFG" include.path "$FAKE_CANARY_CFG" ;;
  worktree) _spike_git config --file "$CFG" core.worktree "$SPIKE_CAPTURES_ROOT/elsewhere" ;;
  foobar) _spike_git config --file "$CFG" foo.bar 1 ;;
esac
[ -n "${FAKE_CLAUDE_SIGNAL:-}" ] && kill -"$FAKE_CLAUDE_SIGNAL" "$PPID"
if [ "${FAKE_CLAUDE_CTRLC:-}" = "1" ]; then
  # a terminal Ctrl-C reaches every process of the foreground group: simulate it on run-both.sh and on the other members of its pipeline
  # (the output filter and its child), then keep writing. This script's own EXIT trap (like the real run.sh cleanup) must still run.
  trap 'printf "claude exit-trap\n"; printf "claude exit-trap\n" >> "$FAKE_LOG"' EXIT
  kill -INT "$PPID"
  for p in $(pgrep -P "$PPID"); do
    [ "$p" = "$$" ] && continue
    for c in $(pgrep -P "$p"); do kill -INT "$c" 2>/dev/null; done
    kill -INT "$p" 2>/dev/null
  done
  /bin/sleep 1
  printf 'claude after the interrupt\n'
fi
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
if [ "${FAKE_CODEX_FORGE:-}" = "old" ]; then
  # a complete scratch repo and worktree (a valid cleanup target) whose run dir is older than this run: a leftover from an earlier run
  VREPO="$(spike_scratch_repo)"
  VWT="$(spike_worktree_add "$VREPO" codex-1)"
  printf 'keep\n' > "$VWT/sentinel"
  touch -t 200001010000 "$(dirname "$VREPO")"
  printf 'victim %s\n' "$VWT" >> "$FAKE_LOG"
  printf '%s\n' "$VWT" > "$CAP/worktree.txt"
fi
if [ "${FAKE_CODEX_FORGE:-}" = "claude" ]; then
  # the other CLI's worktree path
  CW="$(cat "$SPIKE_CAPTURES_ROOT"/claude/*/worktree.path)"
  printf '%s\n' "$CW" > "$CAP/worktree.txt"
fi
if [ "${FAKE_CODEX_FORGE:-}" = "slash" ]; then
  # a complete, fresh scratch repo and worktree whose run dir has TWO path segments (run-a/bcdefgT123456Z-abcdef) that a case
  # pattern with ? wildcards would accept, because a ? also matches a slash
  V="$(spike_root)/run-a/bcdefgT123456Z-abcdef"
  mkdir -p "$V/repo" "$V/repo-wt"
  _spike_git -C "$V/repo" init -q -b main
  printf 'x\n' > "$V/repo/README.md"
  _spike_git -C "$V/repo" add README.md
  _spike_git -C "$V/repo" commit -q -m i
  _spike_git -C "$V/repo" worktree add -q -b spike/codex-1 "$V/repo-wt/codex-1" > /dev/null
  printf 'hello from codex\n' > "$V/repo-wt/codex-1/hello.txt"
  printf 'keep\n' > "$V/repo-wt/codex-1/sentinel"
  printf 'victim %s\n' "$V/repo-wt/codex-1" >> "$FAKE_LOG"
  printf '%s\n' "$V/repo-wt/codex-1" > "$CAP/worktree.txt"
fi
if [ "${FAKE_CODEX_REPOLINK:-}" = "1" ]; then
  # the "CLI" redirects <run>/repo to ANOTHER scratch repo that has an allowlisted config and a worktrees/codex-1 entry whose worktree
  # path lies in THIS run dir, so a git command run through the redirect (the library cleanup does that) would remove it
  OREPO="$(spike_scratch_repo)"
  mv "$WT" "$WT.moved"
  _spike_git -C "$OREPO" worktree add -q -b spike/codex-1 "$WT" > /dev/null
  printf 'hello from codex\n' > "$WT/hello.txt"
  mv "$REPO" "$REPO.real"
  ln -s "$OREPO" "$REPO"
  printf 'other %s\n' "$OREPO" >> "$FAKE_LOG"
  { git -C "$OREPO" worktree list; find "$OREPO" | sort; } > "$FAKE_LOG.other.before" 2>&1
fi
if [ "${FAKE_CODEX_LATE:-}" = "1" ]; then
  : > "$FAKE_SLOWFLAG"
  ( /bin/sleep 1; kill -TERM "$PPID" ) > /dev/null 2>&1 < /dev/null &
fi
[ -n "${FAKE_CODEX_SIGNAL:-}" ] && kill -"$FAKE_CODEX_SIGNAL" "$PPID"
printf 'codex end %s\n' "$(date +%s)" >> "$FAKE_LOG"
exit "${FAKE_CODEX_RC:-0}"
EOF
  chmod +x "$SB/spike/run-both.sh" "$SB/spike/preflight.sh" "$SB/spike/claude/run.sh" "$SB/spike/codex/run.sh" "$SB/fast/sleep" "$SB/fast/date" "$SB/fast/tr" "$SB/fast/wc"
  : > "$SB/log"
}
# mk_fast: a sandbox whose copy of run-both.sh has exactly ONE line rewritten, the /bin/sleep line, so the wait is a shim that only logs
mk_fast() {
  local pat rep
  mk_sandbox
  pat='^/bin/sleep "[$]GAP_SECS"$'
  rep="\"$SB/fast/sleep\" \"\$GAP_SECS\""
  sed "s#$pat#$rep#" "$RUN" > "$SB/run-both.fast"
  mv "$SB/run-both.fast" "$SB/spike/run-both.sh"
  chmod +x "$SB/spike/run-both.sh"
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
FASTP="fast:"

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
has "A: the claude run.sh stdout is shown" "$OUT" 'claude says hello'
has "A: the claude run.sh stderr is shown too (2>&1)" "$OUT" 'claude stderr text'
eq "A: run.sh output holds no escape character (printable)" "0" "$(LC_ALL=C grep -c "$(printf '\033')" "$SB/out")"
has "A: the escape text is kept without its escape characters" "$OUT" 'claude escape [31mred[0m end'
eq "A: scratch run dirs were removed" "0" "$(scratch_left)"
check "A: captures stay" test -d "$ROOTA/claude" -a -d "$ROOTA/codex"
check "A: the fake CLIs on the PATH were not started" test ! -e "$MARK_C" -a ! -e "$MARK_X"
check "A: no full session id in the output" test "$(grep -c '11111111-1111' "$SB/out")" = "0"
check "A: the sandbox copy is byte-identical to the real script" cmp -s "$RUN" "$SB/spike/run-both.sh"

# B. --keep keeps the scratch run dirs
mk_fast
rc="$(run_sb "$SB/$FASTP" "" -- --keep)"
eq "B: --keep: exit 0" "0" "$rc"
eq "B: --keep leaves both scratch run dirs" "2" "$(scratch_left)"
eq "B: the wait is requested as sleep 5" "1" "$(grep -c '^sleep 5$' "$SB/log")"

# C. claude fails: codex still runs, exit 1
mk_fast
rc="$(run_sb "$SB/$FASTP" "FAKE_CLAUDE_RC=1 FAKE_CLAUDE_RAW=$EXP/claude-limits.jsonl" --)"
eq "C: claude FAIL: exit 1" "1" "$rc"
eq "C: codex still ran once after the claude failure" "1" "$(logcount 'codex start')"
eq "C: claude ran once (no retry)" "1" "$(logcount 'claude start')"
eq "C: the wait happened between them" "1" "$(grep -c '^sleep 5$' "$SB/log")"
ROOTC="$(root_of)"
expect "C: claude FAIL and codex PASS in run-both.json" "$(cat "$ROOTC/run-both.json")" '(.rows | map(.verdict) == ["FAIL","PASS"])'
has "C: the table shows the FAIL note" "$(cat "$SB/out")" 'note: claude FAIL:'

# D. codex fails: exit 1
mk_fast
rc="$(run_sb "$SB/$FASTP" "FAKE_CODEX_RC=1" --)"
eq "D: codex run.sh exit 1: exit 1" "1" "$rc"
expect "D: verdicts PASS then FAIL" "$(cat "$(root_of)/run-both.json")" '(.rows | map(.verdict) == ["PASS","FAIL"])'

# E. hello.txt not exact: FAIL although run.sh exit 0; missing hello: FAIL
mk_fast
rc="$(run_sb "$SB/$FASTP" "FAKE_CLAUDE_HELLO=bad FAKE_CODEX_HELLO=none" --)"
eq "E: bad and missing hello.txt: exit 1" "1" "$rc"
expect "E: both rows FAIL with hello_ok false" "$(cat "$(root_of)/run-both.json")" '(.rows | map(.verdict) == ["FAIL","FAIL"]) and (.rows | map(.hello_ok) == [false,false])'

# F. two capture dirs for one CLI: FAIL for that CLI
mk_fast
rc="$(run_sb "$SB/$FASTP" "FAKE_CLAUDE_TWOCAPS=1" --)"
eq "F: two claude capture dirs: exit 1" "1" "$rc"
expect "F: claude FAIL, codex PASS" "$(cat "$(root_of)/run-both.json")" '(.rows | map(.verdict) == ["FAIL","PASS"])'

# G. preflight fails: nothing else starts
mk_fast
rc="$(run_sb "$SB/$FASTP" "FAKE_PRE_RC=1" --)"
eq "G: preflight non-zero: exit 1" "1" "$rc"
eq "G: claude not started" "0" "$(logcount 'claude start')"
eq "G: codex not started" "0" "$(logcount 'codex start')"
eq "G: no sleep" "0" "$(grep -c '^sleep' "$SB/log")"

# G2. a signal during preflight: exit with the signal's code (not 1), even if preflight itself failed; nothing else starts
for pair in TERM:143 INT:130 HUP:129; do
  sig="${pair%%:*}"
  want="${pair##*:}"
  for prc in 0 1; do
    mk_fast
    rc="$(run_sb "$SB/$FASTP" "FAKE_PRE_SIGNAL=$sig FAKE_PRE_RC=$prc" --)"
    eq "G2: SIG$sig during preflight (preflight exit $prc): exit $want" "$want" "$rc"
    eq "G2: SIG$sig (preflight exit $prc): claude not started" "0" "$(logcount 'claude start')"
    eq "G2: SIG$sig (preflight exit $prc): codex not started and no sleep" "00" "$(logcount 'codex start')$(grep -c '^sleep' "$SB/log")"
  done
done

# H. a signal during the claude run: codex never starts, exit 143 / 130 / 129, scratch cleaned up
for pair in TERM:143 INT:130 HUP:129; do
  sig="${pair%%:*}"
  want="${pair##*:}"
  mk_fast
  rc="$(run_sb "$SB/$FASTP" "FAKE_CLAUDE_SIGNAL=$sig" --)"
  eq "H: SIG$sig during the claude run: exit $want" "$want" "$rc"
  eq "H: SIG$sig: codex not started" "0" "$(logcount 'codex start')"
  eq "H: SIG$sig: no sleep" "0" "$(grep -c '^sleep' "$SB/log")"
  eq "H: SIG$sig: the claude run was not repeated" "1" "$(logcount 'claude start')"
  eq "H: SIG$sig: scratch run dir removed" "0" "$(scratch_left)"
  check "H: SIG$sig: no run-both.json was written" test ! -e "$(root_of)/run-both.json"
done

# H2. a signal during the 5 s gap: the sleep returns, codex never starts, cleanup runs, exit with the signal's code
for pair in TERM:143 INT:130 HUP:129; do
  sig="${pair%%:*}"
  want="${pair##*:}"
  mk_fast
  rc="$(run_sb "$SB/$FASTP" "FAKE_SLEEP_SIGNAL=$sig" --)"
  eq "H2: SIG$sig during the gap: exit $want" "$want" "$rc"
  eq "H2: SIG$sig during the gap: codex never started" "0" "$(logcount 'codex start')"
  eq "H2: SIG$sig during the gap: claude ran once, the wait once" "11" "$(logcount 'claude start')$(grep -c '^sleep 5$' "$SB/log")"
  eq "H2: SIG$sig during the gap: scratch cleanup ran" "0" "$(scratch_left)"
  check "H2: SIG$sig during the gap: no run-both.json" test ! -e "$(root_of)/run-both.json"
done

# H3. a signal during the codex run: codex is not repeated, cleanup of both scratch dirs runs, exit with the signal's code
for pair in TERM:143 INT:130 HUP:129; do
  sig="${pair%%:*}"
  want="${pair##*:}"
  mk_fast
  rc="$(run_sb "$SB/$FASTP" "FAKE_CODEX_SIGNAL=$sig" --)"
  eq "H3: SIG$sig during the codex run: exit $want" "$want" "$rc"
  eq "H3: SIG$sig during the codex run: codex ran once (not repeated), claude once" "11" "$(logcount 'codex start')$(logcount 'claude start')"
  eq "H3: SIG$sig during the codex run: both scratch dirs removed" "0" "$(scratch_left)"
  check "H3: SIG$sig during the codex run: no run-both.json" test ! -e "$(root_of)/run-both.json"
done

# H4. a signal while the script normalizes (the tr shim stalls once, the codex fake kills the script one second later): signal code, cleanup
mk_fast
rc="$(run_sb "$SB/$FASTP" "FAKE_CODEX_LATE=1 FAKE_SLOWFLAG=$SB/slowflag" --)"
eq "H4: SIGTERM after the codex run (during normalize or print): exit 143" "143" "$rc"
eq "H4: codex ran once" "1" "$(logcount 'codex start')"
eq "H4: scratch dirs removed" "0" "$(scratch_left)"
check "H4: the stall really happened (the flag was consumed by the tr shim)" test ! -e "$SB/slowflag"

# I. an existing ROOT is refused (fixed date), nothing runs
mk_fast
mkdir -p "$SB/spike/captures/run-both/20260101T000000Z"
rc="$(run_sb "$SB/$FASTP" "" --)"
eq "I: an existing ROOT: exit 1" "1" "$rc"
eq "I: nothing was started" "0" "$(logcount 'preflight')"

# J. the sandbox copy: byte-identical to the real script (plain sandbox); a fast sandbox differs by exactly the one /bin/sleep line
mk_sandbox
cmp -s "$RUN" "$SB/spike/run-both.sh" && ok || bad "J: the plain sandbox copy equals the real script"
mk_fast
eq "J: the fast sandbox copy differs from the real script by exactly two diff lines (one removed, one added)" "2" "$(diff "$RUN" "$SB/spike/run-both.sh" | grep -c '^[<>]')"
eq "J: the removed line is the /bin/sleep line" '< /bin/sleep "$GAP_SECS"' "$(diff "$RUN" "$SB/spike/run-both.sh" | grep '^<')"
eq "J: the added line is the shim line" "> \"$SB/fast/sleep\" \"\$GAP_SECS\"" "$(diff "$RUN" "$SB/spike/run-both.sh" | grep '^>')"
eq "J: dry-run in the sandbox exits 0 and starts nothing" "0" "$(run_sb "$SB/$FASTP" "" -- --dry-run)"
eq "J: dry-run wrote no log line" "0" "$(wc -l < "$SB/log" | tr -d ' ')"
check "J: dry-run created no captures directory" test ! -e "$SB/spike/captures"

# K. the normalizer's exit status is kept (blocker: a normalizer that prints the result and then fails must not PASS)
golden_prog() { # golden_prog <golden jsonl> <tail>: a jq program that emits every golden line, then <tail>
  printf '%s%s\n' "$(paste -sd, "$1")" "$2" > "$SB/spike/normalize/$3.jq"
}
mk_fast
golden_prog "$EXP/claude-sample.jsonl" "" claude
rc="$(run_sb "$SB/$FASTP" "" --)"
eq "K control: the same program without the error gives PASS and exit 0" "0" "$rc"
expect "K control: claude row PASS" "$(cat "$(root_of)/run-both.json")" '.rows[0].verdict == "PASS"'
mk_fast
golden_prog "$EXP/claude-sample.jsonl" ', error("boom")' claude
rc="$(run_sb "$SB/$FASTP" "" --)"
eq "K: claude normalizer prints the golden stream then errors: exit 1" "1" "$rc"
JK="$(cat "$(root_of)/run-both.json")"
expect "K: claude row FAIL with the fixed reason normalizer failed" "$JK" '.rows[0].verdict == "FAIL" and (.rows[0].reasons | index("normalizer failed")) != null'
expect "K: codex row is still PASS (one bad row does not hide the other)" "$JK" '.rows[1].verdict == "PASS"'
has "K: the jq error text is shown (filtered)" "$(cat "$SB/err")" 'boom'
check "K: at most 5 lines of the jq error text are shown" test "$(grep -c 'boom\|jq: error' "$SB/err")" -le 5
eq "K: the stderr text holds no escape character" "0" "$(LC_ALL=C grep -c "$(printf '\033')" "$SB/err")"
mk_fast
golden_prog "$EXP/codex-sample.jsonl" ', error("boom")' codex
rc="$(run_sb "$SB/$FASTP" "" --)"
eq "K: codex normalizer prints the golden stream then errors: exit 1" "1" "$rc"
JK="$(cat "$(root_of)/run-both.json")"
expect "K: codex row FAIL with the fixed reason normalizer failed" "$JK" '.rows[1].verdict == "FAIL" and (.rows[1].reasons | index("normalizer failed")) != null'
expect "K: claude row is still PASS" "$JK" '.rows[0].verdict == "PASS"'
# a pre-existing normalized file that noclobber refuses
mk_fast
rc="$(run_sb "$SB/$FASTP" "FAKE_CLAUDE_PRENORM=1" --)"
eq "K: a pre-existing normalized file: exit 1" "1" "$rc"
JK="$(cat "$(root_of)/run-both.json")"
expect "K: a pre-existing normalized file: claude FAIL with normalizer failed" "$JK" '.rows[0].verdict == "FAIL" and (.rows[0].reasons | index("normalizer failed")) != null'
eq "K: the pre-existing file was not overwritten" "pre-existing" "$(cat "$(root_of)/claude.normalized.jsonl")"
expect "K: the refused file's content is not used (zero counts)" "$JK" '.rows[0].session == "none" and .rows[0].turns == null'

# K2. one bad row does not hide the other: a normalizer that exits 0 but emits text the row builder cannot use
mk_fast
printf '"just a string"\n' > "$SB/spike/normalize/claude.jq"
rc="$(run_sb "$SB/$FASTP" "" --)"
eq "K2: claude row cannot be built: exit 1" "1" "$rc"
check "K2: run-both.json is still written" test -s "$(root_of)/run-both.json"
JK="$(cat "$(root_of)/run-both.json")"
expect "K2: claude row is the fixed FAIL row (row could not be built)" "$JK" '.rows[0].provider == "claude" and .rows[0].verdict == "FAIL" and .rows[0].reasons == ["row could not be built"] and .rows[0].run_exit == 0'
expect "K2: codex row is intact and PASS" "$JK" '.rows[1].provider == "codex" and .rows[1].verdict == "PASS"'
has "K2: the table is still printed with both providers" "$(cat "$SB/out")" 'codex'
has "K2: the claude FAIL note names the fixed reason" "$(cat "$SB/out")" 'note: claude FAIL: row could not be built'
mk_fast
printf '"just a string"\n' > "$SB/spike/normalize/codex.jq"
rc="$(run_sb "$SB/$FASTP" "" --)"
eq "K2: codex row cannot be built: exit 1" "1" "$rc"
expect "K2: claude PASS and codex fixed FAIL row" "$(cat "$(root_of)/run-both.json")" '.rows[0].verdict == "PASS" and .rows[1].reasons == ["row could not be built"]'

# L. a hostile scratch repo config (blocker): the "CLI" edits the config of the scratch repo; git must not run on it at all
hostile_flow() { # hostile_flow <label> <FAKE_HOSTILE value>
  mk_fast
  rm -f "$MARKF"
  rc="$(run_sb "$SB/$FASTP" "FAKE_HOSTILE=$2 FAKE_MARK_SCRIPT=$TMP/mark.sh FAKE_CANARY_CFG=$CANARY_CFG" -- --keep)"
  HJ="$(cat "$(root_of)/run-both.json" 2>/dev/null)"
  eq "L $1: exit 1" "1" "$rc"
  check "L $1: the marker file stays absent" test ! -e "$MARKF"
  expect "L $1: the claude row is FAIL with exactly the fixed reason" "$HJ" '.rows[0].verdict == "FAIL" and .rows[0].reasons == ["scratch repo config changed"]'
  expect "L $1: changed files show the fixed not-listed text" "$HJ" '.rows[0].changed == ["(not listed: repo config changed)"]'
  expect "L $1: the codex row is unaffected" "$HJ" '.rows[1].verdict == "PASS" and .rows[1].changed == ["hello.txt"]'
  has "L $1: the table notes the fixed reason" "$(cat "$SB/out")" 'note: claude FAIL: scratch repo config changed'
  eq "L $1: the canary text is never printed" "0" "$(cat "$SB/out" "$SB/err" "$(root_of)/run-both.json" | grep -c "$CANARY")"
}
hostile_flow "filter.x.clean" filter
HWT="$(head -n 1 "$(root_of)"/claude/*/worktree.path)"
rm -f "$MARKF"
"$GIT_BIN" -C "$HWT" status --porcelain > /dev/null 2>&1
check "L control: a plain git status in that very worktree DOES run the filter (the fixture is not vacuous)" test -e "$MARKF"
rm -f "$MARKF"
hostile_flow "filter.x.process" process
hostile_flow "include.path" include
hostile_flow "core.worktree" worktree
hostile_flow "unknown key foo.bar" foobar
# without --keep a repo whose config changed is not cleaned up with git either: it is left and reported
mk_fast
rc="$(run_sb "$SB/$FASTP" "FAKE_HOSTILE=foobar" --)"
eq "L: no --keep, changed config: exit 1" "1" "$rc"
eq "L: the claude scratch dir is left (no git ran on it, not even the library's cleanup), the codex one is removed" "1" "$(scratch_left)"
has "L: the leftover is reported" "$(cat "$SB/err")" 'claude: scratch run dir NOT removed'

# M. forged worktree paths in the capture files are never read for hello/status and never deleted
mk_fast
rc="$(run_sb "$SB/$FASTP" "FAKE_CLAUDE_FORGE=1" --)"
eq "M: forged claude worktree.path (fresh victim of the right shape): exit 1" "1" "$rc"
VICT="$(grep '^victim ' "$SB/log" | cut -d' ' -f2)"
check "M: the victim worktree (a complete scratch repo) was not deleted" test -f "$VICT/sentinel"
has "M: the leftover claude scratch location is printed" "$(cat "$SB/err")" "claude: scratch run dir NOT removed"
has "M: the recorded (forged) location is shown, filtered" "$(cat "$SB/err")" "$VICT"
expect "M: the forged claude row is FAIL (hello not read from the forged path)" "$(cat "$(root_of)/run-both.json")" '.rows[0].verdict == "FAIL" and .rows[0].hello_ok == false and .rows[1].verdict == "PASS"'
eq "M: the real claude run dir is also left (victim + real run dir, codex removed)" "2" "$(scratch_left)"
mk_fast
rc="$(run_sb "$SB/$FASTP" "FAKE_CODEX_FORGE=old" --)"
eq "M: forged codex worktree.txt (a leftover older than this run): exit 1" "1" "$rc"
VICT="$(grep '^victim ' "$SB/log" | cut -d' ' -f2)"
check "M: the old leftover worktree (a complete scratch repo) was not deleted" test -f "$VICT/sentinel"
has "M: the codex leftover is reported" "$(cat "$SB/err")" 'codex: scratch run dir NOT removed'
mk_fast
rc="$(run_sb "$SB/$FASTP" "FAKE_CODEX_FORGE=claude" --)"
eq "M: codex worktree.txt naming the claude worktree: exit 1" "1" "$rc"
expect "M: that codex row is FAIL, the claude row PASS" "$(cat "$(root_of)/run-both.json")" '.rows[0].verdict == "PASS" and .rows[1].verdict == "FAIL" and .rows[1].hello_ok == false'
# a worktree path file that read_wt refuses (a symlink) is reported, not skipped silently
mk_fast
rc="$(run_sb "$SB/$FASTP" "FAKE_CLAUDE_WTLINK=1" --)"
eq "M: worktree.path is a symlink: exit 1" "1" "$rc"
has "M: the refusal is reported" "$(cat "$SB/err")" 'claude: the worktree path file is missing or was refused'
has "M: the leftover is reported with an unknown location" "$(cat "$SB/err")" 'claude: scratch run dir NOT removed'
has "M: the location is unknown (the symlinked file was not read)" "$(cat "$SB/err")" 'Recorded location: unknown'

# N. round 3 hardening, whole flow
# N1. the claude worktree is swapped for a symlink to another directory (after the path shape was accepted): nothing is read there
mk_fast
mkdir -p "$SB/tmp/other"
printf 'hello from claude\n' > "$SB/tmp/other/hello.txt"
CNAME="canary-name-$$-must-never-be-printed"
printf 'x\n' > "$SB/tmp/other/$CNAME"
rc="$(run_sb "$SB/$FASTP" "FAKE_WCSWAP_OTHER=$SB/tmp/other" --)"
JN="$(cat "$(root_of)/run-both.json" 2>/dev/null)"
eq "N1: a swapped worktree symlink: exit 1" "1" "$rc"
eq "N1: the swap really happened (the wc shim ran it once)" "1" "$(logcount swapped)"
expect "N1: the claude row is FAIL with the fixed reason worktree path refused" "$JN" '.rows[0].verdict == "FAIL" and (.rows[0].reasons | index("worktree path refused")) != null'
expect "N1: hello.txt was not read through the symlink, nothing was listed" "$JN" '.rows[0].hello_ok == false and .rows[0].changed == []'
expect "N1: the codex row is unaffected" "$JN" '.rows[1].verdict == "PASS"'
eq "N1: the canary file name is never printed or stored" "0" "$(cat "$SB/out" "$SB/err" "$(root_of)/run-both.json" | grep -c "$CNAME")"
has "N1: the refusal is reported" "$(cat "$SB/err")" 'claude: worktree path refused'
eq "N1: the claude scratch dir is left, the codex one removed" "1" "$(scratch_left)"
check "N1: the other directory was not touched" test "$(ls -A "$SB/tmp/other" | wc -l | tr -d ' ')" = "2"

# N2. Ctrl-C during the claude run reaches the output filter too: the filter keeps the pipe open, the run script's EXIT trap runs
mk_fast
rc="$(run_sb "$SB/$FASTP" "FAKE_CLAUDE_CTRLC=1" --)"
eq "N2: Ctrl-C during the claude run: exit 130" "130" "$rc"
eq "N2: the run script's EXIT trap ran (the filter did not die and close the pipe under it)" "1" "$(logcount 'claude exit-trap')"
has "N2: the EXIT trap output reached the screen (the filter was still alive to show it)" "$(cat "$SB/out")" "claude exit-trap"
has "N2: the output written after the interrupt was still shown" "$(cat "$SB/out")" 'claude after the interrupt'
eq "N2: codex never started and no wait happened" "00" "$(logcount 'codex start')$(grep -c '^sleep' "$SB/log")"
eq "N2: scratch cleanup ran" "0" "$(scratch_left)"
check "N2: no run-both.json" test ! -e "$(root_of)/run-both.json"

# N3. a CLI with no capture dir: no false "NOT removed" message
mk_fast
rc="$(run_sb "$SB/$FASTP" "FAKE_CLAUDE_NOCAP=1" --)"
eq "N3: claude left no capture dir: exit 1" "1" "$rc"
has "N3: the missing capture is reported once" "$(cat "$SB/err")" 'claude: no single safe capture'
lacks "N3: no 'NOT removed' message for claude (nothing is recorded or known)" "$(cat "$SB/err")" 'claude: scratch run dir NOT removed'
expect "N3: claude FAIL, codex PASS" "$(cat "$(root_of)/run-both.json")" '.rows[0].verdict == "FAIL" and .rows[1].verdict == "PASS"'

# N4. a run dir name with a slash that the ? wildcards would accept is refused, and the victim is not deleted
mk_fast
rc="$(run_sb "$SB/$FASTP" "FAKE_CODEX_FORGE=slash" --)"
eq "N4: codex worktree.txt naming a two-segment run dir: exit 1" "1" "$rc"
VICT="$(grep '^victim ' "$SB/log" | cut -d' ' -f2)"
check "N4: the victim (a complete scratch repo whose path the glob accepts) was not deleted" test -f "$VICT/sentinel"
expect "N4: the codex row is FAIL (hello not read from the forged path), claude PASS" "$(cat "$(root_of)/run-both.json")" '.rows[0].verdict == "PASS" and .rows[1].verdict == "FAIL" and .rows[1].hello_ok == false'
has "N4: the codex leftover is reported" "$(cat "$SB/err")" 'codex: scratch run dir NOT removed'

# N5. <run>/repo is redirected to another scratch repo: no git runs through it, the other repo is untouched
mk_fast
rc="$(run_sb "$SB/$FASTP" "FAKE_CODEX_REPOLINK=1" --)"
eq "N5: a redirected repo: exit 1" "1" "$rc"
OREPO="$(grep '^other ' "$SB/log" | cut -d' ' -f2)"
check "N5: the other repo exists" test -d "$OREPO/.git"
{ git -C "$OREPO" worktree list; find "$OREPO" | sort; } > "$SB/other.after" 2>&1
check "N5: nothing in the other repo changed (git worktree list and file listing, before and after)" cmp -s "$SB/log.other.before" "$SB/other.after"
check "N5: the other repo still has its worktrees/codex-1 entry" test -d "$OREPO/.git/worktrees/codex-1"
expect "N5: the codex row is FAIL with exactly the fixed reason" "$(cat "$(root_of)/run-both.json")" '.rows[1].verdict == "FAIL" and .rows[1].reasons == ["scratch repo config changed"]'
has "N5: the leftover is reported (no cleanup through the redirect)" "$(cat "$SB/err")" 'codex: scratch run dir NOT removed'

# ---- the live gate in the real library is still intact (the sandbox override is only in the sandbox copy) -----------------------
check "the real lib/common.sh was not changed by the sandbox override" test "$(grep -c 'spike_require_live() { :; }' "$SPIKE/lib/common.sh")" = "0"
LIB_SHA1="$(sha "$SPIKE/lib/common.sh")"
eq "the real lib/common.sh has the same sha256 after the suite as before it" "$LIB_SHA0" "$LIB_SHA1"
if git -C "$REPO_TOP" rev-parse --is-inside-work-tree >/dev/null 2>&1 && git -C "$REPO_TOP" cat-file -e HEAD:spike/lib/common.sh 2>/dev/null; then
  LIB_SHA_HEAD="$(git -C "$REPO_TOP" show HEAD:spike/lib/common.sh | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -d' ' -f1)"
  eq "the real lib/common.sh equals git show HEAD:spike/lib/common.sh" "$LIB_SHA_HEAD" "$LIB_SHA1"
else
  ok
fi

# ---- result ------------------------------------------------------------------------------------------------------------------
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
