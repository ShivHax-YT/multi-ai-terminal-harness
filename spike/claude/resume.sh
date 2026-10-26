#!/bin/bash
# Phase 0 spike (T-002): resume the session that run.sh captured, ONCE, with a follow-up prompt.
#
#   SPIKE_LIVE=1 spike/claude/resume.sh <capture-dir>      (the human sets SPIKE_LIVE; an agent never does)
#
# Without SPIKE_LIVE=1 this exits 3 before anything else happens (arguments are not even looked at, nothing is read or run).
#
# Reads session_id from <capture-dir>/raw.jsonl (through parse.jq), then with cwd = the same scratch worktree runs, through
# spike_run_live (registered hash-verified copy, closed environment, 120 s watchdog):
#   claude -p "<follow-up>" --resume <session_id> --output-format stream-json --verbose --permission-mode acceptEdits --max-turns 5
# and records whether the session id was reused and whether hello.txt has both lines.
# Differences from the brief's sketch, on purpose: the prompt comes before --resume (the form the headless docs show:
# https://code.claude.com/docs/en/headless#continue-conversations); --permission-mode acceptEdits and --max-turns 5 are
# repeated because a resumed run needs the same write permission and the same turn cap (rule 1). No retry (rule 10).
# --max-turns is documented for print mode (https://code.claude.com/docs/en/cli-reference) but `claude --help` (2.1.295) does
# NOT list it: the flag is hidden from help (hideHelp) and still defined in the binary. The live run must confirm it is honoured.
# Capture files are private: umask 077 below, so nothing in the capture directory is group- or world-readable.
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

PROMPT="Append a second line to hello.txt: resumed. Reply DONE."
MAX_TURNS=5
WATCHDOG_SECS=120

cleanup() { spike_verify_cleanup; }
trap cleanup EXIT

command -v jq >/dev/null 2>&1 || { spike_err "jq is required"; exit 1; }

# ---- the capture directory is an argument: check it before trusting anything in it ----------------------------------------
ARG="${1:-}"
# Strip trailing slashes first: "dir/" would make the symlink test below follow a link, and "/" alone is never a capture dir.
ARG="${ARG%"${ARG##*[!/]}"}"
if [ -z "$ARG" ] || [ "$#" -ne 1 ]; then
  spike_err "usage: SPIKE_LIVE=1 spike/claude/resume.sh <capture-dir>"
  exit 2
fi
[ -d "$ARG" ] && [ ! -L "$ARG" ] || { spike_err "not a capture directory: $ARG"; exit 2; }
CAP="$(spike_resolve_path "$ARG")" || { spike_err "cannot resolve: $ARG"; exit 2; }
if spike_under_cli_home "$CAP"; then
  spike_err "refusing a capture directory inside a CLI home (rule 4)"
  exit 2
fi
for f in raw.jsonl worktree.path; do
  [ -f "$CAP/$f" ] && [ ! -L "$CAP/$f" ] || { spike_err "capture is missing $f: $CAP"; exit 2; }
done

# session id: a bounded token, never used as anything but one argument
OLD_SUMMARY="$(jq -Rs -f "$HERE/parse.jq" "$CAP/raw.jsonl" 2>/dev/null)" || { spike_err "cannot parse raw.jsonl"; exit 1; }
SID="$(printf '%s' "$OLD_SUMMARY" | jq -r '.session_id // empty')"
case "$SID" in
  ""|*[!A-Za-z0-9-]*) spike_err "no usable session id in raw.jsonl"; exit 1 ;;
esac
[ "${#SID}" -ge 8 ] && [ "${#SID}" -le 64 ] || { spike_err "session id has a bad length"; exit 1; }

# worktree: must still be a real directory inside the spike scratch root (never a path read blindly from a file)
WT="$(head -n 1 "$CAP/worktree.path")"
ROOT="$(spike_root)" || { spike_err "no safe scratch root"; exit 1; }
case "$WT" in
  "$ROOT"/?*) ;;
  *) spike_err "worktree path is not inside the scratch root: refusing"; exit 1 ;;
