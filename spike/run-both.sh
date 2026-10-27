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
#   3. /bin/sleep 5                     (at least 5 s between dispatches, applied across providers as the human asked; rule 10)
#   4. spike/codex/run.sh once          (headless codex exec --json inside its own scratch worktree codex-1; rule 3)
#      Codex still runs when Claude failed (different provider, one prompt; human decision 2026-10-26). A signal stops before it.
#   5. normalizes each raw.jsonl with spike/normalize/<cli>.jq, prints one row per CLI, writes <ROOT>/run-both.json
#   6. removes the scratch run dirs unless --keep. Exit 0 only if both CLIs PASS, else 1.
# <ROOT> = spike/captures/run-both/<UTC stamp> (gitignored, fresh). The run scripts pick it up from the capture-root variable;
# the runner rebuilds the CLI's own environment, so nothing here reaches a CLI. The two run scripts verify and run only the
# registered binary (rule 6). No credential file, config-home variable, profile or config override is touched (rules 2 and 4);
# every file read from a capture is checked first (regular file, no symlink, one link, outside every CLI home).
# Everything a CLI wrote is untrusted data: it is only parsed with jq and printed filtered to printable characters.
# The scratch repo's config sits where the CLI could write it. Before ANY git command runs on that repo (the changed-files listing
# and the library's cleanup), its config files are read without executing anything and compared with an ALLOWLIST of the keys the
# scratch setup writes; any other key fails closed: the row FAILs ("scratch repo config changed"), no git runs, the dir is left and reported.
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

# Every jq call on capture data uses the probe-checked native jq (a wrapper script or a copy in a user directory first on PATH is refused).
JQ="$(spike_tool_path jq)" || { spike_err "a native jq in a system or package-manager prefix is required"; exit 1; }

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
  case "$size" in ""|*[!0123456789]*) return 1 ;; esac
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

# git_new_enough <git>: 0 if `git --version` is 2.32 or newer (GIT_CONFIG_COUNT needs 2.31, GIT_CONFIG_GLOBAL needs 2.32). Runs no repo.
git_new_enough() {
  local v maj min
  v="$(env -i PATH=/usr/bin:/bin HOME=/nonexistent LC_ALL=C "$1" --version 2>/dev/null | head -n 1)"
  v="${v#git version }"
  maj="${v%%.*}"
  min="${v#*.}"
  min="${min%%.*}"
  case "$maj" in ""|*[!0123456789]*) return 1 ;; esac
  case "$min" in ""|*[!0123456789]*) return 1 ;; esac
  [ "$maj" -gt 2 ] || { [ "$maj" -eq 2 ] && [ "$min" -ge 32 ]; }
}

# config_allowed <git> <config file>: 0 only if the file passes safe_input BEFORE git reads it (a regular file, no symlink, one link,
# outside every CLI home; rule 4) and every key is one the scratch repo setup writes (spike_scratch_repo and spike_worktree_add: init
# and worktree add, plus extensions.objectformat and extensions.refstorage, which a user's global init.* settings can make `git init`
# write and which start no program). An ALLOWLIST: any other key at all (a filter driver, include.path, core.worktree,
# extensions.worktreeconfig, an unknown harmless key) refuses. The file is read by `config --file ... --list`, which follows no
# include and executes nothing. An unreadable or unparsable file refuses.
config_allowed() {
  local keys n
  safe_input "$2" || return 1
  keys="$(env -i PATH=/usr/bin:/bin HOME=/nonexistent LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CEILING_DIRECTORIES=/ \
    "$1" -C / config --file "$2" --name-only --list 2>/dev/null)" || return 1
  [ -n "$keys" ] || return 0
  n="$(printf '%s\n' "$keys" | grep -vxE 'core\.(repositoryformatversion|filemode|bare|logallrefupdates|ignorecase|precomposeunicode)|extensions\.(objectformat|refstorage)' | wc -l | tr -d ' ')"
  [ "$n" = "0" ]
}

# config_absent_or_allowed <git> <config file>: 0 if the file does not exist at all, else config_allowed.
config_absent_or_allowed() {
  if [ ! -e "$2" ] && [ ! -L "$2" ]; then return 0; fi
  config_allowed "$1" "$2"
}

