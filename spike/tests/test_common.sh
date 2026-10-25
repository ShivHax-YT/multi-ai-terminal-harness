#!/usr/bin/env bash
# Tests for spike/lib/common.sh. Run: /bin/bash spike/tests/test_common.sh  (exit 0 = all passed)
# Uses a private TMPDIR so it never touches a real spike run.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { # check <name> <command...>
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}
eq() { # eq <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected [$2], got [$3])"; fi
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/spiketest.XXXXXX")" || exit 1
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
export TMPDIR="$SANDBOX"
trap 'rm -rf "$SANDBOX"' EXIT

# shellcheck disable=SC1091
. "$HERE/../lib/common.sh"

ROOT="$(spike_root)"
eq "spike_root is under the private TMPDIR" "$SANDBOX/harness-spike" "$ROOT"

# --- scratch repo, worktree, branch, cleanup -------------------------------------------------------------------------
REPO="$(spike_scratch_repo)"
check "scratch repo exists" test -d "$REPO/.git"
check "scratch repo lives under the spike root" test "${REPO#"$ROOT"/}" != "$REPO"
check "scratch repo has README.md and notes.txt" test -f "$REPO/README.md" -a -f "$REPO/notes.txt"
eq "scratch repo has exactly one commit" "1" "$(git -C "$REPO" rev-list --count HEAD)"
RUN="$(dirname "$REPO")"

WT="$(spike_worktree_add "$REPO" alpha)"
eq "worktree path is <repo>-wt/<name>" "$REPO-wt/alpha" "$WT"
check "worktree dir exists" test -d "$WT"
eq "worktree is on branch spike/alpha" "spike/alpha" "$(git -C "$WT" rev-parse --abbrev-ref HEAD)"
check "worktree add rejects a bad name" bash -c '. "$1"; ! spike_worktree_add "$2" "../evil"' _ "$HERE/../lib/common.sh" "$REPO"

spike_cleanup "$RUN"
check "cleanup removed the run dir" test ! -e "$RUN"
check "cleanup left no worktree dir" test ! -e "$REPO-wt"

# --- cleanup refuses anything outside the spike root -----------------------------------------------------------------
OUTSIDE="$SANDBOX/outside"
mkdir -p "$OUTSIDE/keep"
printf 'x\n' > "$OUTSIDE/keep/file"
spike_cleanup "$OUTSIDE" 2>/dev/null
eq "cleanup refuses a path outside the spike root (rc)" "2" "$?"
check "outside path is untouched" test -f "$OUTSIDE/keep/file"
spike_cleanup "$ROOT" 2>/dev/null
eq "cleanup refuses the spike root itself (rc)" "2" "$?"
spike_cleanup "" 2>/dev/null
eq "cleanup refuses an empty path (rc)" "2" "$?"
spike_cleanup "/" 2>/dev/null
eq "cleanup refuses / (rc)" "2" "$?"
spike_cleanup "$HOME" 2>/dev/null
eq "cleanup refuses \$HOME (rc)" "2" "$?"
mkdir -p "$ROOT/run-x"
spike_cleanup "$ROOT/run-x/../../outside" 2>/dev/null
eq "cleanup refuses .. traversal (rc)" "2" "$?"
check "traversal target is untouched" test -f "$OUTSIDE/keep/file"
ln -s "$OUTSIDE" "$ROOT/run-link"
spike_cleanup "$ROOT/run-link" 2>/dev/null
eq "cleanup refuses a symlink under the root (rc)" "2" "$?"
check "symlink target is untouched" test -f "$OUTSIDE/keep/file"
rm -f "$ROOT/run-link"
spike_cleanup "$ROOT/run-x"
check "cleanup removes a plain run dir under the root" test ! -e "$ROOT/run-x"

# --- spike_require_live ----------------------------------------------------------------------------------------------
( unset SPIKE_LIVE; spike_require_live ) 2>/dev/null
eq "spike_require_live exits 3 when SPIKE_LIVE is unset" "3" "$?"
( SPIKE_LIVE=0; spike_require_live ) 2>/dev/null
eq "spike_require_live exits 3 when SPIKE_LIVE=0" "3" "$?"
( SPIKE_LIVE=yes; spike_require_live ) 2>/dev/null
eq "spike_require_live exits 3 when SPIKE_LIVE=yes" "3" "$?"
( SPIKE_LIVE=1; spike_require_live ) 2>/dev/null
eq "spike_require_live passes when SPIKE_LIVE=1" "0" "$?"

# --- spike_capture_dir -----------------------------------------------------------------------------------------------
export SPIKE_CAPTURES_ROOT="$SANDBOX/captures"
CAP="$(spike_capture_dir demo)"
check "capture dir exists" test -d "$CAP"
case "$CAP" in
  "$SANDBOX/captures/demo/"2*Z/) ok "capture dir is <root>/<cli>/<UTC timestamp>/" ;;
  *) bad "capture dir shape: $CAP" ;;
