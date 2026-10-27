#!/bin/bash
# Phase 0 end-to-end run (T-007): ONE scripted task per CLI, one after the other, then normalize both captures and print one table.
#
#   spike/run-both.sh [--dry-run] [--keep]       (the live run is the human's: SPIKE_LIVE must be set to 1 by the human)
#
#   --dry-run  print every command with placeholder paths and the wait between the two runs; create and start nothing; exit 0
#   --keep     keep the scratch repos and worktrees (captures always stay, for the human's redaction step)
#
# Without the live opt-in this exits 3 before anything else happens (spike_require_live): no directory, no preflight, no CLI.
#
# What it does, once, in this fixed order, never in parallel, never in a loop, no retry, no resume (rules 1 and 10):
#   1. spike/preflight.sh once, output to <ROOT>/preflight.txt (versions, signature, sign-in by exit code; sends no prompt)
#   2. spike/claude/run.sh once         (headless claude -p inside its own scratch worktree claude-1; rule 3)
#   3. sleep 5                          (at least 5 s between dispatches, applied across providers as the human asked; rule 10)
#   4. spike/codex/run.sh once          (headless codex exec --json inside its own scratch worktree codex-1; rule 3)
#      Codex still runs when Claude failed (different provider, one prompt; human decision 2026-10-26). A signal stops before it.
#   5. normalizes each raw.jsonl with spike/normalize/<cli>.jq, prints one row per CLI, writes <ROOT>/run-both.json
#   6. removes the scratch run dirs unless --keep. Exit 0 only if both CLIs PASS, else 1.
# <ROOT> = spike/captures/run-both/<UTC stamp> (gitignored, fresh). The run scripts pick it up from the capture-root variable;
# the runner rebuilds the CLI's own environment, so nothing here reaches a CLI. The two run scripts verify and run only the
# registered binary (rule 6). No credential file, config-home variable, profile or config override is touched (rules 2 and 4);
# every file read from a capture is checked first (regular file, no symlink, one link, outside every CLI home).
# Everything a CLI wrote is untrusted data: it is only parsed with jq and printed filtered to printable characters.
set -u
umask 077

GAP_SECS=5
readonly GAP_SECS
# The text each run.sh asks for; a test checks they appear verbatim inside the TASK= line of the matching run.sh.
CLAUDE_HELLO='hello from claude'
CODEX_HELLO='hello from codex'
readonly CLAUDE_HELLO CODEX_HELLO

DRY=0
KEEP=0
# At most two arguments, each one of the two options; anything else is a usage error (exit 2).
parse_arg() {
  case "$1" in
    --dry-run) DRY=1 ;;
    --keep) KEEP=1 ;;
    *)
      printf 'usage: spike/run-both.sh [--dry-run] [--keep]\n' >&2
      exit 2
      ;;
  esac
}
[ "$#" -le 2 ] || parse_arg "?"
[ "$#" -lt 1 ] || parse_arg "$1"
[ "$#" -lt 2 ] || parse_arg "$2"

if [ "$DRY" -eq 1 ]; then
  printf 'run-both dry run: nothing is created or started, no live opt-in is needed.\n'
  printf '<ROOT> = spike/captures/run-both/<UTC stamp>   (gitignored, must not exist yet)\n'
  printf '  1. mkdir <ROOT>\n'
  printf '  2. spike/preflight.sh > <ROOT>/preflight.txt\n'
  printf '  3. SPIKE_CAPTURES_ROOT=<ROOT> spike/claude/run.sh\n'
  printf '  4. sleep %s\n' "$GAP_SECS"
  printf '  5. SPIKE_CAPTURES_ROOT=<ROOT> spike/codex/run.sh\n'
  printf '  6. jq -c -n -R -f spike/normalize/claude.jq < <ROOT>/claude/<stamp>/raw.jsonl > <ROOT>/claude.normalized.jsonl\n'
  printf '  7. jq -c -n -R -f spike/normalize/codex.jq < <ROOT>/codex/<stamp>/raw.jsonl > <ROOT>/codex.normalized.jsonl\n'
  printf '  8. print one table (provider, exit, session, turns, tokens, cost, warning, rate_limited, unknown, changed files, hello, verdict)\n'
  printf '     and write <ROOT>/run-both.json\n'
  printf '  9. remove the scratch run dirs (skipped with --keep); exit 0 only if both PASS\n'
  printf 'Codex runs even if Claude fails. A signal stops before the codex run. The live run itself is the human'"'"'s.\n'
  exit 0