# wt_path_ok <worktree>: 0 only if the path is its own physical path (no component is a symlink) and lies outside every CLI home
# (rule 4). Nothing is read from or run in a worktree path that fails this.
wt_path_ok() {
  local phys
  [ -n "${1:-}" ] || return 1
  phys="$(spike_resolve_path "$1")" || return 1
  [ "$phys" = "$1" ] || return 1
  if spike_under_cli_home "$1"; then return 1; fi
  return 0
}

# scratch_repo_ok <git> <worktree>: no git command runs on the scratch repo, only `config --file` on its config files. 0 = the layout is the
# one the run scripts create (<run>/repo/.git and <run>/repo/.git/worktrees/<name>) and is pinned: <run>/repo is not a symlink, the
# physical path of the common git dir is exactly <run>/repo/.git (so no component above it redirects elsewhere), the worktree's
# commondir file is a safe regular file holding exactly ../.., and every config file git would read (the repo config, and
# config.worktree if present) passes the allowlist; 2 = the path is not a scratch worktree path; 3 = a config file or the layout
# changed. Sets SG_COMMON and SG_GD (the pinned git dirs) for the caller; the worktree's own .git file is never read.
scratch_repo_ok() {
  local g="$1" wt="$2" rest repo phys got
  SG_COMMON=""
  SG_GD=""
  rest="${wt%/*}"
  case "$rest" in
    */repo-wt) ;;
    *) return 2 ;;
  esac
  repo="${rest%/repo-wt}/repo"
  SG_COMMON="$repo/.git"
  SG_GD="$SG_COMMON/worktrees/${wt##*/}"
  if [ ! -d "$repo" ] || [ -L "$repo" ]; then return 3; fi
  phys="$(spike_resolve_path "$SG_COMMON")" || return 3
  [ "$phys" = "$SG_COMMON" ] || return 3
  if [ ! -d "$SG_COMMON" ] || [ -L "$SG_COMMON" ] || [ -L "$SG_COMMON/worktrees" ] || [ ! -d "$SG_GD" ] || [ -L "$SG_GD" ] ||
    [ ! -e "$SG_COMMON/config" ] || ! config_absent_or_allowed "$g" "$SG_COMMON/config" ||
    ! config_absent_or_allowed "$g" "$SG_COMMON/config.worktree" || ! config_absent_or_allowed "$g" "$SG_GD/config.worktree"; then
    return 3
  fi
  # git writes ../.. (and a newline) into the worktree entry's commondir file; anything else points the entry at another repo.
  safe_input "$SG_GD/commondir" || return 3
  got="$(cat -- "$SG_GD/commondir" 2>/dev/null; printf x)"
  got="${got%x}"
  [ "$got" = "../.." ] || [ "$got" = "../.."$'\n' ] || return 3
  return 0
}

# changed_files <worktree>: names from git status --porcelain, printable only, at most 20 lines. The scratch repo's config sits where the
# CLI could write it, so, before git runs on the repo at all:
#   - git must be 2.32 or newer, else it prints "(not listed: git too old)" and runs nothing (not a failure by itself);
#   - scratch_repo_ok must pass. A changed layout or any key outside the allowlist prints "(not listed: repo config changed)", runs
#     NO git on the repo and returns 3 (the row FAILs with the fixed reason "scratch repo config changed").
# Then status runs with a closed environment, the git dirs pinned (the worktree's .git file is not followed), no global or system
# config, fsmonitor, hooks and untracked cache forced off, and submodules ignored (a submodule would start a second git inside a
# directory the CLI controls).
changed_files() {
  local g wt="$1" rc
  g="$(spike_tool_path git)" || { printf '(not listed: git unavailable)\n'; return 0; }
  git_new_enough "$g" || { printf '(not listed: git too old)\n'; return 0; }
  scratch_repo_ok "$g" "$wt"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    printf '(not listed: unexpected worktree layout)\n'
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    printf '(not listed: repo config changed)\n'
    return 3
  fi
  env -i PATH=/usr/bin:/bin HOME=/nonexistent LC_ALL=C GIT_OPTIONAL_LOCKS=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ATTR_NOSYSTEM=1 \
    GIT_DIR="$SG_GD" GIT_COMMON_DIR="$SG_COMMON" GIT_WORK_TREE="$wt" \
    GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false \
    GIT_CONFIG_KEY_1=core.hooksPath GIT_CONFIG_VALUE_1=/dev/null GIT_CONFIG_KEY_2=core.untrackedCache GIT_CONFIG_VALUE_2=false \
    "$g" -C "$wt" status --porcelain --ignore-submodules=all 2>/dev/null | cut -c4- | printable | head -n 20
  return 0
}

