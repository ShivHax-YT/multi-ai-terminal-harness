#!/usr/bin/env bash
# Tests for spike/lib/common.sh. Run: /bin/bash spike/tests/test_common.sh  (exit 0 = all passed)
# Uses a private TMPDIR so it never touches a real spike run.
#
# Round 6: registration (spike_mark_verified) runs the pinned-signer check, so every child shell in this file sources a
# SANDBOX COPY of common.sh whose only change is the readonly CODESIGN_BIN line, pointed at a fake codesign. The main
# shell sources the real file (for the capture-root and other main-shell assertions). No real codesign or provider CLI
# is run here. Fixtures that must "run" are Mach-O-headed shell scripts: on Linux, env hands a file it cannot load to
# /bin/sh (the execvp ENOEXEC fallback), so their bodies run; this is test-only and says nothing about real Mach-O files.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
COMMON_REAL="$HERE/../lib/common.sh"

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
has() { # has <name> <haystack> <needle>
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing [$3] in [$2])" ;; esac
}
lacks() { # lacks <name> <haystack> <needle>
  case "$2" in *"$3"*) bad "$1 (found [$3] in [$2])" ;; *) ok "$1" ;; esac
}
# alive <pid>: 0 if the process is still running. kill -0 alone is not enough: a killed process whose parent is already
# gone stays a zombie (state Z) until PID 1 reaps it, and kill -0 succeeds on a zombie. A zombie has exited and cannot
# run code, so it counts as gone. If ps cannot report a state, the process counts as alive (fail closed).
alive() {
  local st
  [ -n "$1" ] || return 1
  kill -0 "$1" 2>/dev/null || return 1
  st="$(ps -o stat= -p "$1" 2>/dev/null)"
  case "$st" in Z*) return 1 ;; esac
  return 0
}

# ours <pid> <pattern>: 0 if <pid> is alive and not a zombie AND its command line contains <pattern>. A reused pid, whose
# command line differs, does not count.
ours() {
  [ -n "$1" ] || return 1
  alive "$1" || return 1
  case "$(ps -o args= -p "$1" 2>/dev/null)" in *"$2"*) return 0 ;; esac
  return 1
}

# gone_within <tenths> <pid>...: poll alive() every 0.1 s and return 0 as soon as none of the pids is alive. A zombie and
# an empty pid count as gone. After <tenths> tenths of a second with a pid still alive, return 1 and print one ps line per
# survivor. This replaces fixed post-signal sleeps: PID 1 can reap a re-parented zombie late on a loaded machine (about
# 1.6 s seen here). A genuine orphan stays alive past the deadline and still fails.
gone_within() {
  local limit="$1" n=0 p any
  shift
  while :; do
    any=""
    for p in "$@"; do
      if alive "$p"; then
        any=1
        break
      fi
    done
    [ -z "$any" ] && return 0
    if [ "$n" -ge "$limit" ]; then
      for p in "$@"; do
        if alive "$p"; then
          printf '  still alive: '
          ps -o pid=,ppid=,pgid=,stat=,etime=,args= -p "$p" 2>/dev/null
        fi
      done
      return 1
    fi
    sleep 0.1
    n=$((n + 1))
  done
}

# mkmacho <path> < body: a fixture that starts with the four bytes of a 64-bit Mach-O (cf fa ed fe), then a newline, then
# the shell body read from stdin. It is executable. It is NOT a Mach-O: it exists to pass the magic check of a test.
mkmacho() {
  local f="$1"
  { printf '\317\372\355\376\n'; cat; } > "$f"
  chmod +x "$f"
}

# child <code>: run code in a fresh /bin/bash with common.sh sourced and SPIKE_LIVE unset unless the caller exported it.
child() {
  /bin/bash -c '. "$1"; eval "$2"' _ "$COMMON_REAL" "$1"
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/spiketest.XXXXXX")" || exit 1
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
export TMPDIR="$SANDBOX"
unset SPIKE_LIVE
trap 'rm -rf "$SANDBOX"' EXIT

# ---- sandbox copy with the fake codesign (rule 6 tests) -------------------------------------------------------------
# The fake reads its mode from $FSDIR/mode, logs its arguments to $FSDIR/log, and picks the team by the path it is given
# (a path containing "codex" is signed by the OpenAI team, anything else by the Anthropic team).
FSDIR="$SANDBOX/fakesign"
FSCS="$FSDIR/codesign"
mkdir -p "$FSDIR"
printf 'good\n' > "$FSDIR/mode"
cat > "$FSCS" <<EOF
#!/bin/sh
echo "\$*" >> "$FSDIR/log"
MODE="\$(cat "$FSDIR/mode" 2>/dev/null)"
TEAM=Q6L2SF6YDW
case "\$*" in *codex*) TEAM=2DC432GLL2 ;; esac
case "\$MODE" in
  unsigned) echo "code object is not signed at all" >&2; exit 1 ;;
  weird) echo "weird failure" >&2; exit 3 ;;
esac
case "\$1" in
  --verify)
    case "\$3" in -R=*) [ "\$MODE" = forged ] && { echo "failed to satisfy requirement" >&2; exit 3; } ;; esac
    exit 0 ;;
  -dv)
    case "\$MODE" in
      good) printf 'Authority=Developer ID Application: Fake Dev (%s)\nAuthority=Developer ID Certification Authority\nTeamIdentifier=%s\n' "\$TEAM" "\$TEAM" >&2 ;;
      forged) printf 'Authority=Developer ID Application: Fake Dev (%s)\nTeamIdentifier=%s\n' "\$TEAM" "\$TEAM" >&2 ;;
      adhoc) printf 'Signature=adhoc\nTeamIdentifier=not set\n' >&2 ;;
      wrongteam) printf 'Authority=Developer ID Application: Evil Corp (WRONGTEAM1)\nTeamIdentifier=WRONGTEAM1\n' >&2 ;;
      notdev) printf 'Authority=Apple Development: someone (%s)\nTeamIdentifier=%s\n' "\$TEAM" "\$TEAM" >&2 ;;
    esac
    exit 0 ;;
esac
exit 1
EOF
chmod +x "$FSCS"
COMMON="$SANDBOX/ut/spike/lib/common.sh"
mkdir -p "$(dirname "$COMMON")"
sed "s|^readonly CODESIGN_BIN=.*|readonly CODESIGN_BIN=\"$FSCS\"|" "$COMMON_REAL" > "$COMMON"
has "sandbox copy points the codesign constant at the fake" "$(cat "$COMMON")" "readonly CODESIGN_BIN=\"$FSCS\""
has "the shipped common.sh keeps the fixed codesign path" "$(cat "$COMMON_REAL")" 'readonly CODESIGN_BIN="/usr/bin/codesign"'

# shellcheck disable=SC1090
. "$COMMON_REAL"

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
check "worktree add rejects a bad name" bash -c '. "$1"; ! spike_worktree_add "$2" "../evil"' _ "$COMMON_REAL" "$REPO"

spike_cleanup "$RUN"
check "cleanup removed the run dir" test ! -e "$RUN"
check "cleanup left no worktree dir" test ! -e "$REPO-wt"

# --- odd TMPDIR values -----------------------------------------------------------------------------------------------
PHYS_TMP="$(cd /tmp && pwd -P)"
eq "empty TMPDIR falls back to /tmp" "$PHYS_TMP/harness-spike" "$(TMPDIR='' spike_root)"
eq "unset TMPDIR falls back to /tmp" "$PHYS_TMP/harness-spike" "$(unset TMPDIR; spike_root)"

mkdir -p "$SANDBOX/with space"
(
  export TMPDIR="$SANDBOX/with space"
  R="$(spike_scratch_repo)" || exit 1
  W="$(spike_worktree_add "$R" beta)" || exit 1
  [ "$(git -C "$W" rev-parse --abbrev-ref HEAD)" = "spike/beta" ] || exit 1
  spike_cleanup "$(dirname "$R")" || exit 1
  [ ! -e "$(dirname "$R")" ] || exit 1
)
eq "TMPDIR with spaces: repo, worktree and cleanup work" "0" "$?"