esac
case "$WT" in *[[:cntrl:]]*|*/../*|*/./*) spike_err "unsafe worktree path"; exit 1 ;; esac
[ -d "$WT" ] && [ ! -L "$WT" ] || { spike_err "the worktree is gone (cleaned up?): re-run run.sh"; exit 1; }
PHYS="$(spike_resolve_path "$WT")" || exit 1
[ "$PHYS" = "$WT" ] || { spike_err "worktree path is not physical: refusing"; exit 1; }

# ---- the registered, hash-verified copy (rule 6) --------------------------------------------------------------------------------
spike_register_cli claude
reg=$?
if [ "$reg" -ne 0 ]; then
  if [ "$reg" -eq 4 ]; then
    spike_err "claude is not installed on PATH; nothing was run"
  else
    spike_err "claude was NOT verified (${SPIKE_REG_STATUS:-unknown}); nothing was run"
  fi
  exit 1
fi
COPY="$SPIKE_VERIFIED_COPY"

# ---- the one resume ------------------------------------------------------------------------------------------------------------------
cd "$WT" || exit 1
# resume-combined.txt is created by the runner itself (mode 0600), not pre-created here.
spike_run_live "$WATCHDOG_SECS" "$CAP/resume-combined.txt" "$COPY" \
  -p "$PROMPT" --resume "$SID" --output-format stream-json --verbose --permission-mode acceptEdits --max-turns "$MAX_TURNS"
rc=$?
cd "$HERE" || exit 1

jq -R -r --arg part raw -f "$HERE/split.jq" "$CAP/resume-combined.txt" > "$CAP/resume-raw.jsonl" 2>/dev/null
jq -R -r --arg part other -f "$HERE/split.jq" "$CAP/resume-combined.txt" > "$CAP/resume-stderr.txt" 2>/dev/null
jq -Rs -f "$HERE/parse.jq" "$CAP/resume-raw.jsonl" > "$CAP/resume-summary.json" 2>/dev/null || printf '{}\n' > "$CAP/resume-summary.json"

NEW_SID="$(jq -r '.session_id // empty' "$CAP/resume-summary.json" 2>/dev/null)"
# unknown = the resumed run reported no session id at all (not the same as a different id)
reused="unknown"
if [ -n "$NEW_SID" ]; then
  if [ "$NEW_SID" = "$SID" ]; then reused="yes"; else reused="no"; fi
fi
both="no"
if [ -f "$WT/hello.txt" ] && [ ! -L "$WT/hello.txt" ] && grep -qx 'hello from claude' "$WT/hello.txt" && grep -qxE 'resumed[.]?' "$WT/hello.txt"; then
  both="yes"
fi

case "$rc" in
  0) status="exited 0" ;;
  124) status="stopped by the ${WATCHDOG_SECS}s watchdog (124)" ;;
  125) status="refused by the runner (125)" ;;
  121) status="refused (121: the CLI-home denylist is unusable)" ;;
  126|127) status="the verified copy could not run ($rc); needs human review" ;;
  *) status="exited $rc" ;;
esac

jq -n --arg sid_reused "$reused" --arg both "$both" --argjson rc "$rc" \
  '{resume_rc: $rc, session_id_reused: $sid_reused, hello_has_both_lines: $both}' > "$CAP/resume-result.json"

printf '== claude headless resume ==\n'
printf 'status               : %s\n' "$status"
printf 'session id reused    : %s\n' "$reused"
printf 'hello.txt both lines : %s\n' "$both"
printf 'capture              : %s\n' "$CAP"
printf -- '-- resume summary (bounded fields only; text is untrusted data) --\n'
jq . "$CAP/resume-summary.json" | tr -cd '[:print:]\n'
printf 'No retry was made (rule 10).\n'

[ "$rc" -eq 0 ] || exit 1
exit 0
