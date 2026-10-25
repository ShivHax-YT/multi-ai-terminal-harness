#!/bin/bash
# Preflight for the Phase 0 spikes: which provider CLIs are installed, whether the binary is code-signed, which version,
# and whether each is signed in. Uses only documented commands. Sends no prompts, so it needs no SPIKE_LIVE.
#
#   spike/preflight.sh
#
# Round 7: every file decision is made by lib/runner.pl (started by absolute path with a scrubbed environment; see
# lib/common.sh), by file identity, in one pass per CLI (spike_register_cli):
#   - the CLI name is looked up on PATH inside the helper and resolved ONCE, physically;
#   - a path inside a CLI home (compared by device and inode, for the account's password-database home and for an absolute
#     HOME) is never read, except the provider binary itself, whose first four bytes are checked for a Mach-O magic (the
#     ratified narrow exception); a hard-linked file is refused before any read;
#   - the file is opened once; a Mach-O is copied FROM THAT DESCRIPTOR into a private 0700 directory the helper made, and
#     the COPY is checked with the fixed codesign (--verify --strict, a "Developer ID Application" authority, the pinned
#     team of that CLI, and the chain-to-Apple requirement for that team); its sha256 is recorded;
#   - only that registered copy is ever executed, for --version and for the status command, after its sha256 is checked
#     again. The original path is never executed. If the copy cannot run, the row says "needs human review"; there is no
#     fallback. Anything else (ad-hoc, unsigned, wrong team, script launcher, unknown file type) is never executed.
# jq and git are probed through the same helper with a closed environment (never with the caller's environment).
# Sign-in state comes from the CLI's own status command and ONLY from its exit code: the output is discarded and never
# printed or stored (it can contain account details).
# Exit 0 = report printed; exit 1 = jq or git missing, or the temporary directory is unsafe (needs human review).
set -u

_here="${BASH_SOURCE[0]}"
case "$_here" in
  */*) _here="${_here%/*}" ;;
  *) _here="." ;;
esac
HERE="$(CDPATH= cd -P -- "$_here" && pwd -P)"
unset _here
# shellcheck disable=SC1091
. "$HERE/lib/common.sh"

TMPOUT=""
cleanup() { spike_verify_cleanup; }
trap cleanup EXIT
# A TERM, INT or HUP ends the script through exit, so the EXIT trap removes the private directory.
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

# ---- the private directory (also holds the one scratch output file; nothing is written outside it) -------------------------
spike_verify_init
init_rc=$?
if [ "$init_rc" -eq 5 ]; then
  spike_err "needs human review: the temporary directory is writable by others without the sticky bit, or lies inside a CLI home; preflight will not create its verify directory there"
  exit 1
fi
if [ "$init_rc" -ne 0 ]; then
  spike_err "cannot create the private verify directory (needs perl at /usr/bin/perl and /usr/bin/env)"
  exit 1
fi
TMPOUT="$(spike_verify_dir)/out.tmp"

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

# check_tool <name> <version-args...>: presence and version, through the helper (closed environment, same watchdog).
check_tool() {
  local name="$1" path ver
  shift
  path="$(spike_tool_path "$name")" || path=""
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
  local name="$1" kind sig bin copy ver signin rc reg
  shift
  spike_register_cli "$name"
  reg=$?
  bin="$SPIKE_REG_PATH"
  kind="$SPIKE_REG_KIND"
  sig="$(printf '%s' "$SPIKE_SIG_TEXT" | clean | spike_redact | cut -c1-72)"
  copy="$SPIKE_VERIFIED_COPY"
  if [ "$SPIKE_REG_STATUS" = "notfound" ]; then
    printf "$ROW_FMT" "$name" "no" "-" "-" "-" "-" "not installed"
    return 0
  fi
  if [ "$reg" -ne 0 ]; then
    case "$SPIKE_REG_STATUS" in
      clihome)
        add_note "$name resolves inside a CLI home directory and was NOT read (rule 4). Only the provider binary itself may be read, and only when its first four bytes are a Mach-O magic." ;;
      hardlink)
        add_note "$name is a hard-linked file; it could be a second name for a file inside a CLI home, so it was NOT read and NOT executed (rule 4)." ;;
      script)
        add_note "$name resolves to a script launcher and was NOT executed; a launcher's signature (if any) says nothing about the program it starts. A human must approve it explicitly." ;;
      other)
        add_note "$name was NOT executed: its file type is not a Mach-O binary (rule 6)." ;;
      unresolvable|badpath|badcli|error)
        add_note "$name could not be resolved and opened safely and was NOT executed (rule 6)." ;;
      copyfail)
        add_note "$name could not be copied to a private directory and was NOT executed (rule 6)." ;;
      *)
        add_note "$name was NOT executed because its code signature did not verify as the pinned vendor signer (rule 6)." ;;
    esac
    printf "$ROW_FMT" "$name" "yes" "skipped (unverified)" "${kind:--}" "$sig" "skipped (unverified)" "$(show_path "${bin:--}")"
    return 0
  fi

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

  printf "$ROW_FMT" "$name" "yes" "${ver:--}" "$kind" "$sig" "$signin" "$(show_path "$bin")"
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