fi

_here="${BASH_SOURCE[0]}"
case "$_here" in
  */*) _here="${_here%/*}" ;;
  *) _here="." ;;
esac
HERE="$(CDPATH="" cd -P -- "$_here" && pwd -P)"
unset _here
# shellcheck disable=SC1091
. "$HERE/lib/common.sh"

spike_require_live

# A signal is recorded, never acted on in the middle of a child: once set, nothing new starts (see stop_if_signalled).
SIGNAL_RC=0
trap 'SIGNAL_RC=130' INT
trap 'SIGNAL_RC=143' TERM
trap 'SIGNAL_RC=129' HUP

# ---- begin functions (the offline test extracts and runs these) -------------------------------------------------------------

# printable <stdin>: keep printable characters and newlines only, so a CLI cannot inject terminal escape sequences.
printable() { LC_ALL=C tr -cd '[:print:]\n'; }

# safe_input <file>: 0 only for a regular file that is not a symlink, has one link and is outside every CLI home (rule 4).
safe_input() {
  [ -n "${1:-}" ] || return 1
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  if spike_under_cli_home "$1"; then return 1; fi
  return 0
}

# read_wt <file>: print the worktree path stored in a capture file, only if the file is safe, holds one short line and the
# path is absolute, free of control characters, physically resolved and strictly inside the spike scratch root.
read_wt() {
  local f="$1" line phys sroot size
  safe_input "$f" || return 1
  size="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
  case "$size" in ""|*[!0-9]*) return 1 ;; esac
  [ "$size" -gt 0 ] && [ "$size" -le 4096 ] || return 1
  line="$(head -n 1 "$f" 2>/dev/null)"
  case "$line" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$line" in *[[:cntrl:]]*) return 1 ;; esac
  phys="$(spike_resolve_path "$line")" || return 1
  sroot="$(spike_root)" || return 1
  case "$phys" in
    "$sroot"/*) ;;
    *) return 1 ;;
  esac
  case "$phys" in *[[:cntrl:]]*) return 1 ;; esac
  printf '%s\n' "$phys"
}

# hello_ok <worktree> <expected text without a trailing newline>: hello.txt is a safe regular file whose content is exactly the
# expected text, with or without ONE trailing newline: no extra line, no trailing space or carriage return, no NUL byte.
hello_ok() {
  (
    LC_ALL=C
    f="$1/hello.txt"
    want="$2"
    safe_input "$f" || exit 1
    size="$(wc -c < "$f" | tr -d ' ')"
    got="$(cat -- "$f"; printf x)"
    got="${got%x}"
    [ "${#got}" = "$size" ] || exit 1
    [ "$got" = "$want" ] || [ "$got" = "$want"$'\n' ] || exit 1
    exit 0
  )
}

# changed_files <worktree>: names from git status --porcelain, printable only, at most 20 lines. The repo's config was written
# in a place the CLI could write, so git runs with a closed environment and the config keys that start programs forced off.
changed_files() {
  local g
  g="$(spike_tool_path git)" || return 1
  env -i PATH=/usr/bin:/bin HOME=/nonexistent LC_ALL=C GIT_OPTIONAL_LOCKS=0 GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false \
    GIT_CONFIG_KEY_1=core.hooksPath GIT_CONFIG_VALUE_1=/dev/null GIT_CONFIG_KEY_2=core.untrackedCache GIT_CONFIG_VALUE_2=false \
    "$g" -C "$1" status --porcelain 2>/dev/null | cut -c4- | printable | head -n 20
}

# build_row <cli> <run.sh exit status> <hello yes|no> <changed files, one per line> <normalized.jsonl>: print one JSON row.
# PASS = run.sh exit 0, exactly one session_started, exactly one result with is_error false and numeric tokens, 0 rate_limited,
# hello.txt exact. `unknown` > 0 never fails a run (needs_mapping is set). Reasons are fixed strings, never stream text.
build_row() {
  local cli="$1" rc="$2" hello="$3" changed="$4" norm="$5"
  case "$rc" in ""|*[!0-9]*) rc=255 ;; esac
  [ -r "$norm" ] || norm=/dev/null
  jq -c -s --arg cli "$cli" --argjson rc "$rc" --arg hello "$hello" --arg changed "$changed" '
    def cnt($t): [.[] | select(.type == $t)] | length;
    def num: type == "number";
    . as $ev
    | [$ev[] | select(.type == "session_started")] as $ss
    | [$ev[] | select(.type == "result")] as $rs
    | ($rs[0] // {}) as $r
    | ($r.tokens // {}) as $t
    | ($ss[0].session_id // "") as $sid
    | (cnt("rate_limited")) as $rl
    | ($rc == 0) as $c_exit
    | (($ss | length) == 1) as $c_sess
    | (($rs | length) == 1 and $r.is_error == false and $r.tokens_known == true
       and ($t.input | num) and ($t.output | num)) as $c_res
    | ($rl == 0) as $c_rl
    | ($hello == "yes") as $c_hello
    | { provider: $cli,
        run_exit: $rc,
        session: (if $sid == "" then "none" else (($sid | gsub("[^A-Za-z0-9-]"; "?") | .[0:4]) + "...") end),
        turns: ($r.turns // null),
        tokens: {input: ($t.input // null), output: ($t.output // null),
                 cache_read: ($t.cache_read // null), cache_write: ($t.cache_write // null)},
        cost_usd_estimate: (if ($r.cost_usd | num) then $r.cost_usd else null end),
        warnings: cnt("warning"),
        rate_limited: $rl,
        unknown: cnt("unknown"),
        needs_mapping: (cnt("unknown") > 0),
        changed: ($changed | split("\n") | map(select(length > 0))),
        hello_ok: $c_hello,
        verdict: (if $c_exit and $c_sess and $c_res and $c_rl and $c_hello then "PASS" else "FAIL" end),
        reasons: ([ (if $c_exit then empty else "run.sh did not exit 0" end),
                    (if $c_sess then empty else "not exactly one session_started" end),
                    (if $c_res then empty else "not exactly one successful result with numeric tokens" end),
                    (if $c_rl then empty else "rate_limited seen" end),
                    (if $c_hello then empty else "hello.txt missing or not exact" end) ]) }' < "$norm"
}

# table <run-both.json>: one printable table (one row per CLI), then the notes.
table() {
  jq -r '
    def pad($n): tostring | . + ([range(0; $n - length)] | map(" ") | add // "");
    def v: if . == null then "-" else . end;
    def cols: [
      ["provider", 8, (.provider)], ["exit", 4, (.run_exit)], ["session", 8, (.session)], ["turns", 5, (.turns | v)],
      ["in", 7, (.tokens.input | v)], ["out", 7, (.tokens.output | v)], ["cache_r", 7, (.tokens.cache_read | v)],
      ["cache_w", 7, (.tokens.cache_write | v)], ["cost~", 8, (.cost_usd_estimate | v)],
      ["warn", 4, (.warnings)], ["rl", 3, (.rate_limited)], ["unk", 3, (.unknown)],
      ["changed", 24, ((.changed | join(",")) | if . == "" then "-" else . end)],
      ["hello", 5, (if .hello_ok then "yes" else "no" end)], ["verdict", 7, (.verdict)] ];
    .rows as $rows
    | ( ($rows[0] | cols) | map(.[0] as $h | .[1] as $w | $h | pad($w)) | join(" | ") ),
      ( ($rows[0] | cols) | map(.[1] as $w | ([range(0; $w)] | map("-") | add)) | join("-+-") ),
      ( $rows[] | . as $row | ($row | cols) | map(.[1] as $w | (.[2] | tostring) | pad($w)) | join(" | ") ),
      ( $rows[] | select(.needs_mapping) | "note: \(.provider) has \(.unknown) unknown event(s): needs mapping (T-004)" ),
      ( $rows[] | select(.verdict == "FAIL") | "note: \(.provider) FAIL: \(.reasons | join("; "))" )' "$1" | printable
}

# ---- end functions ------------------------------------------------------------------------------------------------------------

cap_of() { # cap_of <cli>: print the one capture dir under $ROOT/<cli>/, else return 1
  set -- "$ROOT/$1"/*/
  [ "$#" -eq 1 ] && [ -d "$1" ] && [ ! -L "$1" ] || return 1
  printf '%s\n' "${1%/}"
}
# scratch_of <cli> <worktree file>: print the scratch run dir of a finished run (for cleanup), or return 1.
scratch_of() {
  local cap wt
  cap="$(cap_of "$1")" || return 1
  wt="$(read_wt "$cap/$2")" || return 1
  case "$wt" in
    */repo-wt/*) printf '%s\n' "${wt%/repo-wt/*}" ;;
    *) return 1 ;;
  esac
}
cleanup_scratch() {
  local d
  [ "$KEEP" -eq 0 ] || return 0
  d="$(scratch_of claude worktree.path)" && spike_cleanup "$d"
  d="$(scratch_of codex worktree.txt)" && spike_cleanup "$d"
  return 0
}

# stop_if_signalled: after INT, TERM or HUP nothing new starts; clean up and exit 130, 143 or 129.
stop_if_signalled() {
  if [ "$SIGNAL_RC" -ne 0 ]; then
    spike_err "stopped by a signal; nothing further was started"
    cleanup_scratch
    exit "$SIGNAL_RC"
  fi
}

# process_cli <cli> <worktree file> <expected hello text> <run.sh exit status>: normalize, check, print the row JSON on stdout.
process_cli() {
  local cli="$1" wtfile="$2" want="$3" rc="$4" cap raw norm wt hello changed
  hello="no"
  changed=""
  norm="$ROOT/$cli.normalized.jsonl"
  if cap="$(cap_of "$cli")" && raw="$cap/raw.jsonl" && safe_input "$raw"; then
    ( set -C; jq -c -n -R -f "$HERE/normalize/$cli.jq" < "$raw" > "$norm" ) 2>/dev/null \
      || spike_err "could not write $norm"
    if wt="$(read_wt "$cap/$wtfile")"; then
      if hello_ok "$wt" "$want"; then hello="yes"; fi
      changed="$(changed_files "$wt")"
    else
      spike_err "$cli: the worktree path file is missing or was refused"
    fi
  else
    spike_err "$cli: no single safe capture with raw.jsonl under $ROOT/$cli"
  fi
  build_row "$cli" "$rc" "$hello" "$changed" "$norm"
}

# ---- the root, preflight ----------------------------------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || { spike_err "jq is required"; exit 1; }
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ROOT="$HERE/captures/run-both/$STAMP"
mkdir -p "$HERE/captures/run-both" || { spike_err "cannot create the run-both captures directory"; exit 1; }
mkdir "$ROOT" || { spike_err "$ROOT exists or cannot be created; nothing was run"; exit 1; }
# The captures root must be gitignored (spike/.gitignore) before anything is captured into it.
if git -C "$HERE" rev-parse --is-inside-work-tree >/dev/null 2>&1 && ! git -C "$HERE" check-ignore -q -- "$ROOT/x"; then
  spike_err "refusing to capture: $ROOT is not ignored by git"
  exit 1
fi

"$HERE/preflight.sh" > "$ROOT/preflight.txt" 2>&1 < /dev/null
PRE_RC=$?
printable < "$ROOT/preflight.txt"
if [ "$PRE_RC" -ne 0 ]; then
  spike_err "preflight failed (exit $PRE_RC); nothing was run"
  exit 1
fi
stop_if_signalled

# ---- the two runs: fixed order, one call each, GAP_SECS apart ------------------------------------------------------------
SPIKE_CAPTURES_ROOT="$ROOT" "$HERE/claude/run.sh" < /dev/null
RC_CLAUDE=$?
stop_if_signalled
sleep "$GAP_SECS"
stop_if_signalled
SPIKE_CAPTURES_ROOT="$ROOT" "$HERE/codex/run.sh" < /dev/null
RC_CODEX=$?
stop_if_signalled

# ---- normalize, check, print ----------------------------------------------------------------------------------------------
ROW_CLAUDE="$(process_cli claude worktree.path "$CLAUDE_HELLO" "$RC_CLAUDE")"
ROW_CODEX="$(process_cli codex worktree.txt "$CODEX_HELLO" "$RC_CODEX")"
ROWS="$(jq -c -n --argjson a "$ROW_CLAUDE" --argjson b "$ROW_CODEX" '[$a, $b]' 2>/dev/null)" || ROWS=""
if [ -z "$ROWS" ]; then
  spike_err "could not build the result rows"
  cleanup_scratch
  exit 1
fi
jq -n --argjson rows "$ROWS" '{rows: $rows}' > "$ROOT/run-both.json"
printf '\n== run-both result ==\n'
table "$ROOT/run-both.json"
printf 'captures (gitignored; redact before committing anything): %s\n' "$ROOT"

cleanup_scratch

if [ "$(printf '%s\n' "$ROWS" | jq -r 'map(select(.verdict == "PASS")) | length')" = "2" ]; then
  printf 'run-both: PASS (both CLIs)\n'
  exit 0
fi
printf 'run-both: FAIL (see the notes above). No retry was made; send this output to the lead, do not re-run in a loop.\n'
exit 1