mkdir -p "$SANDBOX/real-tmp"
ln -s "$SANDBOX/real-tmp" "$SANDBOX/link-tmp"
(
  export TMPDIR="$SANDBOX/link-tmp"
  [ "$(spike_root)" = "$SANDBOX/real-tmp/harness-spike" ] || exit 1
  R="$(spike_scratch_repo)" || exit 1
  case "$R" in "$SANDBOX/real-tmp/harness-spike/"*) ;; *) exit 1 ;; esac
  LOGICAL="$SANDBOX/link-tmp/harness-spike/$(basename "$(dirname "$R")")"
  spike_cleanup "$LOGICAL" || exit 1
  [ ! -e "$(dirname "$R")" ] || exit 1
)
eq "symlinked TMPDIR: root is physical, cleanup accepts the logical spelling" "0" "$?"

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

# --- spike_require_live (rule 1): must stop the whole calling script, not just its own subshell -----------------------
out="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_require_live; echo CONTINUED' _ "$COMMON" 2>/dev/null)"
eq "require_live exits 3 when SPIKE_LIVE is unset (rc)" "3" "$?"
lacks "require_live stops the script when unset" "$out" "CONTINUED"
for v in "0" "1 " " 1" "true" "yes" "" "01"; do
  out="$(SPIKE_LIVE="$v" /bin/bash -c '. "$1"; spike_require_live; echo CONTINUED' _ "$COMMON" 2>/dev/null)"
  rc=$?
  eq "require_live exits 3 for SPIKE_LIVE=[$v]" "3" "$rc"
  lacks "require_live stops the script for SPIKE_LIVE=[$v]" "$out" "CONTINUED"
done
out="$(SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_require_live; echo CONTINUED' _ "$COMMON" 2>/dev/null)"
eq "require_live passes when SPIKE_LIVE=1 is in the environment (rc)" "0" "$?"
has "require_live lets the script continue when SPIKE_LIVE=1" "$out" "CONTINUED"
out="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; export SPIKE_LIVE=1; spike_require_live; echo CONTINUED' _ "$COMMON" 2>/dev/null)"
has "require_live passes when SPIKE_LIVE=1 is exported later" "$out" "CONTINUED"

out="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; x="$(spike_require_live)"; echo CONTINUED' _ "$COMMON" 2>/dev/null)"
eq "require_live inside \$(...) stops the caller (rc)" "3" "$?"
lacks "require_live inside \$(...) stops the caller" "$out" "CONTINUED"
out="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_require_live | cat; echo CONTINUED' _ "$COMMON" 2>/dev/null)"
eq "require_live in a pipe stops the caller (rc)" "3" "$?"
lacks "require_live in a pipe stops the caller" "$out" "CONTINUED"
out="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; ( spike_require_live ); echo CONTINUED' _ "$COMMON" 2>/dev/null)"
eq "require_live in a subshell stops the caller (rc)" "3" "$?"
lacks "require_live in a subshell stops the caller" "$out" "CONTINUED"

# spike_run_timeout refuses a provider CLI for anything but version/status unless SPIKE_LIVE=1.
FAKE="$SANDBOX/fakecli"
mkdir -p "$FAKE"
for n in claude codex; do
  printf '#!/bin/sh\ntouch "%s/ran-$$"\nexit 0\n' "$FAKE" > "$FAKE/$n"
  chmod +x "$FAKE/$n"
done
cat > "$FAKE/claude.exe" <<EOF
#!/bin/sh
touch "$FAKE/ran-exe-\$\$"
EOF
chmod +x "$FAKE/claude.exe"
ran() { ls "$FAKE" | grep -c '^ran-'; }
rm -f "$FAKE"/ran-*
out="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/claude" -p hi; echo CONTINUED' _ "$COMMON" "$FAKE" 2>/dev/null)"
eq "run_timeout refuses a provider CLI prompt without SPIKE_LIVE (rc)" "3" "$?"
lacks "run_timeout refusal stops the caller" "$out" "CONTINUED"
eq "refused provider CLI was not started" "0" "$(ran)"
out="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/claude.exe" -p hi; echo CONTINUED' _ "$COMMON" "$FAKE" 2>/dev/null)"
eq "run_timeout also guards a claude.exe name (rc)" "3" "$?"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/codex" exec hi' _ "$COMMON" "$FAKE" 2>/dev/null
eq "run_timeout refuses codex exec without SPIKE_LIVE (rc)" "3" "$?"
eq "refused CLIs were not started" "0" "$(ran)"
# Round 4 (decision 1d): an UNVERIFIED claude/codex is refused by spike_run_timeout even for its status shapes. Only
# spike_run_status runs those, and only for a private copy that preflight registered (see the status tests below).
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/claude" --version' _ "$COMMON" "$FAKE" 2>/dev/null
eq "run_timeout refuses an unverified claude --version without SPIKE_LIVE (rc)" "3" "$?"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/claude" auth status' _ "$COMMON" "$FAKE" 2>/dev/null
eq "run_timeout refuses an unverified claude auth status without SPIKE_LIVE (rc)" "3" "$?"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/codex" login status' _ "$COMMON" "$FAKE" 2>/dev/null
eq "run_timeout refuses an unverified codex login status without SPIKE_LIVE (rc)" "3" "$?"
eq "refused unverified status calls did not start the CLIs" "0" "$(ran)"
# Round 6 (item 2): the registered copies are Mach-O-headed fixtures whose signer passes the fake pinned check.
REG="$FAKE/reg"
mkdir -p "$REG"
mkmacho "$REG/claude" <<EOF
touch "$FAKE/ran-\$\$"
exit 0
EOF
mkmacho "$REG/codex" <<EOF
touch "$FAKE/ran-\$\$"
exit 0
EOF
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2/claude" claude && spike_mark_verified "$2/codex" codex && spike_run_status 5 /dev/null "$2/claude" --version && spike_run_status 5 /dev/null "$2/claude" auth status && spike_run_status 5 /dev/null "$2/codex" login status' _ "$COMMON" "$REG" 2>/dev/null
eq "status runner runs registered verified copies (claude --version, claude auth status, codex login status) without SPIKE_LIVE (rc)" "0" "$?"
eq "allowed status calls did start the verified copies" "3" "$(ran)"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/claude" --version extra' _ "$COMMON" "$FAKE" 2>/dev/null
eq "run_timeout refuses --version with extra args (rc)" "3" "$?"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/claude" auth login' _ "$COMMON" "$FAKE" 2>/dev/null
eq "run_timeout refuses auth login (rc)" "3" "$?"
rm -f "$FAKE"/ran-*
SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/claude" -p hi' _ "$COMMON" "$FAKE" 2>/dev/null
eq "run_timeout runs a provider CLI prompt with SPIKE_LIVE=1" "0" "$?"
eq "live provider CLI was started" "1" "$(ran)"

# --- the gate is default-deny: indirect launches of a provider CLI are refused (rule 1) ------------------------------
cp "$FAKE/claude" "$FAKE/renamed"
cp "$FAKE/claude" "$FAKE/mytool"
rm -f "$FAKE"/ran-*
# denied <name> <code>: with SPIKE_LIVE unset and the fake claude first on PATH, <code> must exit 3, never reach the
# line after it, and never start the fake.
denied() {
  local name="$1" code="$2" o rc
  o="$(env -u SPIKE_LIVE PATH="$FAKE:$PATH" /bin/bash -c '. "$1"; eval "$2"; echo CONTINUED' _ "$COMMON" "$code" 2>/dev/null)"
  rc=$?
  eq "gate: $name (rc 3)" "3" "$rc"
  lacks "gate: $name (caller stopped)" "$o" "CONTINUED"
  eq "gate: $name (CLI not started)" "0" "$(ran)"
}
denied "env claude -p hi" 'spike_run_timeout 5 /dev/null env claude -p hi'
denied "/usr/bin/env claude -p hi" 'spike_run_timeout 5 /dev/null /usr/bin/env claude -p hi'
denied "sh -c 'claude -p hi'" "spike_run_timeout 5 /dev/null sh -c 'claude -p hi'"
denied "bash -c 'claude -p hi'" "spike_run_timeout 5 /dev/null bash -c 'claude -p hi'"
denied "/bin/bash -c with a path" "spike_run_timeout 5 /dev/null /bin/bash -c '$FAKE/claude -p hi'"
denied "renamed copy of claude" "spike_run_timeout 5 /dev/null '$FAKE/renamed' -p hi"
denied "renamed copy with --version" "spike_run_timeout 5 /dev/null '$FAKE/renamed' --version"
denied "unknown tool name" "spike_run_timeout 5 /dev/null '$FAKE/mytool' -p hi"
denied "upper-case CLAUDE path" "spike_run_timeout 5 /dev/null '$FAKE/CLAUDE' -p hi"
denied "upper-case Codex exec" "spike_run_timeout 5 /dev/null '$FAKE/Codex' exec hi"
denied "provider name in the args of an allowed tool (echo)" "spike_run_timeout 5 /dev/null echo CLAUDE"
denied "provider name as a path component in cat" "spike_run_timeout 5 /dev/null cat /x/codex/y"
denied "git with an alias that runs claude" "spike_run_timeout 5 /dev/null git -c 'alias.x=!claude -p hi' x"
denied "git with anything but --version" "spike_run_timeout 5 /dev/null git status"
for w in zsh dash ksh xargs nohup command exec time nice perl python python3 node ruby script expect osascript open; do
  denied "launcher '$w'" "spike_run_timeout 5 /dev/null $w claude -p hi"
