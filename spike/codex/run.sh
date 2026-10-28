#!/bin/bash
# Codex headless spike, step 1 (T-003): one tiny scripted task through `codex exec --json` in a scratch worktree.
#
#   SPIKE_LIVE=1 spike/codex/run.sh        # HUMAN ONLY. Without SPIKE_LIVE=1 this exits 3 and calls nothing.
#
# What it does, once and without retries:
#   1. spike_require_live (first statement): exit 3 unless SPIKE_LIVE=1.
#   2. Registers the codex found on PATH as the verified private copy (code signature checked by the T-001 runner).
#      Only that copy is ever executed. A missing, unsigned or launcher-script codex stops here.
#   3. Asks the copy for `login status` (exit code only; the output is discarded). Signed out: stop.
#   4. Makes a scratch repo and a worktree named codex-1 under ${TMPDIR:-/tmp}/harness-spike/ (outside this repo).
#   5. Runs: codex exec --json --sandbox workspace-write -C <worktree> "<task>"   under a 120 s watchdog (the runner kills
#      the child's whole process group on timeout). Default configuration and login only: no profile, no config
#      overrides, no alternate home. `codex exec` is the documented headless mode; the interactive TUI is never started.
#   6. Captures to spike/captures/codex/<UTC time>/ (gitignored): raw.jsonl
#      (the child's stdout, JSON lines), stderr.txt (the child's stderr), parsed.json (parse.jq output), observed.redacted.jsonl (for a
#      fixture, after the human reads it), worktree.txt (input for resume.sh).
#
# spike_run_live_split (T-008) gives the child separate files for stdout (raw.jsonl) and stderr (stderr.txt); there is no
# after-the-fact guessing of which line came from which stream.
# Everything the child printed is untrusted data: it is only counted and parsed with jq, never evaluated.
set -u

