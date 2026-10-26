#!/bin/bash
# Phase 0 spike (T-002): ONE headless Claude Code run in a scratch worktree, then parse and summarise it.
#
#   SPIKE_LIVE=1 spike/claude/run.sh        (the human sets SPIKE_LIVE; an agent never does)
#
# Without SPIKE_LIVE=1 this exits 3 before anything else happens: no scratch repo, no capture, no CLI call.
#
# What it does, once, with no retry and no loop (rules 1 and 10):
#   1. registers the claude on PATH as a hash-verified private copy (rule 6); anything else is refused
#   2. makes a scratch repo + worktree "claude-1" under $TMPDIR/harness-spike/ (outside this repo)
#   3. with cwd = the worktree, runs through spike_run_live (closed environment, 120 s watchdog):
#        claude -p "<TASK>" --output-format stream-json --verbose --permission-mode acceptEdits --max-turns 5
#      --max-turns is a documented print-mode option (https://code.claude.com/docs/en/cli-reference), but `claude --help`
#      (2.1.295) does NOT list it: the flag is hidden from help (hideHelp) and still defined in the binary. So the turn cap is
#      5 (rule 1 ceiling: 40) and the live run must confirm it is honoured. The 120 s runner watchdog is a second, independent limit.
#   4. splits the output (split.jq) into raw.jsonl (JSON object lines) and stderr.txt (everything else), runs parse.jq, prints a summary
# Capture files are private: umask 077 below, so nothing in the capture directory is group- or world-readable.
# Headless -p only (rule 3). No config-home variable is named or set (rule 2); no credential file is read (rule 4).
set -u
umask 077

