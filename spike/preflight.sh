#!/usr/bin/env bash
# Preflight for the Phase 0 spikes: which provider CLIs are installed, which version, whether the binary is code-signed,
# and whether each is signed in. Uses only documented commands. Sends no prompts, so it needs no SPIKE_LIVE.
#
#   spike/preflight.sh
#
# Sign-in state comes from the CLI's own status command and ONLY from its exit code: the command's output is discarded
# and never printed or stored (it can contain account details). Exit 0 = report printed; exit 1 = jq or git missing.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "$HERE/lib/common.sh"

TMPOUT="$(mktemp "${TMPDIR:-/tmp}/spike-preflight.XXXXXX")" || exit 1
trap 'rm -f "$TMPOUT"' EXIT

# Show a path for humans: collapse $HOME and keep '@' (scoped package dirs) from looking like an email address.
show_path() {
  local p="$1"
  if [ -n "${HOME:-}" ] && [ "$HOME" != "/" ]; then
    case "$p" in "$HOME"/*) p="~/${p#"$HOME"/}" ;; esac
  fi
  printf '%s' "$p" | tr '@' '%'
}

ROW_FMT='%-8s %-9s %-26s %-10s %-34s %-18s %s\n'
NOTES=""
add_note() { NOTES="$NOTES# $1
"; }

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
  ver="$(head -n 1 "$TMPOUT" | spike_redact | cut -c1-26)"
  printf "$ROW_FMT" "$name" "yes" "${ver:--}" "-" "-" "-" "$(show_path "$path")"
  return 0
}

check_cli() { # check_cli <name> <signin-args...>
  local name="$1" path bin kind sig ver signin rc ftype
  shift
  path="$(command -v "$name" 2>/dev/null)" || path=""
  if [ -z "$path" ]; then
    printf "$ROW_FMT" "$name" "no" "-" "-" "-" "-" "not installed"
    return 0
  fi
  bin="$(spike_resolve_path "$path")" || bin="$path"

  # Version.
  : > "$TMPOUT"
  spike_run_timeout 20 "$TMPOUT" "$bin" --version
  rc=$?
  if [ "$rc" -eq 0 ]; then
    ver="$(head -n 1 "$TMPOUT" | spike_redact | cut -c1-26)"
  elif [ "$rc" -eq 124 ]; then
    ver="timeout"
  else
    ver="error (rc=$rc)"
  fi

  # Code signature of the resolved binary.
  ftype="$(file -b "$bin" 2>/dev/null)"
  case "$ftype" in
    *Mach-O*) kind="mach-o" ;;
    *script*|*text*) kind="script" ;;
    *) kind="other" ;;
  esac
  if command -v codesign >/dev/null 2>&1; then
    : > "$TMPOUT"
    spike_run_timeout 20 "$TMPOUT" codesign --verify --strict "$bin"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      sig="valid"
    elif [ "$rc" -eq 124 ]; then
      sig="timeout"
    elif grep -qi 'not signed at all' "$TMPOUT" 2>/dev/null || grep -qi 'not a Mach-O\|not in an object file format' "$TMPOUT" 2>/dev/null; then
      if [ "$kind" = "mach-o" ]; then sig="NOT SIGNED"; else sig="not signed / not a Mach-O"; fi
    else
      sig="NOT VERIFIED (codesign rc=$rc)"
    fi
  else
    sig="codesign unavailable"
  fi
  if [ "$kind" = "script" ]; then
    add_note "$name resolves to a script launcher; the signature above covers the launcher only, not the program it starts."
  fi

  # Sign-in: documented status command, exit code only (output discarded).
  spike_run_timeout 20 /dev/null "$path" "$@"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    signin="signed in"
  elif [ "$rc" -eq 124 ]; then
    signin="timeout"
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
if [ "$missing" -ne 0 ]; then
  spike_err "jq and git are required"
  exit 1
fi
exit 0