# build_row <cli> <run.sh exit status> <hello yes|no> <changed files, one per line> <normalized.jsonl> [flags]: print one JSON row.
# PASS = run.sh exit 0, exactly one session_started, exactly one result with is_error false and numeric tokens, 0 rate_limited,
# hello.txt exact. `unknown` > 0 never fails a run (needs_mapping is set). Reasons are fixed strings, never stream text.
# flags (space separated words, all optional): cfg = the scratch repo config changed, wt = the worktree path was refused, norm = the
# normalizer failed, row = the row could not be built. Each one forces FAIL with its own fixed reason.
build_row() {
  local cli="$1" rc="$2" hello="$3" changed="$4" norm="$5" flags="${6:-}"
  case "$rc" in ""|*[!0123456789]*) rc=255 ;; esac
  [ -r "$norm" ] || norm=/dev/null
  "$JQ" -c -s --arg cli "$cli" --argjson rc "$rc" --arg hello "$hello" --arg changed "$changed" --arg flags "$flags" '
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
    | ($flags | split(" ")) as $fl
    | (($fl | index("cfg")) == null) as $c_cfg
    | (($fl | index("wt")) == null) as $c_wt
    | (($fl | index("norm")) == null) as $c_norm
    | (($fl | index("row")) == null) as $c_row
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
        verdict: (if $c_exit and $c_sess and $c_res and $c_rl and $c_hello and $c_cfg and $c_wt and $c_norm and $c_row then "PASS" else "FAIL" end),
        reasons: (if $c_row == false then ["row could not be built"] else [ (if $c_exit then empty else "run.sh did not exit 0" end),
                    (if $c_sess then empty else "not exactly one session_started" end),
                    (if $c_res then empty else "not exactly one successful result with numeric tokens" end),
                    (if $c_rl then empty else "rate_limited seen" end),
                    (if $c_hello then empty else "hello.txt missing or not exact" end),
                    (if $c_cfg then empty else "scratch repo config changed" end),
                    (if $c_wt then empty else "worktree path refused" end),
                    (if $c_norm then empty else "normalizer failed" end) ] end) }' < "$norm" 2>/dev/null
}

# fail_row <cli> <run.sh exit status>: the fixed FAIL row used when a row could not be built.
fail_row() { build_row "$1" "${2:-255}" no "" /dev/null row; }

# valid_row <cli> <run.sh exit status> <row json>: print the row if it is a JSON object for that CLI with a PASS or FAIL verdict and
# the fields the table needs, else the fixed FAIL row. One bad row never hides the other.
valid_row() {
  if printf '%s' "$3" | "$JQ" -e --arg cli "$1" 'type == "object" and .provider == $cli and (.verdict == "PASS" or .verdict == "FAIL")
      and (.changed | type) == "array" and (.reasons | type) == "array" and (.tokens | type) == "object"' >/dev/null 2>&1; then
    printf '%s\n' "$3"
  else
    fail_row "$1" "$2"
  fi
}