done
denied "spike_run_live without SPIKE_LIVE" "spike_run_live 5 /dev/null '$FAKE/claude' -p hi"
denied "spike_run_status with a prompt" "spike_run_status 5 /dev/null '$REG/claude' -p hi"
denied "spike_run_status with --version and extra args" "spike_run_status 5 /dev/null '$REG/claude' --version -p"

# ...while the harmless shapes still work without SPIKE_LIVE.
okrun() { # okrun <name> <code>: must not be stopped by the gate
  local name="$1" code="$2" o
  o="$(env -u SPIKE_LIVE PATH="$FAKE:$PATH" /bin/bash -c '. "$1"; eval "$2"; echo CONTINUED' _ "$COMMON" "$code" 2>/dev/null)"
  has "gate allows: $name" "$o" "CONTINUED"
}
okrun "true" 'spike_run_timeout 5 /dev/null true'
okrun "echo hello" 'spike_run_timeout 5 /dev/null echo hello'
okrun "sleep" 'spike_run_timeout 5 /dev/null sleep 0'
# Round 4 (decision 1a): jq is no longer a harmless identity; it is called directly by preflight, never through the runner.
denied "jq --version needs the gate (jq left the ungated list, rule 1)" "spike_run_timeout 5 /dev/null jq --version"
okrun "git --version" 'spike_run_timeout 5 /dev/null git --version'
# Round 4 (decision 1c) and round 6 (item 3): codesign is ungated only for the read-only shapes, from a system directory,
# and only on a path that resolves inside the private verify directory. Without a system codesign (Linux) the identity
# check fails, so the shapes need the gate there.
if [ -x /usr/bin/codesign ]; then
  okrun "codesign --verify --strict <path inside the verify dir> (system codesign)" "spike_set_verify_dir '$FAKE'; spike_run_timeout 5 /dev/null codesign --verify --strict '$FAKE/claude'"
  okrun "codesign -dv --verbose=2 <path inside the verify dir> (system codesign)" "spike_set_verify_dir '$FAKE'; spike_run_timeout 5 /dev/null codesign -dv --verbose=2 '$FAKE/claude'"
else
  denied "codesign verify needs the gate when there is no system codesign (identity, rule 6)" "spike_set_verify_dir '$FAKE'; spike_run_timeout 5 /dev/null codesign --verify --strict '$FAKE/claude'"
fi
mkmacho "$REG/renamed" <<EOF
exit 0
EOF
okrun "spike_run_status of a renamed binary with --version (registered as a verified copy first)" "spike_mark_verified '$REG/renamed' claude; spike_run_status 5 /dev/null '$REG/renamed' --version"
okrun "spike_run_status of a renamed binary with login status (registered as a verified copy first)" "spike_mark_verified '$REG/renamed' claude; spike_run_status 5 /dev/null '$REG/renamed' login status"
rm -f "$FAKE"/ran-*
# Round 4 (decision 1d): the upper-case CLAUDE name no longer gets the status-shape exception in spike_run_timeout.
denied "upper-case CLAUDE --version through spike_run_timeout (unverified provider CLI, rule 6)" "spike_run_timeout 5 /dev/null '$FAKE/CLAUDE' --version"
rm -f "$FAKE"/ran-*
SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 5 /dev/null "$2/renamed" -p hi' _ "$COMMON" "$FAKE" 2>/dev/null
eq "spike_run_live runs when SPIKE_LIVE=1 (rc)" "0" "$?"
eq "spike_run_live started the command" "1" "$(ran)"
rm -f "$FAKE"/ran-*

# --- identity, not name (rule 1, decision 1a/1b): copies of harmless programs are refused outside a system directory ---
SHADOW="$SANDBOX/shadow"
mkdir -p "$SHADOW/marks"
for n in cat printf echo true codesign jq; do
  printf '#!/bin/sh\ntouch "%s/marks/%s-$$"\nexit 0\n' "$SHADOW" "$n" > "$SHADOW/$n"
  chmod +x "$SHADOW/$n"
