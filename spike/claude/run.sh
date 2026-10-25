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
#      --max-turns is a documented print-mode option (https://code.claude.com/docs/en/cli-reference), so the turn cap is
#      5 (rule 1 ceiling: 40). The 120 s runner watchdog is a second, independent limit.
#   4. splits the output into raw.jsonl (JSON object lines) and stderr.txt (everything else), runs parse.jq, prints a summary
# Headless -p only (rule 3). No config-home variable is named or set (rule 2); no credential file is read (rule 4).
set -u

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
WT="$(spike_worktree_add "$REPO" claude-1)" || { spike_err "cannot create the worktree"; exit 1; }
RUN_DIR="$(dirname "$REPO")"
CAP="$(spike_capture_dir claude)" || { spike_err "cannot create the capture directory"; exit 1; }
CAP="${CAP%/}"
printf '%s\n' "$WT" > "$CAP/worktree.path"
printf '%s\n' "$RUN_DIR" > "$CAP/rundir.path"
printf '%s\n' "$TASK" > "$CAP/task.txt"

# ---- 3. the one run -----------------------------------------------------------------------------------------------------------------
# The runner has no cwd option, so the script changes directory itself. The runner puts stdout AND stderr of the child into
# the one output file, so the output is split afterwards (step 4).
cd "$WT" || exit 1
: > "$CAP/combined.txt"
spike_run_live "$WATCHDOG_SECS" "$CAP/combined.txt" "$COPY" \
  -p "$TASK" --output-format stream-json --verbose --permission-mode acceptEdits --max-turns "$MAX_TURNS"
rc=$?
cd "$HERE" || exit 1

# ---- 4. split, parse, summarise ---------------------------------------------------------------------------------------------------
# A line that is a JSON object goes to raw.jsonl; everything else (stderr text, a startup warning) goes to stderr.txt.
jq -R -r 'select(try (fromjson | type == "object") catch false)' "$CAP/combined.txt" > "$CAP/raw.jsonl" 2>/dev/null
jq -R -r 'select((try (fromjson | type == "object") catch false) | not)' "$CAP/combined.txt" > "$CAP/stderr.txt" 2>/dev/null
jq -Rs -f "$HERE/parse.jq" "$CAP/raw.jsonl" > "$CAP/summary.json" 2>/dev/null || printf '{}\n' > "$CAP/summary.json"

hello="no"
if [ -f "$WT/hello.txt" ] && [ ! -L "$WT/hello.txt" ] && grep -qx 'hello from claude' "$WT/hello.txt"; then hello="yes"; fi

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

if [ "$rc" -ne 0 ]; then exit 1; fi
sid="$(jq -r '.session_id // empty' "$CAP/summary.json" 2>/dev/null)"
[ -n "$sid" ] || { spike_err "no session id found in the output"; exit 1; }
exit 0
