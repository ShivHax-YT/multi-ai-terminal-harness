#!/bin/bash
# Codex headless spike, step 2 (T-003): resume the thread that run.sh started, by its thread id.
#
#   SPIKE_LIVE=1 spike/codex/resume.sh <capture-dir>     # HUMAN ONLY. Without SPIKE_LIVE=1 this exits 3, calls nothing.
#
# <capture-dir> is the spike/captures/codex/<UTC time> directory that run.sh printed. This script:
#   1. spike_require_live (first statement): exit 3 unless SPIKE_LIVE=1.
#   2. Reads the thread id from <capture-dir>/raw.jsonl with parse.jq and the scratch worktree from worktree.txt. Both are
#      checked (an id is letters, digits and dashes only; the worktree must lie under the harness scratch root).
#   3. Registers the codex on PATH as the verified private copy and checks `login status` (exit code only), as run.sh does.
#   4. Runs once, from the same worktree, under a 120 s watchdog (no retry, no loop; a second resume of the same capture
#      is refused):
#        codex exec --json --sandbox workspace-write -C <worktree> resume <thread_id> "<prompt>"
#      Flag placement: the options belong to `codex exec` and come BEFORE the `resume` word, exactly as the official
#      TypeScript SDK builds this command line (see EVENTS.md, "CLI facts"). The human confirms with
#      `codex exec resume --help` on the Mac and records any difference in the T-003 notes.
#   5. Writes resume.combined.txt, resume.raw.jsonl, resume.stderr.txt, resume.parsed.json, resume.exit_code.txt and
#      resume.observed.redacted.jsonl next to the first capture.
# Everything the child printed is untrusted data: counted and parsed with jq only.
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

PROMPT='Append a second line to hello.txt: resumed. Reply DONE.'
WATCHDOG_SECS=120

trap 'spike_verify_cleanup' EXIT

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  spike_err "usage: SPIKE_LIVE=1 spike/codex/resume.sh <capture-dir>"
  exit 2
fi
command -v jq >/dev/null 2>&1 || { spike_err "jq is required"; exit 2; }

# ---- inputs from the first run (all checked; the files are data, not code) ------------------------------------------------
CAP="$(spike_resolve_path "$1")" || { spike_err "cannot resolve the capture directory: $1"; exit 2; }
CAPROOT="$(spike_resolve_path "${SPIKE_CAPTURES_ROOT:-$SPIKE_DIR/captures}")" || { spike_err "cannot resolve the captures root"; exit 2; }
case "$CAP" in
  "$CAPROOT"/codex/?*) ;;
  *) spike_err "not a codex capture directory under $CAPROOT: $1"; exit 2 ;;
esac
[ -d "$CAP" ] && [ -f "$CAP/raw.jsonl" ] && [ -f "$CAP/worktree.txt" ] || { spike_err "not a run.sh capture (raw.jsonl or worktree.txt missing): $CAP"; exit 2; }
if [ -e "$CAP/resume.combined.txt" ]; then
  spike_err "this capture was already resumed once; one resume per capture"
  exit 2
fi

THREAD_ID="$(jq -n -R -f "$HERE/parse.jq" < "$CAP/raw.jsonl" | jq -r '.thread_id // empty' | LC_ALL=C tr -d '\000-\037\177')"
case "$THREAD_ID" in
  ""|*[!A-Za-z0-9-]*) spike_err "no usable thread id in $CAP/raw.jsonl"; exit 2 ;;
esac
[ "${#THREAD_ID}" -ge 8 ] && [ "${#THREAD_ID}" -le 64 ] || { spike_err "thread id has an unexpected length"; exit 2; }

WT_RAW="$(head -n 1 "$CAP/worktree.txt")"
WT="$(spike_resolve_path "$WT_RAW")" || { spike_err "cannot resolve the worktree: $WT_RAW"; exit 2; }
SCRATCH="$(spike_root)" || exit 2
case "$WT" in
  "$SCRATCH"/?*) ;;
  *) spike_err "the worktree is not under the harness scratch root: $WT"; exit 2 ;;