done
marks() { ls "$SHADOW/marks" | grep -c . ; }
# shadow_denied <label> <path-prefix or -> <code>: with SPIKE_LIVE unset, <code> must exit 3, never reach the next
# statement, and start no copy (the copy would leave a marker file).
shadow_denied() {
  local name="$1" pfx="$2" code="$3" o rc
  rm -f "$SHADOW"/marks/* 2>/dev/null
  if [ "$pfx" = "-" ]; then
    o="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; eval "$2"; echo CONTINUED' _ "$COMMON" "$code" 2>/dev/null)"
  else
    o="$(env -u SPIKE_LIVE PATH="$pfx:$PATH" /bin/bash -c '. "$1"; eval "$2"; echo CONTINUED' _ "$COMMON" "$code" 2>/dev/null)"
  fi
  rc=$?
  eq "identity: $name (rc 3)" "3" "$rc"
  lacks "identity: $name (caller stopped)" "$o" "CONTINUED"
  eq "identity: $name (nothing started)" "0" "$(marks)"
}
for n in cat printf echo true codesign jq; do
  shadow_denied "copy of $n by absolute path, with a prompt" - "spike_run_timeout 5 /dev/null '$SHADOW/$n' -p hello"
  shadow_denied "copy of $n by ./relative path, with a prompt" - "cd '$SHADOW' && spike_run_timeout 5 /dev/null './$n' -p hello"
  shadow_denied "copy of $n shadowing PATH, with a prompt" "$SHADOW" "spike_run_timeout 5 /dev/null $n -p hello"
done
shadow_denied "copy of codesign shadowing PATH, verify shape" "$SHADOW" "spike_run_timeout 5 /dev/null codesign --verify --strict /x"
denied "codesign --sign - x is not ungated (rc 3)" "spike_run_timeout 5 /dev/null codesign --sign - x"
denied "codesign --remove-signature is not ungated (rc 3)" "spike_run_timeout 5 /dev/null codesign --remove-signature x"
okrun "absolute /usr/bin/true is a system binary and runs" 'spike_run_timeout 5 /dev/null /usr/bin/true'

# cs_shape <label> <1 = allowed | 0 = refused> <args...>: the codesign shape check on its own (platform independent).
cs_shape() {
  local name="$1" want="$2" rc got
  shift 2
  /bin/bash -c '. "$1"; shift; _spike_codesign_shape "$@"' _ "$COMMON" "$@" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then got=1; else got=0; fi
  eq "codesign shape: $name" "$want" "$got"
}
cs_shape "--verify --strict <path> is a read-only shape" 1 --verify --strict /x/claude
cs_shape "-dv --verbose=2 <path> is a read-only shape" 1 -dv --verbose=2 /x/claude
cs_shape "--verify --strict with the pinned -R requirement is a read-only shape" 1 --verify --strict '-R=anchor apple generic and certificate leaf[subject.OU] = "Q6L2SF6YDW"' /x/claude
cs_shape "--sign - is refused" 0 --sign - x
cs_shape "--remove-signature is refused" 0 --remove-signature x
cs_shape "--verify --strict --remove-signature is refused" 0 --verify --strict --remove-signature
cs_shape "--verify --strict <path> --remove-signature is refused" 0 --verify --strict /x --remove-signature
cs_shape "-dv --verbose=2 with an option where the path goes is refused" 0 -dv --verbose=2 --remove-signature

# --- round 6, item 3 (rule 4): the codesign path must resolve inside the private verify directory --------------------
# A canary stands in for a credential file under a fake home. Its text must never be read by the codesign checks.
VD="$SANDBOX/verifydir"
mkdir -p "$VD"
FH="$SANDBOX/fakehome"
mkdir -p "$FH/.claude"
printf 'CANARY-ROOT-9d1e\n' > "$FH/.claude/canary"
ln -s "$FH/.claude/canary" "$VD/link-to-canary"
rooted() { # rooted <label> <1|0> <verify-dir or -> <path>: _spike_codesign_rooted on its own
  local label="$1" want="$2" vd="$3" p="$4" got
  if [ "$vd" = "-" ]; then
    /bin/bash -c '. "$1"; _spike_codesign_rooted "$2"' _ "$COMMON" "$p" >/dev/null 2>&1
  else
    /bin/bash -c '. "$1"; spike_set_verify_dir "$2"; _spike_codesign_rooted "$3"' _ "$COMMON" "$vd" "$p" >/dev/null 2>&1
  fi
  if [ $? -eq 0 ]; then got=1; else got=0; fi
  eq "codesign rooted: $label" "$want" "$got"
}
rooted "a path inside the verify directory" 1 "$VD" "$VD/inside"
rooted "the verify directory itself is not a file inside it" 0 "$VD" "$VD"
rooted "a canary path under a fake home" 0 "$VD" "$FH/.claude/canary"
rooted "a symlink in the verify directory that leads to the canary" 0 "$VD" "$VD/link-to-canary"
rooted "a .. escape out of the verify directory" 0 "$VD" "$VD/../fakehome/.claude/canary"
rooted "no verify directory set: nothing is rooted" 0 - "$VD/inside"
denied "codesign --verify on a canary under a fake home is not ungated (rc 3)" "spike_set_verify_dir '$VD'; spike_run_timeout 5 /dev/null codesign --verify --strict '$FH/.claude/canary'"
denied "codesign --verify through a symlink into the fake home is not ungated (rc 3)" "spike_set_verify_dir '$VD'; spike_run_timeout 5 /dev/null codesign --verify --strict '$VD/link-to-canary'"
check "the canary was never copied or read into a verify output" bash -c '! grep -rq CANARY-ROOT "$1"' _ "$VD"

# --- spike_run_status (decision 2): only a registered verified copy, and only the three status shapes ----------------
SRS="$SANDBOX/srs.out"
o="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_status 5 "$2" /bin/sh auth status; echo CONTINUED' _ "$COMMON" "$SRS" 2>/dev/null)"
eq "spike_run_status with /bin/sh auth status is refused (rc 3)" "3" "$?"
lacks "spike_run_status with /bin/sh stops the caller" "$o" "CONTINUED"
eq "spike_run_status with /bin/sh started nothing (no output in the outfile)" "" "$(cat "$SRS" 2>/dev/null)"
o="$(SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_status 5 "$2" /bin/sh auth status; echo CONTINUED' _ "$COMMON" "$SRS" 2>/dev/null)"
eq "spike_run_status with /bin/sh is refused even with SPIKE_LIVE=1 (rc 3)" "3" "$?"
lacks "spike_run_status with /bin/sh and SPIKE_LIVE=1 stops the caller" "$o" "CONTINUED"
denied "spike_run_status with the original (unregistered) claude --version" "spike_run_status 5 /dev/null '$FAKE/claude' --version"
denied "spike_run_status with the original (unregistered) claude auth status" "spike_run_status 5 /dev/null '$FAKE/claude' auth status"
denied "spike_run_status of an unregistered renamed copy with --version" "spike_run_status 5 /dev/null '$FAKE/renamed' --version"
mkdir -p "$SANDBOX/launch"
mkmacho "$SANDBOX/launch/sh" <<EOF
touch "$FAKE/ran-\$\$"
exit 0
EOF
ln -s "$FAKE/claude" "$SANDBOX/launch/linked"
rm -f "$FAKE"/ran-*
o="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2/sh" claude && spike_run_status 5 /dev/null "$2/sh" --version; echo CONTINUED' _ "$COMMON" "$SANDBOX/launch" 2>/dev/null)"
eq "spike_run_status refuses a registered copy whose name is a launcher (rc 3)" "3" "$?"
lacks "spike_run_status refuses a registered launcher-named copy: caller stopped" "$o" "CONTINUED"
eq "spike_run_status refused the launcher-named copy: nothing started" "0" "$(ran)"
rm -f "$FAKE"/ran-*
o="$(SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_mark_verified "$2/claude" claude && spike_run_status 5 /dev/null "$2/claude" -p hi; echo CONTINUED' _ "$COMMON" "$REG" 2>/dev/null)"
eq "spike_run_status with a prompt is refused even for a registered copy and SPIKE_LIVE=1 (rc 3)" "3" "$?"
lacks "spike_run_status with a prompt stops the caller" "$o" "CONTINUED"
eq "spike_run_status with a prompt started nothing" "0" "$(ran)"
/bin/bash -c '. "$1"; spike_mark_verified relative/claude claude' _ "$COMMON" >/dev/null 2>&1
eq "spike_mark_verified refuses a relative path (rc 2)" "2" "$?"
/bin/bash -c '. "$1"; spike_mark_verified "$2/linked" claude' _ "$COMMON" "$SANDBOX/launch" >/dev/null 2>&1
eq "spike_mark_verified refuses a symlink (rc 2)" "2" "$?"
/bin/bash -c '. "$1"; spike_mark_verified "$2" claude' _ "$COMMON" "$SANDBOX/launch" >/dev/null 2>&1
eq "spike_mark_verified refuses a directory (rc 2)" "2" "$?"

# --- round 6, item 2 (rule 6): registration runs the pinned-signer check and the Mach-O magic check itself -------------
RG="$SANDBOX/regtest"
mkdir -p "$RG"
mkmacho "$RG/claude" <<EOF
touch "$FAKE/ran-\$\$"
exit 0
EOF
# regcase <label> <fake codesign mode> <cli> <path> <fixture-maker-or-empty>: registration must refuse (rc 2), and the
# status runner must then refuse the same path (rc 3) without running it.
regcase() {
  local label="$1" mode="$2" name="$3" p="$4" rc
  printf '%s\n' "$mode" > "$FSDIR/mode"
  env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" "$3"' _ "$COMMON" "$p" "$name" >/dev/null 2>&1
  rc=$?
  eq "registration refused: $label (rc 2)" "2" "$rc"
  rm -f "$FAKE"/ran-*
  env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_status 5 /dev/null "$2" --version' _ "$COMMON" "$p" >/dev/null 2>&1
  eq "registration refused: $label, so spike_run_status refuses it (rc 3)" "3" "$?"
  eq "registration refused: $label, and nothing ran" "0" "$(ran)"
}
mkmacho "$RG/unsigned" <<EOF
touch "$FAKE/ran-\$\$"
EOF
mkmacho "$RG/wrong-claude" <<EOF
touch "$FAKE/ran-\$\$"
EOF
mkmacho "$RG/adhoc-claude" <<EOF
touch "$FAKE/ran-\$\$"
EOF
mkmacho "$RG/forged-claude" <<EOF
touch "$FAKE/ran-\$\$"
EOF
mkmacho "$RG/notdev-claude" <<EOF
touch "$FAKE/ran-\$\$"
EOF
mkmacho "$RG/weird-claude" <<EOF
touch "$FAKE/ran-\$\$"
EOF
regcase "unsigned Mach-O (not signed at all)" unsigned claude "$RG/unsigned"
regcase "wrong team (Developer ID, other team)" wrongteam claude "$RG/wrong-claude"
regcase "ad-hoc signature" adhoc claude "$RG/adhoc-claude"
regcase "forged text, chain requirement fails" forged claude "$RG/forged-claude"
regcase "Apple Development authority, not Developer ID" notdev claude "$RG/notdev-claude"
regcase "codesign fails with rc 3" weird claude "$RG/weird-claude"
printf 'good\n' > "$FSDIR/mode"
# A Claude-team copy registered under the codex name is refused by the pinned team of that name.
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" codex' _ "$COMMON" "$RG/claude" >/dev/null 2>&1
eq "registration refused: a copy signed by the Anthropic team registered as codex (rc 2)" "2" "$?"
# Magic: an ELF header and a script with a Mach-O name are refused before any signer runs.
printf '\177ELF\002\001\001\000 not a mach-o\n' > "$RG/elf-claude"
chmod +x "$RG/elf-claude"
printf '#!/bin/sh\necho "%s"\n' "script with a Mach-O name" > "$RG/script-claude"
chmod +x "$RG/script-claude"
printf 'good\n' > "$FSDIR/mode"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" claude' _ "$COMMON" "$RG/elf-claude" >/dev/null 2>&1
eq "registration refused: an ELF header named claude (rc 2)" "2" "$?"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" claude' _ "$COMMON" "$RG/script-claude" >/dev/null 2>&1
eq "registration refused: a shell script with a Mach-O name (rc 2)" "2" "$?"
if [ "$(head -c 4 /bin/sh | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
  cp /bin/sh "$RG/dash-claude"
  env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" claude' _ "$COMMON" "$RG/dash-claude" >/dev/null 2>&1
  eq "registration refused: a copy of dash named claude (ELF on Linux, rc 2)" "2" "$?"
  rm -f "$FAKE"/ran-*
  env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_status 5 /dev/null "$2" --version' _ "$COMMON" "$RG/dash-claude" >/dev/null 2>&1
  eq "a dash copy named claude is never run through spike_run_status (rc 3)" "3" "$?"
fi
# Positive: a Mach-O-headed copy that passes the fake pinned signer for claude registers (rc 0). The fake codesign was asked
# about this exact copy path with the chain requirement. The status run passes the identity check and reaches exec.
printf 'good\n' > "$FSDIR/mode"
: > "$FSDIR/log"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" claude' _ "$COMMON" "$RG/claude" >/dev/null 2>&1
eq "registration accepts a Mach-O copy that passes the pinned signer (rc 0)" "0" "$?"
has "registration asked codesign about the copy path (verify)" "$(cat "$FSDIR/log")" "--verify --strict $RG/claude"
has "registration checked the chain-to-Apple requirement for the pinned team" "$(cat "$FSDIR/log")" 'anchor apple generic and certificate leaf[subject.OU] = "Q6L2SF6YDW"'
rm -f "$FAKE"/ran-*
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" claude && spike_run_status 5 /dev/null "$2" --version' _ "$COMMON" "$RG/claude" >/dev/null 2>&1
eq "registered binary passes the identity check and runs through spike_run_status (rc 0)" "0" "$?"
eq "registered binary ran once" "1" "$(ran)"

# --- round 6, item 1: resolve once, physically, and execute the resolved path --------------------------------------
# Reviewer's repro: S is a symlink to an 11-level directory, and the command is S + 14 x "/.." + "/usr/bin/printf". The
# kernel applies each '..' to the real directory, so the command is a file under the physical target. A fake printf sits
# there. The old lexical resolution saw /usr/bin/printf; the fixed resolver must see the physical file and refuse.
RR="$SANDBOX/rr"
RQ="$RR/q1/q2/q3"
RT="$RQ/c1/c2/c3/c4/c5/c6/c7/c8/c9/c10/c11"
mkdir -p "$RT" "$RR/usr/bin"
ln -s "$RT" "$RQ/S"
printf '#!/bin/sh\ntouch "%s/rr-marker"\necho FAKE-PRINTF\n' "$RR" > "$RR/usr/bin/printf"
chmod +x "$RR/usr/bin/printf"
RUPS=""
i=0
while [ "$i" -lt 14 ]; do RUPS="$RUPS/.."; i=$((i + 1)); done
RCMD="$RQ/S$RUPS/usr/bin/printf"
eq "reviewer repro resolves to the physical target, not /usr/bin/printf" "$(cd -P "$RR" && pwd -P)/usr/bin/printf" "$(spike_resolve_path "$RCMD")"
rm -f "$RR"/rr-marker
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2" hi' _ "$COMMON" "$RCMD" >/dev/null 2>&1
eq "reviewer repro with a prompt is refused (rc 3)" "3" "$?"
check "reviewer repro: the fake printf under the physical target never ran" test ! -e "$RR/rr-marker"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2" hi' _ "$COMMON" "$RCMD" >/dev/null 2>&1
eq "reviewer repro without a prompt is refused too (rc 3)" "3" "$?"
check "reviewer repro (no prompt): the fake printf never ran" test ! -e "$RR/rr-marker"
# Double slashes are normalised, so //usr//bin/printf runs the REAL printf (no false refusal).
PFOUT="$SANDBOX/pf.out"
: > "$PFOUT"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 "$2" //usr//bin/printf hello' _ "$COMMON" "$PFOUT" >/dev/null 2>&1
eq "//usr//bin/printf runs the real printf (rc 0)" "0" "$?"
has "//usr//bin/printf wrote its output" "$(cat "$PFOUT")" "hello"
eq "//usr//bin/printf resolves to /usr/bin/printf" "/usr/bin/printf" "$(spike_resolve_path //usr//bin/printf)"
# A symlink named like a harmless tool, pointing at a non-system file, is refused (the resolved target decides).
ln -s "$FAKE/claude" "$SANDBOX/alias-true"
rm -f "$FAKE"/ran-*
denied "a symlink named alias-true to a provider copy is not ungated (rc 3)" "spike_run_timeout 5 /dev/null '$SANDBOX/alias-true' --version"
# PATH TOCTOU: a directory first on PATH holds printf as a symlink to the real binary, and a fake regular file that the
# swapper puts in its place. Each run resolves printf once. The fake must never run; a run is either the real printf
# (rc 0) or a refusal (rc 3) when the fake was resolved.
TOC="$SANDBOX/toc"
mkdir -p "$TOC/first"
REALP="$(type -P printf)"
printf '#!/bin/sh\ntouch "%s/toc-marker-$$"\nexit 0\n' "$TOC" > "$TOC/fake"
chmod +x "$TOC/fake"
ln -sf "$REALP" "$TOC/first/printf"
(
  while :; do
    ln -sf "$REALP" "$TOC/first/.p.tmp" && mv -f "$TOC/first/.p.tmp" "$TOC/first/printf"
    cp "$TOC/fake" "$TOC/first/.f.tmp" && mv -f "$TOC/first/.f.tmp" "$TOC/first/printf"
  done
) >/dev/null 2>&1 &
SWAP=$!
TOC_BAD=0
TOC_BADRC=0
for i in $(seq 1 25); do
  rm -f "$TOC"/toc-marker-*
  env -u SPIKE_LIVE PATH="$TOC/first:$PATH" /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null printf toc' _ "$COMMON" >/dev/null 2>&1
  rc=$?
  case "$rc" in 0|3) ;; *) TOC_BADRC=$((TOC_BADRC + 1)) ;; esac
  for m in "$TOC"/toc-marker-*; do
    if [ -e "$m" ]; then TOC_BAD=$((TOC_BAD + 1)); fi
  done
done
kill "$SWAP" 2>/dev/null
wait "$SWAP" 2>/dev/null
eq "PATH TOCTOU: the swapped printf never ran in 25 trials (bad runs)" "0" "$TOC_BAD"
eq "PATH TOCTOU: every trial ran the resolved printf or refused (rc 0 or 3)" "0" "$TOC_BADRC"

# --- round 6, item 6: the runner body replaces the inherited traps as its FIRST statement -------------------------------
BODY_SRC="$(/bin/bash -c '. "$1"; declare -f _spike_run_timeout_body' _ "$COMMON" 2>/dev/null)"
FIRST_STMT="$(printf '%s\n' "$BODY_SRC" | sed -n '3p' | sed 's/^[[:space:]]*//')"
case "$FIRST_STMT" in
  "trap '_spike_signal 143' TERM"*) ok "item 6: the runner body's first statement replaces the TERM trap" ;;
  *) bad "item 6: the runner body's first statement replaces the TERM trap (first statement: [$FIRST_STMT])" ;;