# table <run-both.json>: one printable table (one row per CLI), then the notes.
table() {
  "$JQ" -r '
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

# run_dir_of <cli> <worktree file>: print the scratch run dir of THIS run's <cli> worktree, or return 1. The worktree path comes from a
# capture file the CLI could have written, so it is trusted only if all of this holds (a forged path is never read or deleted):
#   - read_wt accepts the file (safe file, absolute, no control characters, physically inside the spike scratch root);
#   - the path is exactly <scratch root>/run-<UTC stamp>-<6 characters>/repo-wt/<cli>-1, the shape the run scripts create, and the
#     run dir name is one path segment (a ? in the pattern would also match a slash);
#   - the run dir is a real directory (no symlink) that is not older than this run's preflight.txt, so a leftover from an
#     earlier run, or any other directory, is refused;
#   - for claude, whose capture also holds rundir.path, that file must name the same run dir (codex writes no such file).
run_dir_of() {
  local cap wt run sroot rd name
  cap="$(cap_of "$1")" || return 1
  wt="$(read_wt "$cap/$2")" || return 1
  sroot="$(spike_root)" || return 1
  case "$wt" in
    "$sroot"/run-????????T??????Z-??????/repo-wt/"$1"-1) ;;
    *) return 1 ;;
  esac
  run="${wt%/repo-wt/*}"
  # a ? in a case pattern also matches a slash, so the run dir name is checked on its own: exactly one path segment
  name=${run#"$sroot"/}
  case "$name" in
    "" | */*) return 1 ;;
  esac
  [ -d "$run" ] && [ ! -L "$run" ] || return 1
  [ ! "$ROOT/preflight.txt" -nt "$run" ] || return 1
  if [ "$1" = "claude" ]; then
    rd="$(read_wt "$cap/rundir.path")" || return 1
    [ "$rd" = "$run" ] || return 1
  fi
  printf '%s\n' "$run"
}

# leftover_note <cli> <worktree file>: say where the scratch run dir was left, as claude/run.sh does. The recorded location is only
# read from a safe file, and is printed filtered and cut; it is text from a file the CLI could write, so it is only shown, never used.
leftover_note() {
  local cap line
  line="unknown"
  # No capture dir for this CLI: there is no recorded location and nothing to point at, so no "NOT removed" message at all.
  cap="$(cap_of "$1")" || return 0
  if safe_input "$cap/$2"; then
    line="$(head -n 1 "$cap/$2" 2>/dev/null | cut -c1-300 | printable)"
  fi
  spike_err "$1: scratch run dir NOT removed (not verified as this run's, its repo config changed, or removal failed). Recorded location: $line. All scratch dirs live under $(spike_root 2>/dev/null | printable). Remove by hand: . spike/lib/common.sh; spike_cleanup <run dir>"
}

# cleanup_one <cli> <worktree file>: remove the verified scratch run dir. The library's cleanup runs git on the scratch repo, so it
# runs only if the worktree path is clean and the repo layout and config still pass scratch_repo_ok (pinned repo path, commondir,
# allowlist; git new enough to check it); otherwise the dir is left and reported.
cleanup_one() {
  local d g
  if d="$(run_dir_of "$1" "$2")" && wt_path_ok "$d/repo-wt/$1-1" && g="$(spike_tool_path git)" && git_new_enough "$g" &&
    scratch_repo_ok "$g" "$d/repo-wt/$1-1" && spike_cleanup "$d"; then
    return 0
  fi
  leftover_note "$1" "$2"
}

# cleanup_scratch: once only, and only for a CLI that was started. Skipped with --keep.
CLEANED=0
STARTED_CLAUDE=0
STARTED_CODEX=0
cleanup_scratch() {
  [ "$KEEP" -eq 0 ] || return 0
  [ "$CLEANED" -eq 0 ] || return 0
  CLEANED=1
  if [ "$STARTED_CLAUDE" -eq 1 ]; then cleanup_one claude worktree.path; fi
  if [ "$STARTED_CODEX" -eq 1 ]; then cleanup_one codex worktree.txt; fi
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
  local cli="$1" wtfile="$2" want="$3" rc="$4" cap raw norm rd wt hello changed flags jqerr nrc crc normarg
  hello="no"
  changed=""
  flags=""
  norm="$ROOT/$cli.normalized.jsonl"
  if cap="$(cap_of "$cli")" && raw="$cap/raw.jsonl" && safe_input "$raw"; then
    # The status of the normalizer is kept: a non-zero status (jq failed after printing, or noclobber refused an existing file)
    # fails the row. Its error text is shown through printable, at most 5 lines.
    jqerr="$( ( set -C; "$JQ" -c -n -R -f "$HERE/normalize/$cli.jq" < "$raw" > "$norm" ) 2>&1 )"
    nrc=$?
    if [ "$nrc" -ne 0 ]; then
      flags="$flags norm"
      spike_err "$cli: the normalizer failed (status $nrc); its output is not used"
      if [ -n "$jqerr" ]; then printf '%s\n' "$jqerr" | cut -c1-300 | printable | head -n 5 >&2; fi
    fi
    if rd="$(run_dir_of "$cli" "$wtfile")"; then
      wt="$rd/repo-wt/$cli-1"
      if wt_path_ok "$wt"; then
        if hello_ok "$wt" "$want"; then hello="yes"; fi
        changed="$(changed_files "$wt")"
        crc=$?
        if [ "$crc" -eq 3 ]; then
          flags="$flags cfg"
          spike_err "$cli: scratch repo config changed; no git command was run on that repo"
        fi
      else
        flags="$flags wt"
        spike_err "$cli: worktree path refused; nothing was read or run there"
      fi
    else
      spike_err "$cli: the worktree path file is missing or was refused"
    fi
  else
    spike_err "$cli: no single safe capture with raw.jsonl under $ROOT/$cli"
  fi
  normarg="$norm"
  case "$flags" in *norm*) normarg=/dev/null ;; esac
  build_row "$cli" "$rc" "$hello" "$changed" "$normarg" "$flags"
}

# ---- the root, preflight ----------------------------------------------------------------------------------------------------
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
stop_if_signalled
if [ "$PRE_RC" -ne 0 ]; then
  spike_err "preflight failed (exit $PRE_RC); nothing was run"
  exit 1
fi

# ---- the two runs: fixed order, one call each, GAP_SECS apart ------------------------------------------------------------
# Each run script's output (stdout and stderr) goes through printable; its own exit status is taken from PIPESTATUS. The filter
# ignores SIGINT: a terminal Ctrl-C reaches the whole foreground group, and a filter that died would close the pipe under the run
# script, which would then die of SIGPIPE before its EXIT trap (its own cleanup) ran. The signal is still recorded by the trap above.
STARTED_CLAUDE=1
SPIKE_CAPTURES_ROOT="$ROOT" "$HERE/claude/run.sh" < /dev/null 2>&1 | ( trap '' INT; printable )
RC_CLAUDE="${PIPESTATUS[0]}"
stop_if_signalled
/bin/sleep "$GAP_SECS"
stop_if_signalled
STARTED_CODEX=1
SPIKE_CAPTURES_ROOT="$ROOT" "$HERE/codex/run.sh" < /dev/null 2>&1 | ( trap '' INT; printable )
RC_CODEX="${PIPESTATUS[0]}"
stop_if_signalled

# ---- normalize, check, print ----------------------------------------------------------------------------------------------
ROW_CLAUDE="$(process_cli claude worktree.path "$CLAUDE_HELLO" "$RC_CLAUDE")"
ROW_CODEX="$(process_cli codex worktree.txt "$CODEX_HELLO" "$RC_CODEX")"
ROW_CLAUDE="$(valid_row claude "$RC_CLAUDE" "$ROW_CLAUDE")"
ROW_CODEX="$(valid_row codex "$RC_CODEX" "$ROW_CODEX")"
stop_if_signalled
ROWS="$("$JQ" -c -n --argjson a "$ROW_CLAUDE" --argjson b "$ROW_CODEX" '[$a, $b]' 2>/dev/null)" || ROWS=""
if [ -z "$ROWS" ]; then
  spike_err "could not build the result rows"
  cleanup_scratch
  exit 1
fi
"$JQ" -n --argjson rows "$ROWS" '{rows: $rows}' > "$ROOT/run-both.json"
printf '\n== run-both result ==\n'
table "$ROOT/run-both.json"
printf 'captures (gitignored; redact before committing anything): %s\n' "$ROOT"

cleanup_scratch
# A signal that arrived while normalizing or printing still ends the script with the signal's code, after the cleanup above.
stop_if_signalled

if [ "$(printf '%s\n' "$ROWS" | "$JQ" -r 'map(select(.verdict == "PASS")) | length')" = "2" ]; then
  printf 'run-both: PASS (both CLIs)\n'
  exit 0
fi
printf 'run-both: FAIL (see the notes above). No retry was made; send this output to the lead, do not re-run in a loop.\n'
exit 1
