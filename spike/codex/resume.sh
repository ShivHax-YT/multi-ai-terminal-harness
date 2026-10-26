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
#      Flag placement (verified with `--help`, codex-cli 0.162.0): `-C` and `--sandbox` are options of `codex exec` only and
#      must come BEFORE the `resume` word; `codex exec resume -C ...` fails with "unexpected argument". `--json` is accepted
#      by both `exec` and `exec resume`. Nothing may be added after `resume <id> <prompt>` (see EVENTS.md, "CLI facts").
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
# link_count <file>: the number of hard links, portable (field 2 of `ls -ld`; the same on macOS and Linux). `stat` is avoided
# because its option letters differ between the two (and `stat -f %l` means something else on Linux).
link_count() {
  /bin/ls -ld -- "$1" 2>/dev/null | /usr/bin/awk '{ print $2; exit }'
}
# safe_input <file>: 0 only for a regular file that is not a symlink, is outside every CLI home (the T-001 check, which also
# refuses hard-linked regular files and anything it cannot resolve) and has exactly one link. Prints nothing and never opens
# the file, so a link to a credential file cannot leak into any output. Rule 4.
safe_input() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  if spike_under_cli_home "$1"; then return 1; fi
  [ "$(link_count "$1")" = "1" ]
}
CAP="$(spike_resolve_path "$1")" || { spike_err "cannot resolve the capture directory: $1"; exit 2; }
CAPROOT="$(spike_resolve_path "${SPIKE_CAPTURES_ROOT:-$SPIKE_DIR/captures}")" || { spike_err "cannot resolve the captures root"; exit 2; }
case "$CAP" in
  "$CAPROOT"/codex/?*) ;;
  *) spike_err "not a codex capture directory under $CAPROOT: $1"; exit 2 ;;
esac
[ -d "$CAP" ] && [ -f "$CAP/raw.jsonl" ] && [ -f "$CAP/worktree.txt" ] || { spike_err "not a run.sh capture (raw.jsonl or worktree.txt missing): $CAP"; exit 2; }
# every capture file is checked BEFORE it is read (rule 4); the message names only the capture directory, never file content
safe_input "$CAP/raw.jsonl" && safe_input "$CAP/worktree.txt" \
  || { spike_err "a capture file is a link, is hard-linked or lies inside a CLI home; refused, nothing was read: $CAP"; exit 2; }
# reserve_resume: the one-resume guard. mkdir either creates the directory or fails, in one step, so two resumes of the same
# capture cannot both pass. The reservation is made before the CLI call and is never removed (a failed resume is not retried).
reserve_resume() {
  mkdir "$1/resume.lock" 2>/dev/null
}
# any name starting with resume. (the lock, a combined file, or a planted file or link where an output will be written)
if compgen -G "$CAP/resume.*" >/dev/null; then
  spike_err "this capture was already resumed once (or is being resumed); one resume per capture"
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

# ---- atomic one-resume reservation, before the CLI call; never removed ---------------------------------------------------------
reserve_resume "$CAP" || { spike_err "this capture was already resumed once (or is being resumed); one resume per capture"; exit 2; }

# ---- the one invocation (no retry, no loop) ------------------------------------------------------------------------------------
spike_run_live "$WATCHDOG_SECS" "$CAP/resume.combined.txt" "$SPIKE_VERIFIED_COPY" exec --json --sandbox workspace-write -C "$WT" resume "$THREAD_ID" "$PROMPT"
RUN_RC=$?
printf '%s\n' "$RUN_RC" > "$CAP/resume.exit_code.txt"

# ---- split, parse, redact (data only) ---------------------------------------------------------------------------------------
: > "$CAP/resume.raw.jsonl"
: > "$CAP/resume.stderr.txt"
if [ -f "$CAP/resume.combined.txt" ]; then
  awk -v raw="$CAP/resume.raw.jsonl" -v err="$CAP/resume.stderr.txt" '/^\{/ { print > raw; next } { print > err }' "$CAP/resume.combined.txt"
fi
jq -n -R -f "$HERE/parse.jq" < "$CAP/resume.raw.jsonl" > "$CAP/resume.parsed.json" 2> "$CAP/resume.parse.err"
PARSE_RC=$?
spike_redact < "$CAP/resume.raw.jsonl" > "$CAP/resume.observed.redacted.jsonl"

# ---- result --------------------------------------------------------------------------------------------------------------------
# completion_verdict RUN_RC PARSE_RC STATUS THREAD_ID [EXPECTED_THREAD_ID]: prints one fixed reason per failure and returns 1 if there is any.
# The run counts as good only if ALL hold: codex exited 0 (not the 124 of the watchdog), parse.jq itself succeeded
# (jq exit 0), the parsed final status is exactly "completed" (the resume must have reported it), and the thread id is usable (letters, digits and dashes,
# 8 to 64 characters), and equal to EXPECTED_THREAD_ID. The reasons never repeat text from the stream. hello.txt is checked separately; a matching
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
  if [ -n "${5:-}" ] && [ "$tid" != "$5" ]; then echo "the thread id after resume differs from the first run's"; bad=1; fi
  [ "$bad" -eq 0 ]
}
STATUS="$(jq -r '.final.status // empty' "$CAP/resume.parsed.json" 2>/dev/null | LC_ALL=C tr -d '\000-\037\177')"
NEW_ID="$(jq -r '.thread_id // empty' "$CAP/resume.parsed.json" 2>/dev/null | LC_ALL=C tr -d '\000-\037\177')"
OK=1
REASONS="$(completion_verdict "$RUN_RC" "$PARSE_RC" "$STATUS" "$NEW_ID" "$THREAD_ID")" || {
  spike_err "not a good run: $(printf '%s' "$REASONS" | tr '\n' ';') (see $CAP/resume.stderr.txt and resume.parse.err)"
  OK=0
}
if [ "$NEW_ID" = "$THREAD_ID" ]; then
  echo "thread id after resume: same as before (OK)"
else
  echo "thread id after resume: differs or missing; record this in EVENTS.md"
  OK=0
fi
# hello_ok: the file holds exactly "hello from codex" and "resumed" as two lines, the second with or without a trailing
# newline (no extra lines). The added "x" keeps command substitution from stripping trailing newlines.
hello_ok() {
  local got
  [ -f "$1/hello.txt" ] || return 1
  got="$(cat "$1/hello.txt" 2>/dev/null; printf x)"
  [ "$got" = "hello from codex"$'\n'"resumedx" ] || [ "$got" = "hello from codex"$'\n'"resumed"$'\n'"x" ]
}
if hello_ok "$WT"; then
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