_here="${BASH_SOURCE[0]}"
case "$_here" in
  */*) _here="${_here%/*}" ;;
  *) _here="." ;;
esac
HERE="$(CDPATH= cd -P -- "$_here" && pwd -P)"
unset _here
# shellcheck disable=SC1091
. "$HERE/../lib/common.sh"

spike_require_live

TASK="Create hello.txt containing exactly the line: hello from claude. Then reply DONE."
MAX_TURNS=5
WATCHDOG_SECS=120

cleanup() { spike_verify_cleanup; }
trap cleanup EXIT

# completion_verdict <cli-exit-status> <parse-exit-status> <summary.json>
# Parsed completion decides success (rules 1 and 10: report, never retry). Returns 0 only when ALL of these hold: the CLI exited 0
# (124 gets its own reason), parse.jq exited 0, the summary is a JSON object with a result event whose is_error is exactly false,
# and the session id is usable (letters, digits and dashes, 8 to 64 long). Sets VERDICT_REASON to a FIXED string on failure (stream
# text is untrusted and is never echoed) and VERDICT_SID to the session id when it is usable. Whether hello.txt looks right is
# reported separately and can never turn a failing verdict into a pass.
completion_verdict() {
  local cli_rc="$1" parse_rc="$2" file="$3" sid
  VERDICT_REASON=""
  VERDICT_SID=""
  sid="$(jq -r '(.session_id | select(type == "string")) // empty' "$file" 2>/dev/null)"
  case "$sid" in
    ""|*[!A-Za-z0-9-]*) sid="" ;;
  esac
  if [ -n "$sid" ] && [ "${#sid}" -ge 8 ] && [ "${#sid}" -le 64 ]; then VERDICT_SID="$sid"; fi
  case "$cli_rc" in
    0) ;;
    124) VERDICT_REASON="the CLI was stopped by the watchdog timeout"; return 1 ;;
    *) VERDICT_REASON="the CLI did not exit 0"; return 1 ;;
  esac
  [ "$parse_rc" = "0" ] || { VERDICT_REASON="parse.jq failed on the output"; return 1; }
  jq -e 'type == "object"' "$file" >/dev/null 2>&1 || { VERDICT_REASON="the summary is missing or unreadable"; return 1; }
  jq -e '(.event_counts // {}) | keys | any(. == "result" or startswith("result/"))' "$file" >/dev/null 2>&1 \
    || { VERDICT_REASON="the output has no result event"; return 1; }
  jq -e '.final.is_error == false' "$file" >/dev/null 2>&1 \
    || { VERDICT_REASON="the result event does not report is_error false"; return 1; }
  [ -n "$VERDICT_SID" ] || { VERDICT_REASON="no usable session id in the output"; return 1; }
  return 0
}

# hello_ok <file> <expected text without a trailing newline>: byte-exact check of the file the CLI wrote. The file must be a regular
# file (not a symlink) whose content is exactly the expected text, with or without ONE trailing newline: no extra lines, no
# trailing spaces or carriage returns, no NUL bytes (the byte count must equal the length of what the shell read).
hello_ok() {
  (
    LC_ALL=C
    f="$1"
    want="$2"
    [ -f "$f" ] && [ ! -L "$f" ] || exit 1
    size="$(wc -c < "$f" | tr -d ' ')"
    got="$(cat -- "$f"; printf x)"
    got="${got%x}"
    [ "${#got}" = "$size" ] || exit 1
    [ "$got" = "$want" ] || [ "$got" = "$want"$'\n' ] || exit 1
    exit 0
  )
}

command -v jq >/dev/null 2>&1 || { spike_err "jq is required"; exit 1; }
command -v git >/dev/null 2>&1 || { spike_err "git is required"; exit 1; }

# ---- 1. the registered, hash-verified copy (rule 6) -----------------------------------------------------------------------
spike_register_cli claude
reg=$?
if [ "$reg" -ne 0 ]; then
  if [ "$reg" -eq 4 ]; then
    spike_err "claude is not installed on PATH; nothing was run"
  else
    spike_err "claude was NOT verified (${SPIKE_REG_STATUS:-unknown}); nothing was run. Run spike/preflight.sh and see its notes."
  fi
  exit 1
fi
COPY="$SPIKE_VERIFIED_COPY"

# ---- 2. scratch repo, worktree, capture directory -----------------------------------------------------------------------------
REPO="$(spike_scratch_repo)" || { spike_err "cannot create the scratch repo"; exit 1; }
RUN_DIR="$(dirname "$REPO")"
# From here on a scratch run directory exists; if setup fails, say where it is so the human can remove it.
WT="$(spike_worktree_add "$REPO" claude-1)" || {
  spike_err "cannot create the worktree; scratch run dir left at: $RUN_DIR (remove with: . spike/lib/common.sh; spike_cleanup $RUN_DIR)"
  exit 1
}
CAP="$(spike_capture_dir claude)" || {
  spike_err "cannot create the capture directory; scratch run dir left at: $RUN_DIR (remove with: . spike/lib/common.sh; spike_cleanup $RUN_DIR)"
  exit 1
}
CAP="${CAP%/}"
printf '%s\n' "$WT" > "$CAP/worktree.path"
printf '%s\n' "$RUN_DIR" > "$CAP/rundir.path"
printf '%s\n' "$TASK" > "$CAP/task.txt"

# ---- 3. the one run -----------------------------------------------------------------------------------------------------------------
# The runner has no cwd option, so the script changes directory itself. The runner puts stdout AND stderr of the child into
# the one output file, so the output is split afterwards (step 4).
cd "$WT" || exit 1
# combined.txt is created by the runner itself (mode 0600), not pre-created here.
spike_run_live "$WATCHDOG_SECS" "$CAP/combined.txt" "$COPY" \
  -p "$TASK" --output-format stream-json --verbose --permission-mode acceptEdits --max-turns "$MAX_TURNS"
rc=$?
cd "$HERE" || exit 1

# ---- 4. split, parse, summarise ---------------------------------------------------------------------------------------------------
# A line that is a JSON object goes to raw.jsonl; everything else (stderr text, a startup warning) goes to stderr.txt.
# Both files are always created by the redirects (a missing combined.txt, e.g. a refused run, gives two empty files).
jq -R -r --arg part raw -f "$HERE/split.jq" "$CAP/combined.txt" > "$CAP/raw.jsonl" 2>/dev/null
jq -R -r --arg part other -f "$HERE/split.jq" "$CAP/combined.txt" > "$CAP/stderr.txt" 2>/dev/null
jq -Rs -f "$HERE/parse.jq" "$CAP/raw.jsonl" > "$CAP/summary.json" 2>/dev/null
PARSE_RC=$?
[ "$PARSE_RC" -eq 0 ] || printf '{}\n' > "$CAP/summary.json"
if completion_verdict "$rc" "$PARSE_RC" "$CAP/summary.json"; then verdict="PASS"; else verdict="FAIL ($VERDICT_REASON)"; fi

hello="no"
if hello_ok "$WT/hello.txt" 'hello from claude'; then hello="yes"; fi

case "$rc" in
  0) status="exited 0" ;;
  124) status="stopped by the ${WATCHDOG_SECS}s watchdog (124)" ;;
  125) status="refused by the runner (125: HOME is not the account home, or the output file was refused)" ;;
  121) status="refused (121: the CLI-home denylist is unusable)" ;;
  126|127) status="the verified copy could not run ($rc); needs human review" ;;
  *) status="exited $rc" ;;
esac

printf '== claude headless run ==\n'
printf 'status        : %s\n' "$status"
printf 'verdict       : %s\n' "$verdict"
printf 'capture       : %s\n' "$CAP"
printf 'worktree      : %s\n' "$WT"
printf 'hello.txt ok  : %s\n' "$hello"
printf 'stderr lines  : %s\n' "$(wc -l < "$CAP/stderr.txt" | tr -d ' ')"
printf -- '-- summary (bounded fields only; text is untrusted data) --\n'
jq . "$CAP/summary.json" | tr -cd '[:print:]\n'
printf -- '-- next --\n'
printf 'Resume once:  SPIKE_LIVE=1 spike/claude/resume.sh %s\n' "$CAP"
printf 'Clean up:     (source spike/lib/common.sh; spike_cleanup %s)\n' "$RUN_DIR"
printf 'No retry was made. If the status above is an error, report it; do not re-run in a loop (rule 10).\n'

# The verdict alone decides the exit status; hello.txt above is information and never rescues a failing verdict.
[ "$verdict" = "PASS" ] || exit 1
exit 0