esac

# --- round 6, item 4 (rule 4): the CLI-home test on a resolved path (the names are not written in spike/) -------------
UH="$SANDBOX/uhome"
mkdir -p "$UH/.claude" "$UH/plain/bin" "$UH/.hidden-tool" "$SANDBOX/outside-real"
ln -s "$SANDBOX/outside-real" "$UH/.linked"
uhome() { # uhome <path>: 0 if spike_under_cli_home refuses it, with HOME set to the fake home
  /bin/bash -c 'export HOME="$1"; . "$2"; spike_under_cli_home "$3"' _ "$UH" "$COMMON" "$1" >/dev/null 2>&1
}
if uhome "$UH/.claude/canary"; then ok "CLI home: a file under a dot-directory of HOME is refused"; else bad "CLI home: a file under a dot-directory of HOME is refused"; fi
if uhome "$UH/.hidden-tool/x"; then ok "CLI home: any other dot-directory of HOME is refused too (superset of the list)"; else bad "CLI home: any other dot-directory of HOME is refused too (superset of the list)"; fi
if uhome "$UH/plain/bin/claude"; then bad "CLI home: an ordinary path under HOME is not refused"; else ok "CLI home: an ordinary path under HOME is not refused"; fi
if uhome "$SANDBOX/outside-real/x"; then ok "CLI home: a dot-entry symlinked to an outside directory refuses that directory"; else bad "CLI home: a dot-entry symlinked to an outside directory refuses that directory"; fi
if uhome "$SANDBOX/other/x"; then bad "CLI home: an outside path is not refused"; else ok "CLI home: an outside path is not refused"; fi
if /bin/bash -c 'unset HOME; . "$1"; spike_under_cli_home "$2"' _ "$COMMON" "$UH/plain/bin/claude" >/dev/null 2>&1; then ok "CLI home: HOME unset fails closed (refused)"; else bad "CLI home: HOME unset fails closed (refused)"; fi

