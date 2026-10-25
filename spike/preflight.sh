#!/usr/bin/env bash
# Preflight for the Phase 0 spikes: which provider CLIs are installed, whether the binary is code-signed, which version,
# and whether each is signed in. Uses only documented commands. Sends no prompts, so it needs no SPIKE_LIVE.
#
#   spike/preflight.sh
#
# Order matters (rules 4 and 6). For each CLI: resolve the binary ONCE, physically. If it lies inside a CLI home directory
# (rule 4), it is not read at all, except the provider binary itself when its first four bytes are a Mach-O magic (the
# ratified narrow exception). Otherwise `file` classifies it. A Mach-O is copied into a private directory (mode 700, removed
# on exit) and the COPY is registered with spike_mark_verified, which runs the magic check and the pinned-signer check
# (codesign --verify --strict, the first Authority is a "Developer ID Application" signature, the TeamIdentifier is the
# pinned team in common.sh, and the chain-to-Apple requirement for that team passes). Only the registered copy is ever
# executed, for --version and for the status command. The original path is never executed. If the copy cannot run, the
# row says "needs human review"; there is no fallback. Anything else (ad-hoc, unsigned, no authority, wrong team, script
# launcher, unknown file type) is never executed.
# Sign-in state comes from the CLI's own status command and ONLY from its exit code: the output is discarded and never
# printed or stored (it can contain account details). Children get a scrubbed environment (spike_run_status).
# Exit 0 = report printed; exit 1 = jq or git missing, or the temporary directory is unsafe (needs human review).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "$HERE/lib/common.sh"

ME="$(id -u)"
TMPROOT="${TMPDIR:-/tmp}"
TMPROOT="${TMPROOT%/}"
[ -n "$TMPROOT" ] || TMPROOT="/tmp"
PRIV=""
TMPOUT=""
trap 'rm -f "$TMPOUT"; if [ -n "$PRIV" ]; then rm -rf "$PRIV"; fi' EXIT

# dir_stat <path> -> "<uid> <octal mode>" (perl stat, portable between macOS and Linux). Fails if it cannot stat.
dir_stat() {
  perl -e 'my @s = stat($ARGV[0]) or exit 1; printf "%d %o\n", $s[4], $s[2] & 07777' -- "$1"
}

# parent_ok <dir> (round 6, item 5): 0 if the directory is sticky (shared temporary directories are), or is owned by the
# current user and is not group- or world-writable. Anything else needs a human to look at it.
parent_ok() {
  local st uid mode
  st="$(dir_stat "$1")" || return 1
  uid="${st%% *}"
  mode="${st#* }"
  if [ $(( 0$mode & 01000 )) -ne 0 ]; then return 0; fi
  [ "$uid" = "$ME" ] || return 1
  [ $(( 0$mode & 022 )) -eq 0 ] || return 1
  return 0
}

# sweep_stale (round 6, item 5): remove spike-preflight-verify.* directories left behind by a killed run (SIGKILL cannot
# run the EXIT trap). Only directories this user owns, that are real directories (not symlinks), and whose recorded owner
# pid is no longer alive. A directory without a readable owner record is left alone.
sweep_stale() {
  local d st uid pid
  for d in "$TMPROOT"/spike-preflight-verify.*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    st="$(dir_stat "$d")" || continue
    uid="${st%% *}"
    [ "$uid" = "$ME" ] || continue
    [ -f "$d/.owner" ] && [ ! -L "$d/.owner" ] || continue
    pid="$(head -n 1 "$d/.owner" | tr -cd '0-9')"
    [ -n "$pid" ] || continue
    if kill -0 "$pid" 2>/dev/null; then continue; fi
    rm -rf "$d"
  done
}

# ---- temporary files and the private verify directory ----------------------------------------------------------------
if ! parent_ok "$TMPROOT"; then
  spike_err "needs human review: $TMPROOT is writable by others and is not sticky; preflight will not create its verify directory there"
  exit 1