esac
spike_capture_dir "../x" >/dev/null 2>&1
eq "capture dir rejects a bad cli name (rc)" "2" "$?"
unset SPIKE_CAPTURES_ROOT

# --- spike_redact ----------------------------------------------------------------------------------------------------
U1="3f2b8c1e-9a4d-4e7b-8c55-0123456789ab"
U2="AAAAAAAA-bbbb-4ccc-8ddd-eeeeeeeeeeee"
LINE="session $U1 and $U2 and $U1 again at $HOME/projects/secret/file.txt, mail jane.doe+x@example.com; wt $ROOT/run-1/repo-wt/a/file"
OUT="$(printf '%s\n' "$LINE" | spike_redact)"
case "$OUT" in *"$U1"*|*"$U2"*) bad "redact removes UUIDs" ;; *) ok "redact removes UUIDs" ;; esac
case "$OUT" in *"session <ID-1> and <ID-2> and <ID-1> again"*) ok "redact numbers ids stably (same id, same number)" ;; *) bad "redact id numbering: $OUT" ;; esac
case "$OUT" in *'at $HOME/...,'*) ok 'redact rewrites a $HOME path to $HOME/...' ;; *) bad "redact home: $OUT" ;; esac
case "$OUT" in *"projects/secret"*) bad "redact hides the home path tail" ;; *) ok "redact hides the home path tail" ;; esac
case "$OUT" in *"mail <EMAIL>;"*) ok "redact rewrites an email to <EMAIL>" ;; *) bad "redact email: $OUT" ;; esac
case "$OUT" in *"wt <WORKTREE>/repo-wt/a/file"*) ok "redact rewrites the scratch run dir to <WORKTREE>" ;; *) bad "redact scratch: $OUT" ;; esac
case "$OUT" in *@*) bad "redacted output has no @" ;; *) ok "redacted output has no @" ;; esac
OUT2="$(printf '%s\n' "id $U2 only" | spike_redact)"
eq "redact numbering restarts per invocation" "id <ID-1> only" "$OUT2"
OUT3="$(printf '%s\n' "${HOME}x/not-home and plain text" | spike_redact)"
eq "redact leaves a lookalike path prefix alone" "${HOME}x/not-home and plain text" "$OUT3"

# --- spike_resolve_path / spike_run_timeout ----------------------------------------------------------------------------
mkdir -p "$SANDBOX/rp/real"
printf 'x\n' > "$SANDBOX/rp/real/target"
ln -s real/target "$SANDBOX/rp/link1"
ln -s "$SANDBOX/rp/link1" "$SANDBOX/rp/link2"
eq "resolve_path follows a symlink chain" "$SANDBOX/rp/real/target" "$(spike_resolve_path "$SANDBOX/rp/link2")"

spike_run_timeout 5 /dev/null true
eq "run_timeout returns 0 for true" "0" "$?"
spike_run_timeout 5 /dev/null false
eq "run_timeout returns the command exit code" "1" "$?"
spike_run_timeout 1 /dev/null sleep 5
eq "run_timeout returns 124 on timeout" "124" "$?"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