# --- spike_resolve_path / spike_run_timeout --------------------------------------------------------------------------
mkdir -p "$SANDBOX/rp/real"
printf 'x\n' > "$SANDBOX/rp/real/target"
ln -s real/target "$SANDBOX/rp/link1"
ln -s "$SANDBOX/rp/link1" "$SANDBOX/rp/link2"
eq "resolve_path follows a symlink chain" "$SANDBOX/rp/real/target" "$(spike_resolve_path "$SANDBOX/rp/link2")"

spike_run_timeout 5 /dev/null true
eq "run_timeout returns 0 for true" "0" "$?"
spike_run_timeout 5 /dev/null false
eq "run_timeout returns the command exit code" "1" "$?"
START="$(date +%s)"
spike_run_timeout 1 /dev/null sleep 5
eq "run_timeout returns 124 on timeout" "124" "$?"
check "run_timeout returned promptly" test "$(($(date +%s) - START))" -lt 4

# Environment is scrubbed (rules 2 and 4): only PATH HOME TMPDIR LANG TERM reach the child.
ENVOUT="$SANDBOX/env.out"
: > "$ENVOUT"
SPIKE_TEST_SECRET=hunter2 SPIKE_LIVE=1 USER=tu LOGNAME=tu spike_run_live 5 "$ENVOUT" env
has "run_timeout passes PATH" "$(cat "$ENVOUT")" "PATH="
has "run_timeout passes HOME" "$(cat "$ENVOUT")" "HOME="
has "run_timeout passes USER (CLIs look up their own login by account name)" "$(cat "$ENVOUT")" "USER=tu"
lacks "run_timeout drops other variables" "$(cat "$ENVOUT")" "hunter2"
lacks "run_timeout drops SPIKE_LIVE" "$(cat "$ENVOUT")" "SPIKE_LIVE"
eq "run_timeout passes exactly 7 variables" "7" "$(wc -l < "$ENVOUT" | tr -d ' ')"

# Closed set: whatever is exported in the caller (generic probes shaped like keys, homes and config dirs), the child sees
# only HOME LANG LOGNAME PATH TERM TMPDIR USER (plus PWD SHLVL _ when a shell starts it).
closed_set_check() { # closed_set_check <label> <file>
  local label="$1" f="$2" line name stray=""
  while IFS= read -r line; do
    name="${line%%=*}"
    case "$name" in
      HOME|LANG|LOGNAME|PATH|TERM|TMPDIR|USER|PWD|SHLVL|_) ;;
      *) stray="$stray $name" ;;
    esac
  done < "$f"
  if [ -z "$stray" ]; then ok "$label: child environment is inside the closed set"; else bad "$label: stray variables:$stray"; fi
}
export FOO_API_KEY=k1 FOO_HOME=/h FOO_CONFIG_DIR=/c BAR_TOKEN=t2 HTTPS_PROXY=http://p SSH_AUTH_SOCK=/s XDG_CONFIG_HOME=/x
: > "$ENVOUT"
SPIKE_LIVE=1 spike_run_live 5 "$ENVOUT" env
closed_set_check "env" "$ENVOUT"
lacks "probe FOO_API_KEY is not passed" "$(cat "$ENVOUT")" "FOO_API_KEY"
lacks "probe FOO_HOME is not passed" "$(cat "$ENVOUT")" "FOO_HOME"
lacks "probe FOO_CONFIG_DIR is not passed" "$(cat "$ENVOUT")" "FOO_CONFIG_DIR"
: > "$ENVOUT"
SPIKE_LIVE=1 spike_run_live 5 "$ENVOUT" /bin/sh -c env
closed_set_check "sh -c env" "$ENVOUT"
: > "$ENVOUT"
SPIKE_LIVE=1 spike_run_live 5 "$ENVOUT" /bin/bash -c env
closed_set_check "bash -c env" "$ENVOUT"
unset FOO_API_KEY FOO_HOME FOO_CONFIG_DIR BAR_TOKEN HTTPS_PROXY SSH_AUTH_SOCK XDG_CONFIG_HOME

# The whole process group dies on timeout: a launcher that spawns a grandchild leaves no orphan.
cat > "$SANDBOX/launcher.sh" <<EOF
#!/bin/sh
sleep 30 &
echo \$! > "$SANDBOX/grandchild.pid"
wait
EOF
chmod +x "$SANDBOX/launcher.sh"
rm -f "$SANDBOX/grandchild.pid"
SPIKE_LIVE=1 spike_run_live 1 /dev/null "$SANDBOX/launcher.sh"
eq "run_timeout times out a launcher (rc)" "124" "$?"
GC="$(cat "$SANDBOX/grandchild.pid" 2>/dev/null)"
check "launcher wrote its grandchild pid" test -n "$GC"
if gone_within 30 "$GC"; then
  ok "grandchild was killed with the launcher"
else
  bad "grandchild was killed with the launcher"
  kill -9 "$GC" 2>/dev/null
fi

# A command that exits normally but leaves a background child is swept too.
cat > "$SANDBOX/leaver.sh" <<EOF
#!/bin/sh
sleep 30 </dev/null >/dev/null 2>&1 &
echo \$! > "$SANDBOX/leftover.pid"
exit 0
EOF
chmod +x "$SANDBOX/leaver.sh"
SPIKE_LIVE=1 spike_run_live 5 /dev/null "$SANDBOX/leaver.sh"
eq "run_timeout returns the leaver's exit code" "0" "$?"
LO="$(cat "$SANDBOX/leftover.pid" 2>/dev/null)"
if gone_within 30 "$LO"; then
  ok "leftover background child was swept"
else
  bad "leftover background child was swept"
  kill -9 "$LO" 2>/dev/null
fi

