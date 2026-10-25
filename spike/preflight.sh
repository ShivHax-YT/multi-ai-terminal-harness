#!/usr/bin/env bash
# Preflight for the Phase 0 spikes: which provider CLIs are installed, whether the binary is code-signed, which version,
# and whether each is signed in. Uses only documented commands. Sends no prompts, so it needs no SPIKE_LIVE.
#
#   spike/preflight.sh
#
# Order matters (rule 6): the code signature of the RESOLVED binary is verified first, and the binary is executed only
# if the signature verifies AND is a "Developer ID Application" signature AND carries the pinned team identifier for
# that CLI (see the pinned block below). Anything else (ad-hoc, unsigned, no authority, wrong team, script launcher,
# unknown file type) is never executed. Version and sign-in are then run on that same resolved binary. Sign-in state
# comes from the CLI's own status command and ONLY from its exit code: the output is discarded and never printed or
# stored (it can contain account details). Children get a scrubbed environment (spike_run_status).
# Exit 0 = report printed; exit 1 = jq or git missing.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "$HERE/lib/common.sh"

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

# verify_binary <bin> <kind> <cli-name>: sets SIG (column text) and VERIFIED (1 = ok to execute).
verify_binary() {
  local bin="$1" kind="$2" name="$3" rc auth team want sigkind firstauth
  VERIFIED=0
  case "$kind" in
    script)
      # A script cannot carry a trusted signature; it is never executed without a human decision.
      SIG="launcher only, not executed (needs human approval)"
      return
      ;;
    mach-o) ;;
    *)
      SIG="NOT VERIFIED (unrecognised file type)"
      return
      ;;
  esac
  if ! command -v codesign >/dev/null 2>&1; then
    SIG="NOT VERIFIED (codesign unavailable)"
    return
  fi
  : > "$TMPOUT"
  spike_run_timeout 20 "$TMPOUT" codesign --verify --strict "$bin"
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
  spike_run_timeout 20 "$TMPOUT" codesign -dv --verbose=2 "$bin"
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
  spike_run_timeout 20 "$TMPOUT" codesign --verify --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$want\"" "$bin"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    SIG="UNTRUSTED (signer text matches but the certificate chain does not satisfy the pinned team)"
    return
  fi
  SIG="valid; ${auth}; team ${team}"
  VERIFIED=1
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
  verify_binary "$bin" "$kind" "$name"
  if [ "$VERIFIED" -ne 1 ]; then
    printf "$ROW_FMT" "$name" "yes" "skipped (unverified)" "$kind" "$SIG" "skipped (unverified)" "$(show_path "$bin")"
    if [ "$kind" = "script" ]; then
      add_note "$name resolves to a script launcher and was NOT executed; a launcher's signature (if any) says nothing about the program it starts. A human must approve it explicitly."
    else
      add_note "$name was NOT executed because its code signature did not verify as the pinned vendor signer (rule 6)."
    fi
    return 0
  fi

  : > "$TMPOUT"
  spike_run_status 20 "$TMPOUT" "$bin" --version
  rc=$?
  if [ "$rc" -eq 0 ]; then
    ver="$(first_line "$TMPOUT" 26)"
  elif [ "$rc" -eq 124 ]; then
    ver="timeout"
  else
    ver="error (rc=$rc)"
  fi

  # Sign-in: documented status command, exit code only (output discarded).
  spike_run_status 20 /dev/null "$bin" "$@"
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
