#!/usr/bin/env bash
# Preflight for the Phase 0 spikes: which provider CLIs are installed, whether the binary is code-signed, which version,
# and whether each is signed in. Uses only documented commands. Sends no prompts, so it needs no SPIKE_LIVE.
#
#   spike/preflight.sh
#
# Order matters (rule 6): the code signature of the RESOLVED binary is verified first. A Mach-O binary whose signature
# does not verify is never executed ("skipped (unverified)"). Version and sign-in are then run on that same resolved
# binary. Sign-in state comes from the CLI's own status command and ONLY from its exit code: the output is discarded and
# never printed or stored (it can contain account details). Children get a scrubbed environment (spike_run_timeout).
# Exit 0 = report printed; exit 1 = jq or git missing.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "$HERE/lib/common.sh"

TMPOUT="$(mktemp "${TMPDIR:-/tmp}/spike-preflight.XXXXXX")" || exit 1
trap 'rm -f "$TMPOUT"' EXIT

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

check_tool() { # check_tool <name> <version-args...>
  local name="$1" path ver
  shift
  path="$(command -v "$name" 2>/dev/null)" || path=""
  if [ -z "$path" ]; then
    printf "$ROW_FMT" "$name" "MISSING" "-" "-" "-" "-" "required tool not found"
    return 1
  fi
  : > "$TMPOUT"
  spike_run_timeout 10 "$TMPOUT" "$path" "$@"
  ver="$(first_line "$TMPOUT" 26)"
  printf "$ROW_FMT" "$name" "yes" "${ver:--}" "-" "-" "-" "$(show_path "$path")"
  return 0
}

# Sets SIG (column text) and VERIFIED (1 = ok to execute) for the binary at $1.
verify_binary() {
  local bin="$1" kind="$2" rc auth team sigkind
  VERIFIED=0
  if ! command -v codesign >/dev/null 2>&1; then
    SIG="NOT VERIFIED (codesign unavailable)"
    return
  fi
  : > "$TMPOUT"
  spike_run_timeout 20 "$TMPOUT" codesign --verify --strict "$bin"
  rc=$?
  case "$kind" in
    mach-o)
      if [ "$rc" -eq 0 ]; then
        : > "$TMPOUT"
        spike_run_timeout 20 "$TMPOUT" codesign -dv --verbose=2 "$bin"
        auth="$(grep -m1 '^Authority=' "$TMPOUT" | cut -d= -f2- | clean | sed 's/ ([A-Z0-9]*)$//' | spike_redact | cut -c1-46)"
        team="$(grep -m1 '^TeamIdentifier=' "$TMPOUT" | cut -d= -f2- | clean | cut -c1-12)"
        sigkind=""
        grep -q '^Signature=adhoc' "$TMPOUT" && sigkind="ad-hoc, "
        SIG="valid; ${sigkind}${auth:-no authority}; team ${team:-none}"
        VERIFIED=1
      elif [ "$rc" -eq 124 ]; then
        SIG="NOT VERIFIED (codesign timed out)"
      elif grep -qi 'not signed at all' "$TMPOUT"; then
        SIG="NOT SIGNED"
      else
        SIG="NOT VERIFIED (codesign rc=$rc)"
      fi
      ;;
    script)
      # A script cannot carry its own signature; the check only describes the launcher.
      VERIFIED=1
      if [ "$rc" -eq 0 ]; then
        SIG="launcher only (valid signature on the launcher)"
      else
        SIG="launcher only (not signed / not a Mach-O)"
      fi
      ;;
    *)
      SIG="NOT VERIFIED (unrecognised file type)"
      ;;
  esac
}

check_cli() { # check_cli <name> <signin-args...>
  local name="$1" path bin kind ver signin rc ftype
  shift
  path="$(command -v "$name" 2>/dev/null)" || path=""
  if [ -z "$path" ]; then
    printf "$ROW_FMT" "$name" "no" "-" "-" "-" "-" "not installed"
    return 0
  fi
  bin="$(spike_resolve_path "$path")" || bin="$path"

  ftype="$(file -b "$bin" 2>/dev/null)"
  case "$ftype" in
    *Mach-O*) kind="mach-o" ;;
    *script*|*text*) kind="script" ;;
    *) kind="other" ;;
  esac

  # 1. Verify the resolved binary. 2. Only then execute that same binary.
  verify_binary "$bin" "$kind"
  if [ "$VERIFIED" -ne 1 ]; then
    printf "$ROW_FMT" "$name" "yes" "skipped (unverified)" "$kind" "$SIG" "skipped (unverified)" "$(show_path "$bin")"
    add_note "$name was NOT executed because its code signature did not verify (rule 6)."
    return 0
  fi
  if [ "$kind" = "script" ]; then
    add_note "$name resolves to a script launcher; the signature column covers the launcher only, not the program it starts."
  fi

  : > "$TMPOUT"
  spike_run_timeout 20 "$TMPOUT" "$bin" --version
  rc=$?
  if [ "$rc" -eq 0 ]; then
    ver="$(first_line "$TMPOUT" 26)"
  elif [ "$rc" -eq 124 ]; then
    ver="timeout"
  else
    ver="error (rc=$rc)"
  fi

  # Sign-in: documented status command, exit code only (output discarded).
  spike_run_timeout 20 /dev/null "$bin" "$@"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    signin="signed in"
  elif [ "$rc" -eq 124 ]; then
    signin="timeout"
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