# Controls for alive(): a running process is alive, and a zombie (exited, parent has not reaped it) is not.
sleep 5 &
RUNPID=$!
check "alive: a running process is alive" alive "$RUNPID"
kill -9 "$RUNPID" 2>/dev/null
{ wait "$RUNPID"; } 2>/dev/null
rm -f "$SANDBOX/zombie.pid"
perl -e 'my $p = fork; exit 0 unless $p; open my $f, ">", $ARGV[0] or exit 1; print $f "$p\n"; close $f; sleep 6' \
  "$SANDBOX/zombie.pid" </dev/null >/dev/null 2>&1 &
ZP=$!
n=0
while [ ! -s "$SANDBOX/zombie.pid" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
ZCHILD="$(cat "$SANDBOX/zombie.pid" 2>/dev/null)"
sleep 0.3
check "zombie fixture wrote its pid" test -n "$ZCHILD"
case "$(ps -o stat= -p "$ZCHILD" 2>/dev/null)" in
  Z*) ok "zombie fixture is in state Z" ;;
  *) bad "zombie fixture is in state Z" ;;
esac
if [ -n "$ZCHILD" ] && alive "$ZCHILD"; then bad "alive: a zombie is not alive"; else ok "alive: a zombie is not alive"; fi
kill -9 "$ZP" 2>/dev/null
{ wait "$ZP"; } 2>/dev/null

# Signals sent to the caller must not leave the command (or its grandchild) running.
for sig in TERM HUP; do
  rm -f "$SANDBOX/sig.pids"
  cat > "$SANDBOX/siglauncher.sh" <<EOF