fi
sweep_stale
TMPOUT="$(mktemp "$TMPROOT/spike-preflight.XXXXXX")" || exit 1
PRIV="$(mktemp -d "$TMPROOT/spike-preflight-verify.XXXXXX")" || { rm -f "$TMPOUT"; exit 1; }
st="$(dir_stat "$PRIV")" || exit 1
if [ "${st%% *}" != "$ME" ] || [ "${st#* }" != "700" ]; then
  spike_err "needs human review: the private verify directory $PRIV is not owned by this user with mode 700"
  exit 1
fi
printf '%s\n' "$$" > "$PRIV/.owner" || exit 1
chmod 700 "$PRIV" || exit 1
spike_set_verify_dir "$PRIV" || exit 1

# Keep only printable characters, so output from a CLI cannot inject terminal escape sequences into the report.
clean() { tr -cd '[:print:]'; }

# Show a path for humans: collapse $HOME to ~ and show the at-sign (scoped package dirs) as %.
show_path() {
  local p="$1"
  if [ -n "${HOME:-}" ] && [ "$HOME" != "/" ]; then
    case "$p" in "$HOME"/*) p="~/${p#"$HOME"/}" ;; esac
  fi
  printf '%s' "$p" | tr '@' '%' | clean
}

ROW_FMT='%-7s %-6s %-26s %-8s %-72s %-22s %s\n'
NOTES=""
add_note() { NOTES="$NOTES# $1
"; }

# first_line <file> <width> -> first line, printable only, redacted, cut.
first_line() { head -n 1 "$1" | clean | spike_redact | cut -c1-"$2"; }

# file_kind <path> -> prints mach-o | script | other. file(1) reads only the start of the file. Never called on a path
# inside a CLI home directory (rule 4): check_cli refuses those first.
file_kind() {
  local ftype
  : > "$TMPOUT"
  spike_run_timed 10 "$TMPOUT" file -b "$1"
  ftype="$(head -n 1 "$TMPOUT" | clean)"
  case "$ftype" in
    *Mach-O*) printf 'mach-o' ;;
    *script*|*text*) printf 'script' ;;
    *) printf 'other' ;;
  esac
}

# check_tool <name> <version-args...>: presence and version. Called directly, not through the gated runner.
check_tool() {
  local name="$1" path ver
  shift
  path="$(type -P "$name" 2>/dev/null)" || path=""
  if [ -z "$path" ]; then
    printf "$ROW_FMT" "$name" "MISSING" "-" "-" "-" "-" "required tool not found"
    return 1
  fi
  : > "$TMPOUT"
  spike_run_timed 10 "$TMPOUT" "$path" "$@"
  ver="$(first_line "$TMPOUT" 26)"
  printf "$ROW_FMT" "$name" "yes" "${ver:--}" "-" "-" "-" "$(show_path "$path")"
  return 0
}

check_cli() { # check_cli <name> <signin-args...>
  local name="$1" path bin kind copy ver signin rc
  shift
  path="$(type -P "$name" 2>/dev/null)" || path=""
  if [ -z "$path" ]; then
    printf "$ROW_FMT" "$name" "no" "-" "-" "-" "-" "not installed"
    return 0
  fi
  # Resolve ONCE, physically (round 6, item 1). Everything below uses this one path: the rule 4 check, file, cp, and the
  # registration of the copy.
  bin="$(spike_resolve_path "$path" 2>/dev/null)" || bin=""
  if [ -z "$bin" ]; then
    printf "$ROW_FMT" "$name" "yes" "skipped (unverified)" "-" "NOT VERIFIED (unresolvable path)" "skipped (unverified)" "$(show_path "$path")"
    add_note "$name could not be resolved and was NOT executed (rule 6)."
    return 0
  fi

  # Rule 4, before anything reads the file: a path inside a CLI home directory is never read, except the provider binary
  # itself when its first four bytes are a Mach-O magic (the ratified narrow exception; nothing else is read).
  if spike_under_cli_home "$bin"; then
    if ! spike_magic_ok "$bin"; then
      SIG="REFUSED (inside a CLI home directory; not read)"
      printf "$ROW_FMT" "$name" "yes" "skipped (unverified)" "refused" "$SIG" "skipped (unverified)" "$(show_path "$bin")"
      add_note "$name resolves inside a CLI home directory and was NOT read (rule 4). Only the provider binary itself may be read, and only when its first four bytes are a Mach-O magic."
      return 0
    fi
    kind="mach-o"
  else
    kind="$(file_kind "$bin")"
  fi

  if [ "$kind" != "mach-o" ]; then
    if [ "$kind" = "script" ]; then
      SIG="launcher only, not executed (needs human approval)"
      add_note "$name resolves to a script launcher and was NOT executed; a launcher's signature (if any) says nothing about the program it starts. A human must approve it explicitly."
    else
      SIG="NOT VERIFIED (unrecognised file type)"
      add_note "$name was NOT executed: its file type is not a Mach-O binary (rule 6)."
    fi
    printf "$ROW_FMT" "$name" "yes" "skipped (unverified)" "$kind" "$SIG" "skipped (unverified)" "$(show_path "$bin")"
    return 0
  fi

  # 1. Copy the Mach-O into the private directory. 2. Register THE COPY (magic and pinned-signer checks run inside
  # spike_mark_verified). 3. Execute only that registered copy.
  copy="$PRIV/$name"
  if ! cp "$bin" "$copy" 2>/dev/null || ! chmod 700 "$copy" 2>/dev/null; then
    SIG="NOT VERIFIED (private copy failed)"
    printf "$ROW_FMT" "$name" "yes" "skipped (unverified)" "$kind" "$SIG" "skipped (unverified)" "$(show_path "$bin")"
    add_note "$name could not be copied to a private directory and was NOT executed (rule 6)."
    return 0
  fi
  if [ "$(file_kind "$copy")" != "mach-o" ]; then
    SIG="NOT VERIFIED (private copy is not a Mach-O binary)"
    printf "$ROW_FMT" "$name" "yes" "skipped (unverified)" "$kind" "$SIG" "skipped (unverified)" "$(show_path "$bin")"
    add_note "$name was NOT executed: the private copy is not a Mach-O binary (rule 6)."
    return 0
  fi
  if ! spike_mark_verified "$copy" "$name" 2>/dev/null; then
    SIG="$SPIKE_SIG_TEXT"
    printf "$ROW_FMT" "$name" "yes" "skipped (unverified)" "$kind" "$SIG" "skipped (unverified)" "$(show_path "$bin")"
    add_note "$name was NOT executed because its code signature did not verify as the pinned vendor signer (rule 6)."
    return 0
  fi
  SIG="$SPIKE_SIG_TEXT"

  : > "$TMPOUT"
  spike_run_status 20 "$TMPOUT" "$copy" --version
  rc=$?
  if [ "$rc" -eq 0 ]; then
    ver="$(first_line "$TMPOUT" 26)"
  elif [ "$rc" -eq 124 ]; then
    ver="timeout"
  elif [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
    ver="needs human review"
    add_note "$name: the verified copy could not run (rc=$rc). Needs human review; the original path was NOT used."
  else
    ver="error (rc=$rc)"
  fi

  # Sign-in: documented status command, exit code only (output discarded).
  spike_run_status 20 /dev/null "$copy" "$@"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    signin="signed in"
  elif [ "$rc" -eq 124 ]; then
    signin="timeout"
  elif [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
    signin="needs human review"
  else
    signin="not signed in (rc=$rc)"
  fi

  printf "$ROW_FMT" "$name" "yes" "${ver:--}" "$kind" "$SIG" "$signin" "$(show_path "$bin")"
}

printf "$ROW_FMT" "TOOL" "FOUND" "VERSION" "KIND" "SIGNATURE" "SIGNED-IN" "PATH"
missing=0
check_tool jq --version || missing=1
check_tool git --version || missing=1
check_cli claude auth status
check_cli codex login status

if [ -n "$NOTES" ]; then
  printf '%s' "$NOTES"
fi
printf '# paths: home shown as ~, any at-sign in a path shown as %%. Sign-in = exit code of the CLI status command only.\n'
if [ "$missing" -ne 0 ]; then
  spike_err "jq and git are required"
  exit 1
fi
exit 0