esac
[ -d "$WT" ] || { spike_err "the scratch worktree no longer exists: $WT"; exit 2; }

# ---- the verified private copy, sign-in state (exit code only) --------------------------------------------------------------
spike_register_cli codex
rc=$?
if [ "$rc" -eq 4 ]; then
  spike_err "codex is not installed (not found on PATH)"
  exit 1
fi
if [ "$rc" -ne 0 ] || [ -z "$SPIKE_VERIFIED_COPY" ]; then
  spike_err "codex could not be verified (${SPIKE_REG_STATUS:-unknown}): ${SPIKE_SIG_TEXT:-no detail}; run spike/preflight.sh"
  exit 1
fi
spike_run_status 30 /dev/null "$SPIKE_VERIFIED_COPY" login status
if [ "$?" -ne 0 ]; then
  spike_err "codex is not signed in (or the status check failed). Sign in with Codex's own login flow, then re-run."
  exit 1
fi

# ---- the one invocation (no retry, no loop) ------------------------------------------------------------------------------------
spike_run_live "$WATCHDOG_SECS" "$CAP/resume.combined.txt" "$SPIKE_VERIFIED_COPY" \
  exec --json --sandbox workspace-write -C "$WT" resume "$THREAD_ID" "$PROMPT"
RUN_RC=$?
printf '%s\n' "$RUN_RC" > "$CAP/resume.exit_code.txt"

# ---- split, parse, redact (data only) ---------------------------------------------------------------------------------------
: > "$CAP/resume.raw.jsonl"
: > "$CAP/resume.stderr.txt"
if [ -f "$CAP/resume.combined.txt" ]; then
  awk -v raw="$CAP/resume.raw.jsonl" -v err="$CAP/resume.stderr.txt" '/^\{/ { print > raw; next } { print > err }' "$CAP/resume.combined.txt"
fi
jq -n -R -f "$HERE/parse.jq" < "$CAP/resume.raw.jsonl" > "$CAP/resume.parsed.json" 2> "$CAP/resume.parse.err"
spike_redact < "$CAP/resume.raw.jsonl" > "$CAP/resume.observed.redacted.jsonl"

# ---- result --------------------------------------------------------------------------------------------------------------------
OK=1
if [ "$RUN_RC" -eq 124 ]; then
  spike_err "timed out after ${WATCHDOG_SECS}s; the child's process group was killed"
  OK=0
elif [ "$RUN_RC" -ne 0 ]; then
  spike_err "codex exec resume exited with status $RUN_RC (see $CAP/resume.stderr.txt)"
  OK=0
fi
NEW_ID="$(jq -r '.thread_id // "none"' "$CAP/resume.parsed.json" 2>/dev/null | LC_ALL=C tr -d '\000-\037\177')"
if [ "$NEW_ID" = "$THREAD_ID" ]; then
  echo "thread id after resume: same as before (OK)"
else
  echo "thread id after resume: differs or missing ($NEW_ID); record this in EVENTS.md"
  OK=0
fi
if [ -f "$WT/hello.txt" ] && [ "$(sed -n 1p "$WT/hello.txt")" = "hello from codex" ] \
  && [ "$(sed -n 2p "$WT/hello.txt")" = "resumed" ] && [ "$(wc -l < "$WT/hello.txt" | tr -d ' ')" = "2" ]; then
  echo "hello.txt: OK (two lines: hello from codex / resumed)"
else
  echo "hello.txt: second line missing or content differs"
  OK=0
fi
echo "final status: $(jq -r '.final.status // "none"' "$CAP/resume.parsed.json" 2>/dev/null | LC_ALL=C tr -d '\000-\037\177')"
echo "unknown events/items: $(jq -r '(.unknown // []) | length' "$CAP/resume.parsed.json" 2>/dev/null | LC_ALL=C tr -d '\000-\037\177')"
echo "capture: $CAP"
[ "$OK" -eq 1 ] && exit 0
exit 1