_here="${BASH_SOURCE[0]}"
case "$_here" in
  */*) _here="${_here%/*}" ;;
  *) _here="." ;;
esac
HERE="$(CDPATH="" cd -P -- "$_here" && pwd -P)"
unset _here
# shellcheck disable=SC1091
. "$HERE/../lib/common.sh"
spike_require_live

TASK='Create a file named hello.txt whose only line is the three words hello from codex with no punctuation. Then reply DONE.'
WATCHDOG_SECS=120

trap 'spike_verify_cleanup' EXIT

command -v jq >/dev/null 2>&1 || { spike_err "jq is required"; exit 2; }

# ---- the verified private copy of codex -----------------------------------------------------------------------------
spike_register_cli codex
rc=$?
if [ "$rc" -eq 4 ]; then
  spike_err "codex is not installed (not found on PATH); install it the official way and run spike/preflight.sh"
  exit 1
fi
if [ "$rc" -ne 0 ] || [ -z "$SPIKE_VERIFIED_COPY" ]; then
  spike_err "codex could not be verified (${SPIKE_REG_STATUS:-unknown}): ${SPIKE_SIG_TEXT:-no detail}; run spike/preflight.sh"
  exit 1
fi

# ---- sign-in state: exit code only ---------------------------------------------------------------------------------------
spike_run_status 30 /dev/null "$SPIKE_VERIFIED_COPY" login status
if [ "$?" -ne 0 ]; then
  spike_err "codex is not signed in (or the status check failed). Sign in with Codex's own login flow, then re-run."
  exit 1
fi

# ---- scratch repo, worktree, capture directory ------------------------------------------------------------------------------
REPO="$(spike_scratch_repo)" || { spike_err "cannot make the scratch repo"; exit 1; }
RUN_DIR="$(dirname "$REPO")"
# From here on a scratch run directory exists; if setup fails, say where it is so the human can remove it.
WT="$(spike_worktree_add "$REPO" codex-1)" || {
  spike_err "cannot make the worktree; scratch run dir left at: $RUN_DIR (remove with: . spike/lib/common.sh; spike_cleanup $RUN_DIR)"
  exit 1
}
CAP="$(spike_capture_dir codex)" || {
  spike_err "cannot make the capture directory; scratch run dir left at: $RUN_DIR (remove with: . spike/lib/common.sh; spike_cleanup $RUN_DIR)"
  exit 1
}
CAP="${CAP%/}"
printf '%s\n' "$WT" > "$CAP/worktree.txt"
printf '%s\n' "$RUN_DIR" > "$CAP/rundir.path"
printf '%s\n' "$TASK" > "$CAP/task.txt"

# ---- the one invocation (no retry, no loop) ------------------------------------------------------------------------------------
spike_run_live_split "$WATCHDOG_SECS" "$CAP/raw.jsonl" "$CAP/stderr.txt" "$SPIKE_VERIFIED_COPY" exec --json --sandbox workspace-write -C "$WT" "$TASK"
RUN_RC=$?
printf '%s\n' "$RUN_RC" > "$CAP/exit_code.txt"

# ---- parse, redact (data only) ---------------------------------------------------------------------------------------
jq -n -R -f "$HERE/parse.jq" < "$CAP/raw.jsonl" > "$CAP/parsed.json" 2> "$CAP/parse.err"
PARSE_RC=$?
spike_redact < "$CAP/raw.jsonl" > "$CAP/observed.redacted.jsonl"

# ---- result --------------------------------------------------------------------------------------------------------------------
# completion_verdict RUN_RC PARSE_RC STATUS THREAD_ID: prints one fixed reason per failure and returns 1 if there is any.
# The run counts as good only if ALL hold: codex exited 0 (not the 124 of the watchdog), parse.jq itself succeeded
# (jq exit 0), the parsed final status is exactly "completed", and the thread id is usable (letters, digits and dashes,
# 8 to 64 characters). The reasons never repeat text from the stream. hello.txt is checked separately; a matching
# hello.txt never rescues a run that fails here.
completion_verdict() {
  local bad=0 tid=$4
  if [ "$1" = "124" ]; then echo "timed out after ${WATCHDOG_SECS:-120}s; the child's process group was killed"; bad=1
  elif [ "$1" != "0" ]; then echo "codex exited with a non-zero status"; bad=1; fi
  if [ "$2" != "0" ]; then echo "parse.jq failed (jq exited non-zero): the event stream could not be summarised"; bad=1; fi
  if [ "$3" != "completed" ]; then echo "the parsed final status is not 'completed' (no turn.completed as the last terminal event)"; bad=1; fi
  case "$tid" in
    ""|*[!A-Za-z0-9-]*) echo "no usable thread id in the event stream"; bad=1 ;;
    *) if [ "${#tid}" -lt 8 ] || [ "${#tid}" -gt 64 ]; then echo "the thread id has an unexpected length"; bad=1; fi ;;
  esac
  [ "$bad" -eq 0 ]
}
STATUS="$(jq -r '.final.status // empty' "$CAP/parsed.json" 2>/dev/null | LC_ALL=C tr -d '\000-\037\177')"
THREAD="$(jq -r '.thread_id // empty' "$CAP/parsed.json" 2>/dev/null | LC_ALL=C tr -d '\000-\037\177')"
OK=1
REASONS="$(completion_verdict "$RUN_RC" "$PARSE_RC" "$STATUS" "$THREAD")" || {
  spike_err "not a good run: $(printf '%s' "$REASONS" | tr '\n' ';') (see $CAP/stderr.txt and parse.err)"
  OK=0
}
# hello_ok: the file holds exactly "hello from codex", with or without ONE trailing newline (no extra blank lines).
# The added "x" keeps command substitution from stripping trailing newlines, so the bytes are compared as they are.
hello_ok() {
  local got
  [ -f "$1/hello.txt" ] || return 1
  got="$(cat "$1/hello.txt" 2>/dev/null; printf x)"
  [ "$got" = "hello from codexx" ] || [ "$got" = "hello from codex"$'\n'"x" ]
}
if hello_ok "$WT"; then
  echo "hello.txt: OK (exactly one line: hello from codex)"
else
  echo "hello.txt: MISSING or different content"
  OK=0
fi
echo "thread_id: $(jq -r '.thread_id // "none"' "$CAP/parsed.json" 2>/dev/null | LC_ALL=C tr -d '\000-\037\177')"
echo "final status: $(jq -r '.final.status // "none"' "$CAP/parsed.json" 2>/dev/null | LC_ALL=C tr -d '\000-\037\177')"
echo "unknown events/items: $(jq -r '(.unknown // []) | length' "$CAP/parsed.json" 2>/dev/null | LC_ALL=C tr -d '\000-\037\177')"
echo "capture: $CAP"
echo "next: SPIKE_LIVE=1 spike/codex/resume.sh \"$CAP\""
[ "$OK" -eq 1 ] && exit 0
exit 1
