#!/usr/bin/env bash
# Preflight for the Phase 0 spikes: which provider CLIs are installed, whether the binary is code-signed, which version,
# and whether each is signed in. Uses only documented commands. Sends no prompts, so it needs no SPIKE_LIVE.
#
#   spike/preflight.sh
#
# Order matters (rule 6). For each CLI: resolve the binary. If it is a Mach-O file, copy it into a private directory
# (mode 700, removed on exit) and verify THAT COPY: codesign --verify --strict, the first Authority is a "Developer ID
# Application" signature, the TeamIdentifier is the pinned team (see the pinned block below), and the chain-to-Apple
# requirement for that team passes. Only the verified copy is ever executed, for --version and for the status command.
# The original path is never executed. If the copy cannot run, the row says "needs human review"; there is no fallback.
# Anything else (ad-hoc, unsigned, no authority, wrong team, script launcher, unknown file type) is never executed.
# Sign-in state comes from the CLI's own status command and ONLY from its exit code: the output is discarded and never
# printed or stored (it can contain account details). Children get a scrubbed environment (spike_run_status).
# Exit 0 = report printed; exit 1 = jq or git missing.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "$HERE/lib/common.sh"

# ---- FIXED CODESIGN PATH (rule 6) -----------------------------------------------------------------------------------
# Every signature check calls this absolute path. It is a readonly constant: no environment variable, flag or PATH entry
# changes it. The tests make a sandbox copy with only this line rewritten; the shipped script has no override hook.
readonly CODESIGN_BIN="/usr/bin/codesign"

# ---- PINNED SIGNER IDENTITIES (rule 6) ------------------------------------------------------------------------------
# Apple Developer Team IDs that the official CLI binaries must be signed by. Taken from the binaries installed on the
# developer's Mac on 2026-10-25 (claude: Anthropic PBC, codex: OpenAI). THE HUMAN MUST CONFIRM THESE AGAINST
# VENDOR-PUBLISHED VALUES BEFORE ANY RELEASE; until then they only prove "same signer as the binary I installed".
PINNED_AUTHORITY_PREFIX="Developer ID Application"
pinned_team() {
  case "$1" in
    claude) printf 'Q6L2SF6YDW' ;;  # Anthropic PBC
    codex) printf '2DC432GLL2' ;;   # OpenAI
    *) printf '' ;;
  esac
}
# ---------------------------------------------------------------------------------------------------------------------

PRIV=""
TMPOUT="$(mktemp "${TMPDIR:-/tmp}/spike-preflight.XXXXXX")" || exit 1
PRIV="$(mktemp -d "${TMPDIR:-/tmp}/spike-preflight-verify.XXXXXX")" || { rm -f "$TMPOUT"; exit 1; }
trap 'rm -f "$TMPOUT"; if [ -n "$PRIV" ]; then rm -rf "$PRIV"; fi' EXIT
chmod 700 "$PRIV" || exit 1

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

# run_timed <seconds> <outfile> <cmd> [args...]: a direct call for the fixed tools only (perl, file, git, jq, codesign),
# never for a provider CLI. stdin is /dev/null and output is appended to <outfile>. Returns 124 on timeout.
run_timed() {
  local secs="$1" out="$2" rc
  shift 2
  perl -e 'alarm shift; exec @ARGV' -- "$secs" "$@" </dev/null >>"$out" 2>&1
  rc=$?
  if [ "$rc" -eq 142 ]; then return 124; fi
  return "$rc"
}

# file_kind <path> -> prints mach-o | script | other. file(1) reads only the start of the file.
file_kind() {
  local ftype
  : > "$TMPOUT"
  run_timed 10 "$TMPOUT" file -b "$1"
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
  run_timed 10 "$TMPOUT" "$path" "$@"
  ver="$(first_line "$TMPOUT" 26)"
  printf "$ROW_FMT" "$name" "yes" "${ver:--}" "-" "-" "-" "$(show_path "$path")"
  return 0
}