#!/bin/sh
sleep 33 &
echo "\$\$ \$!" > "$SANDBOX/sig.pids.tmp"
mv "$SANDBOX/sig.pids.tmp" "$SANDBOX/sig.pids"
wait
EOF
  chmod +x "$SANDBOX/siglauncher.sh"
  SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 60 /dev/null "$2"; echo AFTER' _ "$COMMON" "$SANDBOX/siglauncher.sh" > "$SANDBOX/sig.out" 2>/dev/null &
  CALLER=$!
  n=0
  while [ ! -s "$SANDBOX/sig.pids" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  read -r LPID GPID < "$SANDBOX/sig.pids"
  if alive "$LPID" && alive "$GPID"; then ok "SIG$sig: launcher and grandchild are running before the signal"; else bad "SIG$sig: launcher and grandchild are running before the signal"; fi
  kill -s "$sig" "$CALLER"
  wait "$CALLER" 2>/dev/null
  RC=$?
  if gone_within 30 "$LPID"; then ok "SIG$sig to the caller: launcher is gone"; else bad "SIG$sig to the caller: launcher is gone"; kill -9 "$LPID" 2>/dev/null; fi
  if gone_within 30 "$GPID"; then ok "SIG$sig to the caller: grandchild is gone"; else bad "SIG$sig to the caller: grandchild is gone"; kill -9 "$GPID" 2>/dev/null; fi
  if alive "$CALLER"; then bad "SIG$sig to the caller: caller exited"; kill -9 "$CALLER" 2>/dev/null; else ok "SIG$sig to the caller: caller exited"; fi
  lacks "SIG$sig to the caller: nothing ran afterwards" "$(cat "$SANDBOX/sig.out")" "AFTER"
  check "SIG$sig to the caller: exit status is a signal status" test "$RC" -gt 128
done

# Orphan sweep (decision 4): the caller is killed with SIGKILL, so no trap can run. The runner must notice that its caller
# is gone and kill the command's group: the CLI and its grandchild must be gone within 3 s (bounded poll, gone_within).
cat > "$SANDBOX/orphan.sh" <<EOF
#!/bin/sh
sleep 33 &
echo "\$\$ \$!" > "$SANDBOX/orphan.pids.tmp"
mv "$SANDBOX/orphan.pids.tmp" "$SANDBOX/orphan.pids"
wait
EOF
chmod +x "$SANDBOX/orphan.sh"
rm -f "$SANDBOX/orphan.pids"
SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 60 /dev/null "$2"; echo AFTER' _ "$COMMON" "$SANDBOX/orphan.sh" > "$SANDBOX/orphan.out" 2>/dev/null &
ORPHAN_CALLER=$!
n=0
while [ ! -s "$SANDBOX/orphan.pids" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
OLPID=""
OGPID=""
read -r OLPID OGPID < "$SANDBOX/orphan.pids" 2>/dev/null
if [ -n "$OLPID" ] && [ -n "$OGPID" ] && alive "$OLPID" && alive "$OGPID"; then
  ok "orphan fixture: the launcher and its grandchild run before the caller is killed"
else
  bad "orphan fixture: the launcher and its grandchild run before the caller is killed"
fi
kill -9 "$ORPHAN_CALLER" 2>/dev/null
if gone_within 30 "$OLPID"; then ok "orphan sweep: the CLI launcher is gone within 3 s of kill -9 of its caller"; else bad "orphan sweep: the CLI launcher is gone within 3 s of kill -9 of its caller"; kill -9 "$OLPID" 2>/dev/null; fi
if gone_within 30 "$OGPID"; then ok "orphan sweep: the grandchild is gone within 3 s of kill -9 of its caller"; else bad "orphan sweep: the grandchild is gone within 3 s of kill -9 of its caller"; kill -9 "$OGPID" 2>/dev/null; fi
{ wait "$ORPHAN_CALLER"; } 2>/dev/null
lacks "orphan sweep: the killed caller ran no further statement" "$(cat "$SANDBOX/orphan.out")" "AFTER"

# Signal race (decision 5). The window between `&` and `$!` is a few microseconds, so the handler is tested directly:
# a signal that arrives before the pid is known is recorded and nothing exits; once the pid is known, the group is killed
# and the handler exits with the signal status.
out="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; _SPIKE_CHILD_PID=""; _spike_signal 143; echo "PENDING=$_SPIKE_PENDING"; echo CONTINUED' _ "$COMMON" 2>/dev/null)"
eq "signal before the pid is known: the handler does not exit (rc)" "0" "$?"
has "signal before the pid is known: it is recorded for the handoff" "$out" "PENDING=143"
has "signal before the pid is known: execution continues to the handoff" "$out" "CONTINUED"
out="$(/bin/bash -c '. "$1"; sleep 30 & _SPIKE_CHILD_PID=$!; echo "PID=$_SPIKE_CHILD_PID"; _spike_signal 143; echo LATE' _ "$COMMON" 2>/dev/null)"
eq "signal after the pid is known: exits with the signal status (rc)" "143" "$?"
lacks "signal after the pid is known: nothing runs after the handler" "$out" "LATE"
SIGPID="$(printf '%s\n' "$out" | sed -n 's/^PID=//p')"
if gone_within 30 "$SIGPID"; then ok "signal after the pid is known: the command is gone"; else bad "signal after the pid is known: the command is gone"; kill -9 "$SIGPID" 2>/dev/null; fi
out="$(/bin/bash -c '. "$1"; _spike_forward 143; echo "PEND=$_SPIKE_BG_PENDING"' _ "$COMMON" 2>/dev/null)"
has "caller: a signal before the runner exists is recorded for the handoff" "$out" "PEND=143"

# Stress (decision 5): TERM or HUP sent right after the start of a live run leaves no command running. This exercises the
# path; it does not prove the few-microsecond window is hit on every run.
cat > "$SANDBOX/strl.sh" <<EOF
#!/bin/sh
sleep 33 &
echo "\$\$ \$!" > "$SANDBOX/strl.pids.tmp"
mv "$SANDBOX/strl.pids.tmp" "$SANDBOX/strl.pids"
wait
EOF
chmod +x "$SANDBOX/strl.sh"
STRESS_BAD=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  rm -f "$SANDBOX/strl.pids"
  if [ $((i % 2)) -eq 0 ]; then sig=HUP; else sig=TERM; fi
  SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 30 /dev/null "$2"' _ "$COMMON" "$SANDBOX/strl.sh" >/dev/null 2>&1 &
  STC=$!
  kill -s "$sig" "$STC" 2>/dev/null
  wait "$STC" 2>/dev/null
  # Reset first: read leaves the variables alone when the file is missing (the launcher had not started yet).
  SL=""
  SG=""
  read -r SL SG < "$SANDBOX/strl.pids" 2>/dev/null
  # Bounded poll of up to 3.0 s instead of a fixed sleep. ours() is zombie-aware and matches the command line, so a reused
  # pid does not count.
  n=0
  while [ "$n" -lt 30 ] && { ours "$SL" strl.sh || ours "$SG" "sleep 33"; }; do sleep 0.1; n=$((n + 1)); done
  if ours "$SL" strl.sh || ours "$SG" "sleep 33"; then
    STRESS_BAD=$((STRESS_BAD + 1))
    echo "stress survivor (iteration $i, signal $sig): launcher=$SL grandchild=$SG"
    for p in "$SL" "$SG"; do
      if [ -n "$p" ]; then
        printf '  still alive: '
        ps -o pid=,ppid=,pgid=,stat=,etime=,args= -p "$p" 2>/dev/null
      fi
    done
    kill -9 "$SL" "$SG" 2>/dev/null
  fi
done
eq "stress: no command survives a TERM or HUP sent right after the start (bad runs of 10)" "0" "$STRESS_BAD"

# The caller's own TERM trap is restored after a run.
out="$(SPIKE_LIVE=1 /bin/bash -c '. "$1"; trap "echo MYTRAP" TERM; spike_run_live 5 /dev/null true; trap -p TERM' _ "$COMMON" 2>/dev/null)"
has "caller TERM trap is restored after spike_run_live" "$out" "echo MYTRAP"

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

CAPREPO="$SANDBOX/caprepo"
mkdir -p "$CAPREPO"
git -C "$CAPREPO" init -q
SPIKE_CAPTURES_ROOT="$CAPREPO/captures" spike_capture_dir demo >/dev/null 2>&1
eq "capture dir refuses a root inside a repo that does not ignore it (rc)" "2" "$?"
check "refused capture root was not created" test ! -e "$CAPREPO/captures"
printf 'captures/\n' > "$CAPREPO/.gitignore"
CAP2="$(SPIKE_CAPTURES_ROOT="$CAPREPO/captures" spike_capture_dir demo)"
eq "capture dir accepts a root inside a repo when git ignores it (rc)" "0" "$?"
check "ignored capture dir exists" test -d "$CAP2"
# This test uses the shared default root spike/captures, so the suite must not run concurrently in one worktree.
CAP3="$(unset SPIKE_CAPTURES_ROOT; spike_capture_dir selftest)"
eq "default capture root (spike/captures) is accepted (ignored by spike/.gitignore)" "0" "$?"
case "$CAP3" in "$HERE/../captures/selftest/"*|"$(cd "$HERE/.." && pwd -P)/captures/selftest/"*) rm -rf "$CAP3" ;; esac
rmdir "$(cd "$HERE/.." && pwd -P)/captures/selftest" 2>/dev/null
rmdir "$(cd "$HERE/.." && pwd -P)/captures" 2>/dev/null
unset SPIKE_CAPTURES_ROOT

# --- spike_redact ----------------------------------------------------------------------------------------------------
U1="3f2b8c1e-9a4d-4e7b-8c55-0123456789ab"
U2="AAAAAAAA-bbbb-4ccc-8ddd-eeeeeeeeeeee"
LINE="session $U1 and $U2 and $U1 again at $HOME/projects/secret/file.txt, mail jane.doe+x@example.com; wt $ROOT/run-1/repo-wt/a/file"
OUT="$(printf '%s\n' "$LINE" | spike_redact)"
lacks "redact removes UUID 1" "$OUT" "$U1"
lacks "redact removes UUID 2" "$OUT" "$U2"
has "redact numbers ids stably (same id, same number)" "$OUT" "session <ID-1> and <ID-2> and <ID-1> again"
has 'redact rewrites a $HOME path to $HOME/...' "$OUT" 'at $HOME/...,'
lacks "redact hides the home path tail" "$OUT" "projects/secret"
has "redact rewrites an email to <EMAIL>" "$OUT" "mail <EMAIL>;"
has "redact rewrites the scratch run dir to <WORKTREE>" "$OUT" "wt <WORKTREE>/repo-wt/a/file"
lacks "redacted output has no @" "$OUT" "@"
OUT2="$(printf '%s\n' "id $U2 only" | spike_redact)"
eq "redact numbering restarts per invocation" "id <ID-1> only" "$OUT2"

# Cases below use a fixed fake home so they behave the same on every machine.
red() { printf '%s\n' "$1" | HOME=/Users/tester spike_redact; }
redcase() { # redcase <name> <input> <leaked-substring>
  local o
  o="$(red "$2")"
  lacks "redact: $1" "$o" "$3"
}
redcase "file:// URL" 'see file:///Users/tester/a.txt now' 'a.txt'
has "redact: file:// URL keeps the scheme" "$(red 'see file:///Users/tester/a.txt now')" 'file://$HOME/... now'
redcase "JSON-escaped newline before the path" 'x\n/Users/tester/secret\nnext' 'secret'
has "redact: JSON-escaped newline keeps the escapes" "$(red 'x\n/Users/tester/secret\nnext')" 'x\n$HOME/...\nnext'
redcase "JSON-escaped slashes" '{"cwd":"\/Users\/tester\/secret"}' 'secret'
redcase "stream-json line" '{"type":"system","cwd":"/Users/tester/work/proj","session_id":"x"}' 'work/proj'
has "redact: stream-json line stays parseable JSON" "$(red '{"type":"system","cwd":"/Users/tester/work/proj","k":1}' | jq -c .cwd)" '"$HOME/..."'
eq "redact: home at end of sentence" 'cwd is $HOME/....' "$(red 'cwd is /Users/tester.')"
eq "redact: single-quoted home" "q '\$HOME/...' end" "$(red "q '/Users/tester' end")"
eq "redact: bracketed home" 'in [$HOME/...] end' "$(red 'in [/Users/tester] end')"
eq "redact: paren home path" 'at ($HOME/...) end' "$(red 'at (/Users/tester/a/b) end')"
redcase "path with a space" 'open /Users/tester/My Docs/secret now' 'secret'
redcase "path with two spaces" 'open /Users/tester/My Big Docs/secret.txt, then' 'secret'
has "redact: path with a space keeps the rest of the line" "$(red 'open /Users/tester/My Docs/secret now')" 'open $HOME/... now'
redcase "another user's home" 'see /Users/other/private/key.pem' 'private'
has "redact: another user's home is generic" "$(red 'see /Users/other/private/key.pem')" '/Users/<USER>/...'
redcase "lookalike of my home (different user name)" 'x /Users/testerx/not-home y' 'not-home'
redcase "linux-style home" 'x /home/alice/.ssh/id y' 'alice'
redcase "email at localhost" 'mail jane@localhost now' 'jane'
redcase "email at a bare host" 'mail bob@corp now' 'bob'
redcase "email with one-letter parts" 'mail a@b.c now' 'a@b.c'
redcase "email with non-ASCII local part" 'mail josé@exämple.org now' 'jos'
redcase "user@host" 'ssh deploy@build-box now' 'deploy'
has "redact: email becomes <EMAIL>" "$(red 'mail jane@localhost now')" 'mail <EMAIL> now'
eq "redact: hyphenless 32-hex id" 'id <ID-1> and <ID-1> and <ID-2>' "$(red 'id 0123456789abcdef0123456789ABCDEF and 0123456789abcdef0123456789abcdef and 3f2b8c1e9a4d4e7b8c550123456789ab')"
eq "redact: dashed and hyphenless forms of one id share a number" 'a <ID-1> b <ID-1>' "$(red 'a 3f2b8c1e-9a4d-4e7b-8c55-0123456789ab b 3f2b8c1e9a4d4e7b8c550123456789ab')"
SHA40="0123456789abcdef0123456789abcdef01234567"
eq "redact: a 40-hex git sha is not an id" "commit $SHA40" "$(red "commit $SHA40")"
eq "redact: plain text is untouched" "hello world: 3 files changed" "$(red 'hello world: 3 files changed')"
eq "redact: a lone @ is untouched" "use @ sign" "$(red 'use @ sign')"
eq "redact: redacting twice changes nothing more" "$(red 'a /Users/other/x b jane@x.io')" "$(red 'a /Users/other/x b jane@x.io' | spike_redact)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