# verify_binary <copy> <cli-name>: sets SIG (column text) and VERIFIED (1 = the copy may be executed). It is only ever
# called with the private copy, never with the original path.
verify_binary() {
  local bin="$1" name="$2" rc auth team want sigkind firstauth
  VERIFIED=0
  SIG=""
  if [ ! -x "$CODESIGN_BIN" ]; then
    SIG="NOT VERIFIED (codesign unavailable)"
    return
  fi
  : > "$TMPOUT"
  run_timed 20 "$TMPOUT" "$CODESIGN_BIN" --verify --strict "$bin"
  rc=$?
  if [ "$rc" -eq 124 ]; then
    SIG="NOT VERIFIED (codesign timed out)"
    return
  fi
  if [ "$rc" -ne 0 ]; then
    if grep -qi 'not signed at all' "$TMPOUT"; then
      SIG="NOT SIGNED"
    else
      SIG="NOT VERIFIED (codesign rc=$rc)"
    fi
    return
  fi

  # The signature is intact. Now identify the signer.
  : > "$TMPOUT"
  run_timed 20 "$TMPOUT" "$CODESIGN_BIN" -dv --verbose=2 "$bin"
  firstauth="$(grep -m1 '^Authority=' "$TMPOUT" | cut -d= -f2-)"
  team="$(grep -m1 '^TeamIdentifier=' "$TMPOUT" | cut -d= -f2-)"
  auth="$(printf '%s' "$firstauth" | clean | sed 's/ ([A-Z0-9]*)$//' | spike_redact | cut -c1-46)"
  team="$(printf '%s' "$team" | clean | cut -c1-12)"
  sigkind=""
  if grep -q '^Signature=adhoc' "$TMPOUT"; then sigkind="ad-hoc, "; fi
  want="$(pinned_team "$name")"

  case "$firstauth" in
    "$PINNED_AUTHORITY_PREFIX"*) ;;
    *)
      SIG="UNTRUSTED (valid but ${sigkind}${auth:-no authority}; not Developer ID)"
      return
      ;;
  esac
  if [ -z "$want" ] || [ "$team" != "$want" ]; then
    SIG="UNTRUSTED (valid but team ${team:-not set} is not the pinned team)"
    return
  fi
  # The text above can be forged by a self-made certificate; this asks codesign to check the chain to Apple's root.
  : > "$TMPOUT"
  run_timed 20 "$TMPOUT" "$CODESIGN_BIN" --verify --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$want\"" "$bin"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    SIG="UNTRUSTED (signer text matches but the certificate chain does not satisfy the pinned team)"
    return
  fi
  SIG="valid; ${auth}; team ${team}"
  VERIFIED=1
}

check_cli() { # check_cli <name> <signin-args...>
  local name="$1" path bin kind copy ver signin rc
  shift
  path="$(type -P "$name" 2>/dev/null)" || path=""
  if [ -z "$path" ]; then
    printf "$ROW_FMT" "$name" "no" "-" "-" "-" "-" "not installed"
    return 0
  fi
  bin="$(spike_resolve_path "$path")" || bin="$path"

  kind="$(file_kind "$bin")"
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

  # 1. Copy the Mach-O into the private directory and verify the COPY. 2. Execute only that verified copy.
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
  verify_binary "$copy" "$name"
  if [ "$VERIFIED" -ne 1 ]; then
    printf "$ROW_FMT" "$name" "yes" "skipped (unverified)" "$kind" "$SIG" "skipped (unverified)" "$(show_path "$bin")"
    add_note "$name was NOT executed because its code signature did not verify as the pinned vendor signer (rule 6)."
    return 0
  fi
  if ! spike_mark_verified "$copy"; then
    SIG="NOT VERIFIED (private copy rejected)"
    printf "$ROW_FMT" "$name" "yes" "skipped (unverified)" "$kind" "$SIG" "skipped (unverified)" "$(show_path "$bin")"
    add_note "$name was NOT executed: the verified copy was rejected by the runner (rule 6)."
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
