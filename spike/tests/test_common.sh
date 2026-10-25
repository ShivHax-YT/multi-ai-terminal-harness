#!/bin/bash
# Tests for spike/lib/common.sh and spike/lib/runner.pl. Run: /bin/bash spike/tests/test_common.sh  (exit 0 = all passed)
# Uses a private TMPDIR so it never touches a real spike run.
#
# Round 7 SANDBOX GUARD (a round-6 fixture once overwrote a system tool through a symlink):
#   - set -o noclobber; every fixture write goes through sbx_put, which refuses a relative path, a physical parent outside
#     $SANDBOX, an existing symlink and a file with more than one link; symlinks are made with sbx_ln (ln -sfn) and copies
#     with sbx_cp. A refusal is a FAIL and the suite fails.
#   - destructive negative tests (spike_cleanup on / and on the real $HOME) run with rm shadowed by a recorder, and the
#     decoy variants point at directories inside the sandbox.
#   - an EXIT tripwire hashes the host tools this suite runs and fails the suite if any of them changed.
#
# Child shells source a SANDBOX COPY of common.sh and runner.pl whose only change is the codesign constant of runner.pl,
# pointed at a fake codesign. The main shell sources the real file. No real codesign or provider CLI is run here.
# Fixtures that must "run" are Mach-O-headed shell scripts: on Linux exec hands a file it cannot load to /bin/sh (the
# execvp ENOEXEC fallback), so their bodies run; this is test-only and says nothing about real Mach-O files.

set -o noclobber

HERE="$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
COMMON_REAL="$HERE/../lib/common.sh"
RUNNER_REAL="$HERE/../lib/runner.pl"

# Host tools are found once with the caller's PATH; then PATH is pinned so a provider CLI directory (for example one that
# holds the real claude) is never on it.
JQ_BIN="$(command -v jq)"
if [ -z "$JQ_BIN" ]; then echo "jq is required to run this suite" >&2; exit 1; fi
PATH="/usr/bin:/bin:$(dirname -- "$JQ_BIN")"
export PATH

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

# ---- sandbox and guard ------------------------------------------------------------------------------------------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/spiketest.XXXXXX")" || exit 1
SANDBOX="$(CDPATH='' cd -P -- "$SANDBOX" && pwd -P)"
export TMPDIR="$SANDBOX"
unset SPIKE_LIVE
VIOLATIONS="$SANDBOX/.violations"
TRIP_LIST=""

sha_of() { /usr/bin/perl -MDigest::SHA -e 'open my $f, "<", $ARGV[0] or exit 1; binmode $f; print Digest::SHA->new(256)->addfile($f)->hexdigest' -- "$1"; }
link_count() { /usr/bin/perl -e 'my @s = stat($ARGV[0]); print $s[3]' -- "$1"; }
trip_add() { # trip_add <host tool name>: remember the hash of the file the name resolves to
  local p
  p="$(command -v "$1")" || return 0
  case "$p" in /*) ;; *) return 0 ;; esac
  TRIP_LIST="$TRIP_LIST$p $(sha_of "$p")
"
}
trip_check() {
  local line p h now bad_n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    p="${line% *}"
    h="${line##* }"
    now="$(sha_of "$p")"
    if [ "$now" != "$h" ]; then
      printf 'FAIL host tool changed during the run: %s\n' "$p"
      bad_n=$((bad_n + 1))
    fi
  done <<EOF
$TRIP_LIST
EOF
  return "$bad_n"
}
for t in bash env perl git jq awk sed tr cut head od cat cp mv ln chmod mkdir rm touch printf true false sleep ls date mktemp seq wc ps grep dirname basename kill id; do trip_add "$t"; done

MAIN_PID="${BASHPID:-$$}"
finish() {
  local rc=$? viol=0
  [ "${BASHPID:-$$}" = "$MAIN_PID" ] || return 0   # a forked subshell signalled before it execs must not remove the sandbox
  trip_check
  local trc=$?
  if [ -s "$VIOLATIONS" ]; then viol=1; printf 'FAIL the sandbox guard refused a write:\n'; cat "$VIOLATIONS"; fi
  rm -rf "$SANDBOX"
  if [ "$trc" -ne 0 ] || [ "$viol" -ne 0 ]; then
    [ "$rc" -ne 0 ] || exit 1
  fi
}
trap finish EXIT

# A refusal is recorded in a file because sbx_put usually runs in a pipeline (a subshell).
sbx_refuse() { printf 'sandbox guard refused: %s\n' "$1" >> "$VIOLATIONS"; return 1; }
sbx_parent_ok() { # sbx_parent_ok <path>: the PHYSICAL parent directory must be inside the sandbox
  local f="$1" dir phys
  case "$f" in /*) ;; *) sbx_refuse "relative path $f"; return 1 ;; esac
  dir="${f%/*}"
  [ -n "$dir" ] || dir="/"
  phys="$(CDPATH='' cd -P -- "$dir" 2>/dev/null && pwd -P)" || { sbx_refuse "no parent for $f"; return 1; }
  case "$phys/" in "$SANDBOX"/*) ;; *) sbx_refuse "parent of $f is outside the sandbox ($phys)"; return 1 ;; esac
  return 0
}
sbx_put() { # sbx_put <file>: stdin -> file (inside the sandbox only; never through a symlink or a hard link)
  local f="$1"
  sbx_parent_ok "$f" || { cat >/dev/null; return 1; }
  if [ -L "$f" ]; then sbx_refuse "$f is a symlink"; cat >/dev/null; return 1; fi
  if [ -e "$f" ] && [ "$(link_count "$f")" != "1" ]; then sbx_refuse "$f has more than one link"; cat >/dev/null; return 1; fi
  cat >| "$f"
}
sbx_ln() { # sbx_ln <target> <link>: ln -sfn into the sandbox
  sbx_parent_ok "$2" || return 1
  ln -sfn -- "$1" "$2"
}
sbx_cp() { # sbx_cp <src> <dst>: a copy that cannot write through a link; keeps the executable bit
  sbx_put "$2" < "$1" || return 1
  chmod +x "$2"
}
sbx_mkdir() { # sbx_mkdir <dir>...: mkdir -p, but the nearest EXISTING ancestor must physically be inside the sandbox
  local d anc phys
  for d in "$@"; do
    case "$d" in /*) ;; *) sbx_refuse "relative directory $d"; return 1 ;; esac
    anc="$d"
    while [ ! -d "$anc" ] && [ "$anc" != "/" ]; do
      anc="${anc%/*}"
      [ -n "$anc" ] || anc="/"
    done
    phys="$(CDPATH='' cd -P -- "$anc" 2>/dev/null && pwd -P)" || { sbx_refuse "no ancestor for $d"; return 1; }
    case "$phys/" in "$SANDBOX"/*) ;; *) sbx_refuse "directory $d resolves outside the sandbox ($phys)"; return 1 ;; esac
    mkdir -p -- "$d"
  done
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

# ours <pid> <pattern>: 0 if <pid> is alive and not a zombie AND its command line contains <pattern>.
ours() {
  [ -n "$1" ] || return 1
  alive "$1" || return 1
  case "$(ps -o args= -p "$1" 2>/dev/null)" in *"$2"*) return 0 ;; esac
  return 1
}

# gone_within <tenths> <pid>...: poll alive() every 0.1 s and return 0 as soon as none of the pids is alive. After <tenths>
# tenths of a second with a pid still alive, return 1 and print one ps line per survivor.
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
  { printf '\317\372\355\376\n'; cat; } | sbx_put "$1"
  chmod +x "$1"
}

# ---- sandbox copy with the fake codesign (rule 6 tests) -------------------------------------------------------------
# The fake reads its mode from $FSDIR/mode and logs its arguments to $FSDIR/log. It picks the signing team from a
# "signer: codex" marker in the CONTENT of the target (the last argument), else from the BASENAME of that argument
# (names starting with codex are signed by the OpenAI team, anything else by the Anthropic team). It never looks at the rest
# of the command line: the sandbox path contains the word claude.
FSDIR="$SANDBOX/fakesign"
FSCS="$FSDIR/codesign"
sbx_mkdir "$FSDIR"
printf 'good\n' | sbx_put "$FSDIR/mode"
fsmode() { printf '%s\n' "$1" | sbx_put "$FSDIR/mode"; }
sbx_put "$FSCS" <<EOF
#!/bin/sh
echo "\$*" >> "$FSDIR/log"
echo "HOME=\$HOME" >> "$FSDIR/homelog"
MODE="\$(cat "$FSDIR/mode" 2>/dev/null)"
for a in "\$@"; do last="\$a"; done
base="\${last##*/}"
TEAM=Q6L2SF6YDW
case "\$base" in codex*) TEAM=2DC432GLL2 ;; esac
if [ -f "\$last" ]; then
  case "\$(cat "\$last" 2>/dev/null)" in *"signer: codex"*) TEAM=2DC432GLL2 ;; *"signer: claude"*) TEAM=Q6L2SF6YDW ;; esac
fi
case "\$MODE" in
  unsigned) echo "code object is not signed at all" >&2; exit 1 ;;
  weird) echo "weird failure" >&2; exit 3 ;;
  slow) sleep 2 ;;
  hang) sleep 30 & echo "\$\$ \$!" > "$FSDIR/cs.pids"; wait ;;
esac
case "\$1" in
  --verify)
    case "\$3" in -R=*) [ "\$MODE" = forged ] && { echo "failed to satisfy requirement" >&2; exit 3; } ;; esac
    exit 0 ;;
  -dv)
    case "\$MODE" in
      good|slow) printf 'Authority=Developer ID Application: Fake Dev (%s)\nAuthority=Developer ID Certification Authority\nTeamIdentifier=%s\n' "\$TEAM" "\$TEAM" >&2 ;;
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
UTLIB="$SANDBOX/ut/spike/lib"
sbx_mkdir "$UTLIB"
COMMON="$UTLIB/common.sh"
RUNNER="$UTLIB/runner.pl"
sbx_cp "$COMMON_REAL" "$COMMON"
sed "s|^use constant CODESIGN_BIN => .*|use constant CODESIGN_BIN => \"$FSCS\";|" "$RUNNER_REAL" | sbx_put "$RUNNER"
# Round 8: runner.pl reads compliance/denylist.txt from the repo layout around its own physical path (<root>/spike/lib/ ->
# <root>/compliance/), so every sandbox copy of the layout carries a copy of the lead-owned file.
DENYLIST_REAL="$HERE/../../compliance/denylist.txt"
if [ -f "$DENYLIST_REAL" ]; then ok "the lead-owned compliance/denylist.txt exists"; else bad "the lead-owned compliance/denylist.txt exists"; fi
sbx_mkdir "$SANDBOX/ut/compliance"
sbx_put "$SANDBOX/ut/compliance/denylist.txt" < "$DENYLIST_REAL"
# A second sandbox layout (ut2) whose "account home" is the fake home $FH: a run is refused unless HOME is the account home,
# so the tests of runs that need a fake CLI home use this copy. Only the codesign constant and the one-line account_home differ.
FH="$SANDBOX/fakehome"
sbx_mkdir "$FH" "$SANDBOX/ut2/spike/lib" "$SANDBOX/ut2/compliance"
COMMON2="$SANDBOX/ut2/spike/lib/common.sh"
RUNNER2="$SANDBOX/ut2/spike/lib/runner.pl"
sbx_cp "$COMMON_REAL" "$COMMON2"
sed -e "s|^use constant CODESIGN_BIN => .*|use constant CODESIGN_BIN => \"$FSCS\";|" -e "s|^sub account_home .*|sub account_home { return \"$FH\"; }|" "$RUNNER_REAL" | sbx_put "$RUNNER2"
sbx_put "$SANDBOX/ut2/compliance/denylist.txt" < "$DENYLIST_REAL"
has "sandbox runner.pl points the codesign constant at the fake" "$(cat "$RUNNER")" "use constant CODESIGN_BIN => \"$FSCS\";"
eq "the sandbox runner.pl differs from the shipped one only in the codesign constant (2 changed lines)" "2" "$(diff "$RUNNER_REAL" "$RUNNER" | grep -c '^[<>]')"
eq "the ut2 runner.pl differs from the shipped one only in the codesign constant and account_home (4 changed lines)" "4" "$(diff "$RUNNER_REAL" "$RUNNER2" | grep -c '^[<>]')"
has "the shipped runner.pl takes the account home from the password database" "$(cat "$RUNNER_REAL")" 'sub account_home { my @pw = getpwuid($<); return $pw[7]; }'
has "the shipped runner.pl keeps the fixed codesign path" "$(cat "$RUNNER_REAL")" 'use constant CODESIGN_BIN => "/usr/bin/codesign";'
lacks "the shipped common.sh defines no codesign constant" "$(cat "$COMMON_REAL")" "readonly CODESIGN_BIN"
for f in "$COMMON_REAL" "$HERE/../preflight.sh" "$HERE/test_common.sh" "$HERE/test_preflight.sh"; do
  case "$(head -n 1 "$f")" in
    "#!/bin/bash") ok "shebang is /bin/bash (no PATH lookup for the interpreter): $(basename "$f")" ;;
    *) bad "shebang is /bin/bash (no PATH lookup for the interpreter): $(basename "$f")" ;;
  esac
done
eq "the helper's shebang is the constant /usr/bin/perl" "#!/usr/bin/perl" "$(head -n 1 "$RUNNER_REAL")"
eq "no shipped script uses env to find an interpreter" "0" "$(grep -c 'usr/bin/env \(bash\|perl\|sh\)' "$COMMON_REAL" "$HERE/../preflight.sh" "$RUNNER_REAL" | awk -F: '{s += $2} END {print s + 0}')"
eq "common.sh starts no program named perl by name (only the constant interpreter path)" "0" "$(grep -v '^[[:space:]]*#' "$COMMON_REAL" | grep -Ec '(^|[ ;(`|])perl([ ]|$)')"

# shellcheck disable=SC1090
. "$COMMON_REAL"

# libp <perl expression> [args...]: run runner.pl as a LIBRARY (it only defines functions when loaded) and print the result.
libp() {
  local code="$1"
  shift
  /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /usr/bin/perl -e 'my $c = shift; my $f = shift; require $f; my @r = eval $c; die $@ if $@; print join("|", @r), "\n"' "$code" "$RUNNER_REAL" "$@"
}
libt() { # libt <perl expression> [args...]: exit status 0 when the expression is true
  local code="$1"
  shift
  /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /usr/bin/perl -e 'my $c = shift; my $f = shift; require $f; my $r = eval $c; die $@ if $@; exit($r ? 0 : 1)' "$code" "$RUNNER_REAL" "$@"
}
# rawhelper <subcommand> [args...]: the sandbox helper started like common.sh starts it, with TMPDIR in the sandbox.
rawhelper() {
  /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C SPIKE_IN_PATH="$PATH" SPIKE_IN_TMPDIR="$SANDBOX" SPIKE_IN_HOME="${RAW_HOME:-$SANDBOX/home}" /usr/bin/perl "$RUNNER" "$@"
}

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
check "worktree add rejects a bad name" /bin/bash -c '. "$1"; ! spike_worktree_add "$2" "../evil"' _ "$COMMON" "$REPO"

spike_cleanup "$RUN"
check "cleanup removed the run dir" test ! -e "$RUN"
check "cleanup left no worktree dir" test ! -e "$REPO-wt"

# --- odd TMPDIR values -----------------------------------------------------------------------------------------------
PHYS_TMP="$(cd /tmp && pwd -P)"
eq "empty TMPDIR falls back to /tmp" "$PHYS_TMP/harness-spike" "$(TMPDIR='' spike_root)"
eq "unset TMPDIR falls back to /tmp" "$PHYS_TMP/harness-spike" "$(unset TMPDIR; spike_root)"

sbx_mkdir "$SANDBOX/with space"
(
  export TMPDIR="$SANDBOX/with space"
  R="$(spike_scratch_repo)" || exit 1
  W="$(spike_worktree_add "$R" beta)" || exit 1
  [ "$(git -C "$W" rev-parse --abbrev-ref HEAD)" = "spike/beta" ] || exit 1
  spike_cleanup "$(dirname "$R")" || exit 1
  [ ! -e "$(dirname "$R")" ] || exit 1
)
eq "TMPDIR with spaces: repo, worktree and cleanup work" "0" "$?"

sbx_mkdir "$SANDBOX/real-tmp"
sbx_ln "$SANDBOX/real-tmp" "$SANDBOX/link-tmp"
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
sbx_mkdir "$OUTSIDE/keep"
printf 'x\n' | sbx_put "$OUTSIDE/keep/file"
spike_cleanup "$OUTSIDE" 2>/dev/null
eq "cleanup refuses a path outside the spike root (rc)" "2" "$?"
check "outside path is untouched" test -f "$OUTSIDE/keep/file"
spike_cleanup "$ROOT" 2>/dev/null
eq "cleanup refuses the spike root itself (rc)" "2" "$?"
spike_cleanup "" 2>/dev/null
eq "cleanup refuses an empty path (rc)" "2" "$?"
# The destructive negatives run with rm shadowed by a recorder, so even a defect could not remove / or the real home.
RMLOG="$SANDBOX/rm-called"
(
  rm() { printf '%s\n' "$*" >> "$RMLOG"; }
  spike_cleanup "/" 2>/dev/null
  rc1=$?
  spike_cleanup "$HOME" 2>/dev/null
  rc2=$?
  [ "$rc1" = 2 ] && [ "$rc2" = 2 ]
)
eq "cleanup refuses / and the real \$HOME (rc 2 each, rm shadowed)" "0" "$?"
check "cleanup of / and \$HOME called rm zero times" test ! -e "$RMLOG"
# Decoy variants: the same refusals against directories whose real path is inside the sandbox.
DECOY="$SANDBOX/decoy-home"
sbx_mkdir "$DECOY/keep"
printf 'x\n' | sbx_put "$DECOY/keep/file"
(HOME="$DECOY"; spike_cleanup "$HOME" 2>/dev/null)
eq "cleanup refuses a decoy home (rc)" "2" "$?"
check "the decoy home is untouched" test -f "$DECOY/keep/file"
sbx_mkdir "$ROOT/run-x"
spike_cleanup "$ROOT/run-x/../../outside" 2>/dev/null
eq "cleanup refuses .. traversal (rc)" "2" "$?"
check "traversal target is untouched" test -f "$OUTSIDE/keep/file"
sbx_ln "$OUTSIDE" "$ROOT/run-link"
spike_cleanup "$ROOT/run-link" 2>/dev/null
eq "cleanup refuses a symlink under the root (rc)" "2" "$?"
check "symlink target is untouched" test -f "$OUTSIDE/keep/file"
rm -f "$ROOT/run-link"
# Round 7, finding 3: a trailing newline must not make the cleanup act on a different path than it checked.
sbx_mkdir "$ROOT/run-nl"
printf 'x\n' | sbx_put "$ROOT/run-nl/file"
spike_cleanup "$ROOT/run-nl"$'\n' 2>/dev/null
eq "cleanup refuses a path with a trailing newline (rc)" "2" "$?"
check "the directory named without the newline is untouched" test -f "$ROOT/run-nl/file"
spike_cleanup "$ROOT/run-nl"
check "cleanup removes a plain run dir under the root" test ! -e "$ROOT/run-nl"
spike_cleanup "$ROOT/run-x"
check "cleanup removes another plain run dir under the root" test ! -e "$ROOT/run-x"

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
sbx_mkdir "$FAKE"
for n in claude codex; do
  printf '#!/bin/sh\ntouch "%s/ran-$$"\nexit 0\n' "$FAKE" | sbx_put "$FAKE/$n"
  chmod +x "$FAKE/$n"
done
sbx_put "$FAKE/claude.exe" <<EOF
#!/bin/sh
touch "$FAKE/ran-exe-\$\$"
EOF
chmod +x "$FAKE/claude.exe"
# count_glob <glob...>: how many of the given paths exist (a glob that matched nothing counts 0).
count_glob() { local n=0 f; for f in "$@"; do if [ -e "$f" ] || [ -L "$f" ]; then n=$((n + 1)); fi; done; echo "$n"; }
ran() { count_glob "$FAKE"/ran-*; }
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
# An UNVERIFIED claude/codex is refused by spike_run_timeout even for its status shapes. Only spike_run_status runs those,
# and only for a private copy that registration produced (see the status tests below).
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/claude" --version' _ "$COMMON" "$FAKE" 2>/dev/null
eq "run_timeout refuses an unverified claude --version without SPIKE_LIVE (rc)" "3" "$?"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/claude" auth status' _ "$COMMON" "$FAKE" 2>/dev/null
eq "run_timeout refuses an unverified claude auth status without SPIKE_LIVE (rc)" "3" "$?"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/codex" login status' _ "$COMMON" "$FAKE" 2>/dev/null
eq "run_timeout refuses an unverified codex login status without SPIKE_LIVE (rc)" "3" "$?"
eq "refused unverified status calls did not start the CLIs" "0" "$(ran)"
# The registered copies are Mach-O-headed fixtures whose signer passes the fake pinned check. Registration COPIES the source
# into the private verify directory; spike_run_status takes the copy (SPIKE_VERIFIED_COPY), never the source.
REG="$FAKE/reg"
sbx_mkdir "$REG"
mkmacho "$REG/claude" <<EOF
touch "$FAKE/ran-\$\$"
exit 0
EOF
mkmacho "$REG/codex" <<EOF
# signer: codex
touch "$FAKE/ran-\$\$"
exit 0
EOF
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2/claude" claude && c1="$SPIKE_VERIFIED_COPY" && spike_mark_verified "$2/codex" codex && c2="$SPIKE_VERIFIED_COPY" && spike_run_status 5 /dev/null "$c1" --version && spike_run_status 5 /dev/null "$c1" auth status && spike_run_status 5 /dev/null "$c2" login status' _ "$COMMON" "$REG" 2>/dev/null
eq "status runner runs registered verified copies (claude --version, claude auth status, codex login status) without SPIKE_LIVE (rc)" "0" "$?"
eq "allowed status calls did start the verified copies" "3" "$(ran)"
# Round 8, item 9: the REGISTERED copy is what spike_run_live runs for a pinned name (SPIKE_LIVE=1 still required).
rm -f "$FAKE"/ran-*
SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_mark_verified "$2/claude" claude && spike_run_live 5 /dev/null "$SPIKE_VERIFIED_COPY" -p hi' _ "$COMMON" "$REG" 2>/dev/null
eq "spike_run_live runs the registered, hash-verified copy of claude with SPIKE_LIVE=1 (rc 0)" "0" "$?"
eq "the registered copy was started by spike_run_live" "1" "$(ran)"
rm -f "$FAKE"/ran-*
o="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2/claude" claude && spike_run_live 5 /dev/null "$SPIKE_VERIFIED_COPY" -p hi; echo CONTINUED' _ "$COMMON" "$REG" 2>/dev/null)"
eq "spike_run_live of the registered copy still needs SPIKE_LIVE=1 (rc 3)" "3" "$?"
eq "the registered copy was not started without SPIKE_LIVE=1" "0" "$(ran)"
o="$(SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_mark_verified "$2/claude" claude || exit 9; printf "%s\n" "#!/bin/sh" "touch \"$3/ran-swapped\"" >| "$SPIKE_VERIFIED_COPY"; spike_run_live 5 /dev/null "$SPIKE_VERIFIED_COPY" -p hi; echo CONTINUED' _ "$COMMON" "$REG" "$FAKE" 2>/dev/null)"
eq "spike_run_live refuses a registered copy whose content changed after registration (rc 3)" "3" "$?"
check_absent() { if [ ! -e "$2" ]; then ok "$1"; else bad "$1"; fi; }
check_absent "the changed registered copy never ran under spike_run_live" "$FAKE/ran-swapped"
eq "spike_run_live of a registered copy of codex under the codex name (rc 0)" "0" "$(SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_mark_verified "$2/codex" codex && spike_run_live 5 /dev/null "$SPIKE_VERIFIED_COPY" exec hi' _ "$COMMON" "$REG" >/dev/null 2>&1; echo $?)"
rm -f "$FAKE"/ran-*
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/claude" --version extra' _ "$COMMON" "$FAKE" 2>/dev/null
eq "run_timeout refuses --version with extra args (rc)" "3" "$?"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/claude" auth login' _ "$COMMON" "$FAKE" 2>/dev/null
eq "run_timeout refuses auth login (rc)" "3" "$?"
rm -f "$FAKE"/ran-*
# CHANGED in round 8 (item 9): an UNVERIFIED claude/codex is no longer started even with SPIKE_LIVE=1; only the current
# registered, hash-verified copy runs (it was "run_timeout runs a provider CLI prompt with SPIKE_LIVE=1", rc 0, started 1).
o="$(SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2/claude" -p hi; echo CONTINUED' _ "$COMMON" "$FAKE" 2>/dev/null)"
eq "run_timeout refuses an UNVERIFIED claude prompt even with SPIKE_LIVE=1 (rc 3)" "3" "$?"
lacks "run_timeout's refusal of an unverified claude with SPIKE_LIVE=1 stops the caller" "$o" "CONTINUED"
eq "the unverified claude was not started with SPIKE_LIVE=1 (run_timeout)" "0" "$(ran)"
SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 5 /dev/null "$2/codex" exec hi' _ "$COMMON" "$FAKE" 2>/dev/null
eq "spike_run_live refuses an UNVERIFIED codex with SPIKE_LIVE=1 (rc 3)" "3" "$?"
eq "the unverified codex was not started with SPIKE_LIVE=1" "0" "$(ran)"
SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 5 /dev/null "$2/claude.exe" -p hi' _ "$COMMON" "$FAKE" 2>/dev/null
eq "spike_run_live refuses an UNVERIFIED claude.exe with SPIKE_LIVE=1 (rc 3)" "3" "$?"
sbx_ln "$FAKE/claude" "$FAKE/alias-to-claude"
SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 5 /dev/null "$2/alias-to-claude" -p hi' _ "$COMMON" "$FAKE" 2>/dev/null
eq "spike_run_live refuses a symlink whose RESOLVED basename is claude (rc 3)" "3" "$?"
eq "none of the unverified pinned-name fixtures was started" "0" "$(ran)"

# --- the gate is default-deny: indirect launches of a provider CLI are refused (rule 1) ------------------------------
sbx_cp "$FAKE/claude" "$FAKE/renamed"
sbx_cp "$FAKE/claude" "$FAKE/mytool"
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
# CHANGED in round 8 (item 4): "provider name in the args of an allowed tool (echo)" is no longer denied; see okrun below.
denied "cat is not on the ungated list (it was: provider name as a path component in cat)" "spike_run_timeout 5 /dev/null cat /x/codex/y"
denied "git with an alias that runs claude" "spike_run_timeout 5 /dev/null git -c 'alias.x=!claude -p hi' x"
denied "git with anything but --version" "spike_run_timeout 5 /dev/null git status"
for w in zsh dash ksh xargs nohup command exec time nice perl python python3 node ruby script expect osascript open; do
  denied "launcher '$w'" "spike_run_timeout 5 /dev/null $w claude -p hi"
done
denied "spike_run_live without SPIKE_LIVE" "spike_run_live 5 /dev/null '$FAKE/claude' -p hi"
denied "spike_run_status with a prompt (unregistered path)" "spike_run_status 5 /dev/null '$REG/claude' -p hi"
denied "spike_run_status with --version and extra args (unregistered path)" "spike_run_status 5 /dev/null '$REG/claude' --version -p"
denied "spike_run_status with a prompt on a REGISTERED copy" "spike_mark_verified '$REG/claude' claude; spike_run_status 5 /dev/null \"\$SPIKE_VERIFIED_COPY\" -p hi"
denied "spike_run_status with --version and extra args on a REGISTERED copy" "spike_mark_verified '$REG/claude' claude; spike_run_status 5 /dev/null \"\$SPIKE_VERIFIED_COPY\" --version -p"

# ...while the harmless shapes still work without SPIKE_LIVE.
okrun() { # okrun <name> <code>: must not be stopped by the gate
  local name="$1" code="$2" o
  o="$(env -u SPIKE_LIVE PATH="$FAKE:$PATH" /bin/bash -c '. "$1"; eval "$2"; echo CONTINUED' _ "$COMMON" "$code" 2>/dev/null)"
  has "gate allows: $name" "$o" "CONTINUED"
}
okrun "true" 'spike_run_timeout 5 /dev/null true'
okrun "echo hello" 'spike_run_timeout 5 /dev/null echo hello'
okrun "sleep" 'spike_run_timeout 5 /dev/null sleep 0'
# Round 8, item 4: provider words are judged on the program name only. The arguments of an ungated system command can name a
# provider (echo/printf text, a path under a directory called claude) because identity is enforced and nothing is launched.
okrun "echo with a provider name in the arguments (was denied in round 7)" 'spike_run_timeout 5 /dev/null echo CLAUDE'
okrun "echo claude -p hi (text only; was denied in round 7)" 'spike_run_timeout 5 /dev/null echo claude -p hi'
okrun "printf with a path argument that has a provider directory in it" 'spike_run_timeout 5 /dev/null printf %s /x/claude/y/codex/z'
sbx_cp /usr/bin/true "$FAKE/claude-true"
denied "a program NAMED like a provider is never ungated (copy of true called claude-true)" "spike_run_timeout 5 /dev/null '$FAKE/claude-true'"
# jq is not a harmless identity; it is probed through spike_run_timed, never through the runner.
denied "jq --version needs the gate (jq is not on the ungated list, rule 1)" "spike_run_timeout 5 /dev/null jq --version"
okrun "git --version" 'spike_run_timeout 5 /dev/null git --version'
# codesign is ungated only for the read-only shapes, from a system directory, and only on a path that resolves inside the
# private verify directory the helper made. Without a system codesign (Linux) the identity check fails, so the shapes need
# the gate there.
if [ -x /usr/bin/codesign ]; then
  okrun "codesign --verify --strict <path inside the verify dir> (system codesign)" 'spike_verify_init; : > "$(spike_verify_dir)/claude"; spike_run_timeout 5 /dev/null codesign --verify --strict "$(spike_verify_dir)/claude"'
  okrun "codesign -dv --verbose=2 <path inside the verify dir> (system codesign)" 'spike_verify_init; : > "$(spike_verify_dir)/claude"; spike_run_timeout 5 /dev/null codesign -dv --verbose=2 "$(spike_verify_dir)/claude"'
else
  denied "codesign verify needs the gate when there is no system codesign (identity, rule 6)" 'spike_verify_init; spike_run_timeout 5 /dev/null codesign --verify --strict "$(spike_verify_dir)/claude"'
fi
mkmacho "$REG/renamed" <<EOF
exit 0
EOF
okrun "spike_run_status of a renamed binary with --version (registered as a verified copy first)" "spike_mark_verified '$REG/renamed' claude; spike_run_status 5 /dev/null \"\$SPIKE_VERIFIED_COPY\" --version"
okrun "spike_run_status of a renamed binary with login status (registered as a verified copy first)" "spike_mark_verified '$REG/renamed' claude; spike_run_status 5 /dev/null \"\$SPIKE_VERIFIED_COPY\" login status"
rm -f "$FAKE"/ran-*
denied "upper-case CLAUDE --version through spike_run_timeout (unverified provider CLI, rule 6)" "spike_run_timeout 5 /dev/null '$FAKE/CLAUDE' --version"
rm -f "$FAKE"/ran-*
SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 5 /dev/null "$2/renamed" -p hi' _ "$COMMON" "$FAKE" 2>/dev/null
eq "spike_run_live runs when SPIKE_LIVE=1 (rc)" "0" "$?"
eq "spike_run_live started the command" "1" "$(ran)"
rm -f "$FAKE"/ran-*

# --- identity, not name (rule 1): copies of harmless programs are refused outside a system directory ---
SHADOW="$SANDBOX/shadow"
sbx_mkdir "$SHADOW/marks"
for n in cat printf echo true codesign jq; do
  printf '#!/bin/sh\ntouch "%s/marks/%s-$$"\nexit 0\n' "$SHADOW" "$n" | sbx_put "$SHADOW/$n"
  chmod +x "$SHADOW/$n"
done
marks() { count_glob "$SHADOW/marks"/*; }
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
  local name="$1" want="$2" got
  shift 2
  if libt 'codesign_shape(@ARGV)' "$@" >/dev/null 2>&1; then got=1; else got=0; fi
  eq "codesign shape: $name" "$want" "$got"
}
cs_shape "--verify --strict <path> is a read-only shape" 1 --verify --strict /x/claude
cs_shape "-dv --verbose=2 <path> is a read-only shape" 1 -dv --verbose=2 /x/claude
cs_shape "--verify --strict with the pinned -R requirement (incl. the Developer ID leaf OID) is a read-only shape" 1 --verify --strict '-R=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "Q6L2SF6YDW"' /x/claude
cs_shape "the old -R requirement without the leaf OID is no longer a shape (changed in round 8)" 0 --verify --strict '-R=anchor apple generic and certificate leaf[subject.OU] = "Q6L2SF6YDW"' /x/claude
cs_shape "a -R requirement with another clause appended is refused" 0 --verify --strict '-R=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "Q6L2SF6YDW" or anchor apple' /x/claude
cs_shape "--sign - is refused" 0 --sign - x
cs_shape "--remove-signature is refused" 0 --remove-signature x
cs_shape "--verify --strict --remove-signature is refused" 0 --verify --strict --remove-signature
cs_shape "--verify --strict <path> --remove-signature is refused" 0 --verify --strict /x --remove-signature
cs_shape "-dv --verbose=2 with an option where the path goes is refused" 0 -dv --verbose=2 --remove-signature

# --- rule 4: the codesign path must resolve inside the private verify directory the HELPER made -----------------------
# A canary stands in for a credential file under a fake home. Its text must never be read by the codesign checks.
VD="$(rawhelper vdir-create $$)"
check "the helper made a verify directory inside the sandbox" test -d "$VD"
case "$VD" in "$SANDBOX"/spike-verify.*) ok "the verify directory is named spike-verify.<id> under TMPDIR" ;; *) bad "the verify directory is named spike-verify.<id> under TMPDIR ($VD)" ;; esac
eq "the verify directory is mode 700" "drwx------" "$(ls -ld "$VD" | cut -c1-10)"
sbx_mkdir "$FH/.claude"
printf 'CANARY-ROOT-9d1e\n' | sbx_put "$FH/.claude/canary"
sbx_ln "$FH/.claude/canary" "$VD/link-to-canary"
rooted() { # rooted <label> <1|0> <verify-dir or -> <path>: codesign_rooted on its own
  local label="$1" want="$2" vd="$3" p="$4" got
  if libt 'codesign_rooted($ARGV[0], $ARGV[1])' "$p" "$vd" >/dev/null 2>&1; then got=1; else got=0; fi
  eq "codesign rooted: $label" "$want" "$got"
}
rooted "a path inside the verify directory" 1 "$VD" "$VD/inside"
rooted "the verify directory itself is not a file inside it" 0 "$VD" "$VD"
rooted "a canary path under a fake home" 0 "$VD" "$FH/.claude/canary"
rooted "a symlink in the verify directory that leads to the canary" 0 "$VD" "$VD/link-to-canary"
rooted "a .. escape out of the verify directory" 0 "$VD" "$VD/../fakehome/.claude/canary"
rooted "no verify directory set: nothing is rooted" 0 - "$VD/inside"
rooted "a directory that merely looks like a verify directory is not one" 0 "$FH/.claude" "$FH/.claude/canary"
denied "codesign --verify on a canary under a fake home is not ungated (rc 3)" "_SPIKE_VERIFY_DIR='$VD'; spike_run_timeout 5 /dev/null codesign --verify --strict '$FH/.claude/canary'"
denied "codesign --verify through a symlink into the fake home is not ungated (rc 3)" "_SPIKE_VERIFY_DIR='$VD'; spike_run_timeout 5 /dev/null codesign --verify --strict '$VD/link-to-canary'"
check "the canary was never copied or read into a verify output" /bin/bash -c '! grep -rq CANARY-ROOT "$1"' _ "$VD"
check "spike_set_verify_dir no longer exists (the caller cannot choose the verify directory)" /bin/bash -c '. "$1"; ! declare -F spike_set_verify_dir >/dev/null' _ "$COMMON"

# --- spike_run_status: only a registered, unchanged verified copy, and only the three status shapes -----------------
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
sbx_mkdir "$SANDBOX/launch"
mkmacho "$SANDBOX/launch/sh" <<EOF
touch "$FAKE/ran-\$\$"
exit 0
EOF
sbx_ln "$FAKE/claude" "$SANDBOX/launch/linked"
rm -f "$FAKE"/ran-*
# A source NAMED like a launcher registers as a copy named after the CLI; the original path itself is never accepted.
o="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2/sh" claude && spike_run_status 5 /dev/null "$2/sh" --version; echo CONTINUED' _ "$COMMON" "$SANDBOX/launch" 2>/dev/null)"
eq "spike_run_status refuses the launcher-named ORIGINAL even after it was registered (rc 3)" "3" "$?"
lacks "spike_run_status refuses the launcher-named original: caller stopped" "$o" "CONTINUED"
eq "spike_run_status refused the launcher-named original: nothing started" "0" "$(ran)"
rm -f "$FAKE"/ran-*
o="$(SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_mark_verified "$2/claude" claude && spike_run_status 5 /dev/null "$SPIKE_VERIFIED_COPY" -p hi; echo CONTINUED' _ "$COMMON" "$REG" 2>/dev/null)"
eq "spike_run_status with a prompt is refused even for a registered copy and SPIKE_LIVE=1 (rc 3)" "3" "$?"
lacks "spike_run_status with a prompt stops the caller" "$o" "CONTINUED"
eq "spike_run_status with a prompt started nothing" "0" "$(ran)"
/bin/bash -c '. "$1"; spike_mark_verified relative/claude claude' _ "$COMMON" >/dev/null 2>&1
eq "spike_mark_verified refuses a relative path (rc 2)" "2" "$?"
/bin/bash -c '. "$1"; spike_mark_verified "$2/linked" claude' _ "$COMMON" "$SANDBOX/launch" >/dev/null 2>&1
eq "spike_mark_verified refuses a symlink (rc 2)" "2" "$?"
/bin/bash -c '. "$1"; spike_mark_verified "$2" claude' _ "$COMMON" "$SANDBOX/launch" >/dev/null 2>&1
eq "spike_mark_verified refuses a directory (rc 2)" "2" "$?"

# --- registration (rule 6): the helper checks the magic and the pinned signer on the COPY ----------------------------
RG="$SANDBOX/regtest"
sbx_mkdir "$RG"
mkmacho "$RG/claude" <<EOF
# signer: claude
touch "$FAKE/ran-\$\$"
exit 0
EOF
# regcase <label> <fake codesign mode> <cli> <path>: registration must refuse (rc 2), and the status runner must then refuse
# the same path (rc 3) without running it.
regcase() {
  local label="$1" mode="$2" name="$3" p="$4" rc
  fsmode "$mode"
  env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" "$3"' _ "$COMMON" "$p" "$name" >/dev/null 2>&1
  rc=$?
  eq "registration refused: $label (rc 2)" "2" "$rc"
  rm -f "$FAKE"/ran-*
  env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_status 5 /dev/null "$2" --version' _ "$COMMON" "$p" >/dev/null 2>&1
  eq "registration refused: $label, so spike_run_status refuses it (rc 3)" "3" "$?"
  eq "registration refused: $label, and nothing ran" "0" "$(ran)"
}
for n in unsigned wrong-claude adhoc-claude forged-claude notdev-claude weird-claude; do
  mkmacho "$RG/$n" <<EOF
touch "$FAKE/ran-\$\$"
EOF
done
regcase "unsigned Mach-O (not signed at all)" unsigned claude "$RG/unsigned"
regcase "wrong team (Developer ID, other team)" wrongteam claude "$RG/wrong-claude"
regcase "ad-hoc signature" adhoc claude "$RG/adhoc-claude"
regcase "forged text, chain requirement fails" forged claude "$RG/forged-claude"
regcase "Apple Development authority, not Developer ID" notdev claude "$RG/notdev-claude"
regcase "codesign fails with rc 3" weird claude "$RG/weird-claude"
fsmode good
# A Claude-team copy registered under the codex name is refused by the pinned team of that name.
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" codex' _ "$COMMON" "$RG/claude" >/dev/null 2>&1
eq "registration refused: a copy signed by the Anthropic team registered as codex (rc 2)" "2" "$?"
# Magic: an ELF header and a script with a Mach-O name are refused before any signer runs.
printf '\177ELF\002\001\001\000 not a mach-o\n' | sbx_put "$RG/elf-claude"
chmod +x "$RG/elf-claude"
printf '#!/bin/sh\necho "%s"\n' "script with a Mach-O name" | sbx_put "$RG/script-claude"
chmod +x "$RG/script-claude"
: >| "$FSDIR/log"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" claude' _ "$COMMON" "$RG/elf-claude" >/dev/null 2>&1
eq "registration refused: an ELF header named claude (rc 2)" "2" "$?"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" claude' _ "$COMMON" "$RG/script-claude" >/dev/null 2>&1
eq "registration refused: a shell script with a Mach-O name (rc 2)" "2" "$?"
eq "no signer was consulted for the non-Mach-O files" "" "$(cat "$FSDIR/log")"
if [ "$(head -c 4 /bin/sh | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
  sbx_cp /bin/sh "$RG/dash-claude"
  env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" claude' _ "$COMMON" "$RG/dash-claude" >/dev/null 2>&1
  eq "registration refused: a copy of dash named claude (ELF on Linux, rc 2)" "2" "$?"
  rm -f "$FAKE"/ran-*
  env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_status 5 /dev/null "$2" --version' _ "$COMMON" "$RG/dash-claude" >/dev/null 2>&1
  eq "a dash copy named claude is never run through spike_run_status (rc 3)" "3" "$?"
fi
# Positive: a Mach-O-headed copy that passes the fake pinned signer for claude registers (rc 0). The fake codesign was asked
# about the COPY (inside the private verify directory) with the chain requirement. The status run reaches exec.
fsmode good
: >| "$FSDIR/log"
COPY="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" claude && printf "%s" "$SPIKE_VERIFIED_COPY"' _ "$COMMON" "$RG/claude" 2>/dev/null)"
eq "registration accepts a Mach-O copy that passes the pinned signer (rc 0)" "0" "$?"
case "$COPY" in "$SANDBOX"/spike-verify.*/claude) ok "the registered copy lives in the private verify directory" ;; *) bad "the registered copy lives in the private verify directory ($COPY)" ;; esac
has "registration asked codesign about the COPY path (verify)" "$(cat "$FSDIR/log")" "--verify --strict $COPY"
lacks "registration never asked codesign about the original path" "$(cat "$FSDIR/log")" "$RG/claude"
has "registration checked the chain-to-Apple requirement for the pinned team (round 8: with the Developer ID leaf OID)" "$(cat "$FSDIR/log")" 'anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "Q6L2SF6YDW"'
rm -f "$FAKE"/ran-*
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" claude && spike_run_status 5 /dev/null "$SPIKE_VERIFIED_COPY" --version' _ "$COMMON" "$RG/claude" >/dev/null 2>&1
eq "registered binary passes the identity check and runs through spike_run_status (rc 0)" "0" "$?"
eq "registered binary ran once" "1" "$(ran)"

# Sonnet audit: the registry binds CONTENT, not only a path. A copy changed after registration is refused before exec.
rm -f "$FAKE"/ran-*
o="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" claude || exit 9; printf "%s\n" "#!/bin/sh" "touch \"$3/ran-swapped\"" >| "$SPIKE_VERIFIED_COPY"; spike_run_status 5 /dev/null "$SPIKE_VERIFIED_COPY" --version; echo CONTINUED' _ "$COMMON" "$RG/claude" "$FAKE" 2>/dev/null)"
eq "a registered copy swapped after registration is refused (rc 3)" "3" "$?"
lacks "a swapped copy stops the caller" "$o" "CONTINUED"
check "the swapped copy never ran" test ! -e "$FAKE/ran-swapped"
eq "no registered fixture ran either" "0" "$(ran)"
o="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" claude || exit 9; rm -f "$SPIKE_VERIFIED_COPY"; ln -s "$2" "$SPIKE_VERIFIED_COPY"; spike_run_status 5 /dev/null "$SPIKE_VERIFIED_COPY" --version; echo CONTINUED' _ "$COMMON" "$RG/claude" 2>/dev/null)"
eq "a registered copy replaced by a symlink to the (once verified) original is refused (rc 3)" "3" "$?"
eq "the symlinked original never ran" "0" "$(ran)"

# --- Opus finding 1: a fake perl first on PATH has no effect ---------------------------------------------------------------
FP="$SANDBOX/fakeperl"
sbx_mkdir "$FP"
for t in perl env bash codesign; do
  sbx_put "$FP/$t" <<EOF
#!/bin/sh
touch "$FP/fake-$t-ran"
exit 0
EOF
  chmod +x "$FP/$t"
done
fsmode unsigned
: >| "$FSDIR/log"
o="$(env -u SPIKE_LIVE PATH="$FP:$PATH" /bin/bash -c '. "$1"; spike_mark_verified "$2" claude; rc=$?; echo "RC=$rc TEXT=$SPIKE_SIG_TEXT"' _ "$COMMON" "$RG/unsigned" 2>/dev/null)"
has "fake perl on PATH: an unsigned Mach-O is still refused (rc 2)" "$o" "RC=2"
has "fake perl on PATH: the signature text is the real verdict (NOT SIGNED), not a forged valid team" "$o" "TEXT=NOT SIGNED"
lacks "fake perl on PATH: never reports a valid team" "$o" "valid"
o="$(env -u SPIKE_LIVE PATH="$FP:$PATH" /bin/bash -c '. "$1"; spike_mark_verified "$2" claude; echo "RC=$?"' _ "$COMMON" "$RG/script-claude" 2>/dev/null)"
has "fake perl on PATH: an unsigned non-Mach-O is refused (rc 2)" "$o" "RC=2"
fsmode good
o="$(env -u SPIKE_LIVE PATH="$FP:$PATH" /bin/bash -c '. "$1"; spike_mark_verified "$2" claude && spike_run_status 5 /dev/null "$SPIKE_VERIFIED_COPY" --version; echo "RC=$?"' _ "$COMMON" "$RG/claude" 2>/dev/null)"
has "fake perl on PATH: a good registration and status run still work (rc 0)" "$o" "RC=0"
rm -f "$FAKE"/ran-*
SPIKE_LIVE=1 PATH="$FP:$PATH" /bin/bash -c '. "$1"; spike_run_live 5 /dev/null "$2/renamed" -p hi; spike_run_timed 5 /dev/null jq --version' _ "$COMMON" "$FAKE" >/dev/null 2>&1
eq "fake perl on PATH: a live run starts the command" "1" "$(ran)"
check "fake perl on PATH: neither the fake perl, env, bash nor codesign was ever started" /bin/bash -c 'test ! -e "$1/fake-perl-ran" -a ! -e "$1/fake-env-ran" -a ! -e "$1/fake-bash-ran" -a ! -e "$1/fake-codesign-ran"' _ "$FP"

# --- Opus finding 2: SIGKILL to the caller's whole process group must not orphan the command -------------------------------
sbx_put "$SANDBOX/pglauncher.sh" <<EOF
#!/bin/sh
sleep 33 &
echo "\$\$ \$!" > "$SANDBOX/pg.pids.tmp"
mv "$SANDBOX/pg.pids.tmp" "$SANDBOX/pg.pids"
wait
EOF
chmod +x "$SANDBOX/pglauncher.sh"
rm -f "$SANDBOX/pg.pids"
# The caller leads its own session and group (setsid), as a terminal job would.
SPIKE_LIVE=1 /usr/bin/perl -e 'use POSIX; POSIX::setsid(); exec @ARGV' /bin/bash -c '. "$1"; spike_run_live 60 /dev/null "$2"; echo AFTER' _ "$COMMON" "$SANDBOX/pglauncher.sh" > "$SANDBOX/pg.out" 2>/dev/null &
PGCALLER=$!
n=0
while [ ! -s "$SANDBOX/pg.pids" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
PLPID=""
PGPID=""
read -r PLPID PGPID < "$SANDBOX/pg.pids" 2>/dev/null
CALLER_PGID="$(ps -o pgid= -p "$PGCALLER" 2>/dev/null | tr -d ' ')"
CMD_PGID="$(ps -o pgid= -p "$PLPID" 2>/dev/null | tr -d ' ')"
if [ -n "$PLPID" ] && [ -n "$PGPID" ] && alive "$PLPID" && alive "$PGPID"; then ok "process group: the launcher and its grandchild run before the group is killed"; else bad "process group: the launcher and its grandchild run before the group is killed"; fi
if [ -n "$CALLER_PGID" ] && [ -n "$CMD_PGID" ] && [ "$CALLER_PGID" != "$CMD_PGID" ]; then ok "process group: the command is NOT in the caller's group (the watchdog is not killed with the caller)"; else bad "process group: the command is NOT in the caller's group (caller $CALLER_PGID, command $CMD_PGID)"; fi
MYPGID="$(ps -o pgid= -p $$ | tr -d ' ')"
if [ -n "$CALLER_PGID" ] && [ "$CALLER_PGID" != "$MYPGID" ] && [ "$CALLER_PGID" != "1" ] && [ "$CALLER_PGID" = "$PGCALLER" ]; then
  kill -9 -- "-$CALLER_PGID" 2>/dev/null
else
  bad "process group: the caller leads its own group (refusing to signal group [$CALLER_PGID], mine is [$MYPGID])"
  kill -9 "$PGCALLER" 2>/dev/null
fi
if gone_within 30 "$PLPID"; then ok "process group: SIGKILL to the caller's whole group, the launcher is gone within 3 s"; else bad "process group: SIGKILL to the caller's whole group, the launcher is gone within 3 s"; kill -9 "$PLPID" 2>/dev/null; fi
if gone_within 30 "$PGPID"; then ok "process group: SIGKILL to the caller's whole group, the grandchild is gone within 3 s"; else bad "process group: SIGKILL to the caller's whole group, the grandchild is gone within 3 s"; kill -9 "$PGPID" 2>/dev/null; fi
{ wait "$PGCALLER"; } 2>/dev/null
lacks "process group: the killed caller ran no further statement" "$(cat "$SANDBOX/pg.out")" "AFTER"

# ...and a SIGKILL to the HELPER's group (which holds the helper, the command and its grandchild) kills the command too.
rm -f "$SANDBOX/pg.pids"
SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 60 /dev/null "$2"; echo "AFTER rc=$?"' _ "$COMMON" "$SANDBOX/pglauncher.sh" > "$SANDBOX/pg2.out" 2>/dev/null &
PGCALLER2=$!
n=0
while [ ! -s "$SANDBOX/pg.pids" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
read -r PLPID PGPID < "$SANDBOX/pg.pids" 2>/dev/null
HGRP="$(ps -o pgid= -p "$PLPID" 2>/dev/null | tr -d ' ')"
if [ -n "$HGRP" ] && [ "$HGRP" != "$MYPGID" ] && [ "$HGRP" != "$PGCALLER2" ] && [ "$HGRP" != "1" ]; then
  kill -9 -- "-$HGRP" 2>/dev/null
else
  bad "process group: the helper leads its own group (refusing to signal group [$HGRP])"
  kill -9 "$PLPID" 2>/dev/null
fi
if gone_within 30 "$PLPID"; then ok "process group: SIGKILL to the helper's group kills the launcher"; else bad "process group: SIGKILL to the helper's group kills the launcher"; kill -9 "$PLPID" 2>/dev/null; fi
if gone_within 30 "$PGPID"; then ok "process group: SIGKILL to the helper's group kills the grandchild"; else bad "process group: SIGKILL to the helper's group kills the grandchild"; kill -9 "$PGPID" 2>/dev/null; fi
{ wait "$PGCALLER2"; } 2>/dev/null
has "process group: the caller of a killed helper sees a signal status and survives" "$(cat "$SANDBOX/pg2.out")" "AFTER rc=137"

# --- resolve once, physically, and execute the resolved path --------------------------------------------------------------
# Reviewer's repro: S is a symlink to an 11-level directory, and the command is S + 14 x "/.." + "/usr/bin/printf". The
# kernel applies each '..' to the real directory, so the command is a file under the physical target. A fake printf sits
# there. A lexical resolver sees /usr/bin/printf; the helper must see the physical file and refuse.
RR="$SANDBOX/rr"
RQ="$RR/q1/q2/q3"
RT="$RQ/c1/c2/c3/c4/c5/c6/c7/c8/c9/c10/c11"
sbx_mkdir "$RT" "$RR/usr/bin"
sbx_ln "$RT" "$RQ/S"
printf '#!/bin/sh\ntouch "%s/rr-marker"\necho FAKE-PRINTF\n' "$RR" | sbx_put "$RR/usr/bin/printf"
chmod +x "$RR/usr/bin/printf"
RUPS=""
i=0
while [ "$i" -lt 14 ]; do RUPS="$RUPS/.."; i=$((i + 1)); done
RCMD="$RQ/S$RUPS/usr/bin/printf"
eq "reviewer repro resolves to the physical target, not /usr/bin/printf" "$(CDPATH='' cd -P -- "$RR" && pwd -P)/usr/bin/printf" "$(spike_resolve_path "$RCMD")"
rm -f "$RR"/rr-marker
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2" hi' _ "$COMMON" "$RCMD" >/dev/null 2>&1
eq "reviewer repro with a prompt is refused (rc 3)" "3" "$?"
check "reviewer repro: the fake printf under the physical target never ran" test ! -e "$RR/rr-marker"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null "$2" hi' _ "$COMMON" "$RCMD" >/dev/null 2>&1
eq "reviewer repro without a prompt is refused too (rc 3)" "3" "$?"
check "reviewer repro (no prompt): the fake printf never ran" test ! -e "$RR/rr-marker"
# Double slashes are normalised, so //usr//bin/printf runs the REAL printf (no false refusal).
PFOUT="$SANDBOX/pf.out"
: >| "$PFOUT"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 "$2" //usr//bin/printf hello' _ "$COMMON" "$PFOUT" >/dev/null 2>&1
eq "//usr//bin/printf runs the real printf (rc 0)" "0" "$?"
has "//usr//bin/printf wrote its output" "$(cat "$PFOUT")" "hello"
eq "//usr//bin/printf resolves to /usr/bin/printf" "/usr/bin/printf" "$(spike_resolve_path //usr//bin/printf)"
# A symlink named like a harmless tool, pointing at a non-system file, is refused (the resolved target decides).
sbx_ln "$FAKE/claude" "$SANDBOX/alias-true"
rm -f "$FAKE"/ran-*
denied "a symlink named alias-true to a provider copy is not ungated (rc 3)" "spike_run_timeout 5 /dev/null '$SANDBOX/alias-true' --version"
# PATH TOCTOU: a directory first on PATH holds printf as a symlink to the real binary, and a fake regular file that the
# swapper puts in its place. Each run resolves printf once. The fake must never run; a run is either the real printf
# (rc 0) or a refusal (rc 3) when the fake was resolved.
TOC="$SANDBOX/toc"
sbx_mkdir "$TOC/first"
REALP="$(type -P printf)"
printf '#!/bin/sh\ntouch "%s/toc-marker-$$"\nexit 0\n' "$TOC" | sbx_put "$TOC/fake"
chmod +x "$TOC/fake"
sbx_ln "$REALP" "$TOC/first/printf"
(
  while :; do
    ln -sfn "$REALP" "$TOC/first/.p.tmp" && mv -f "$TOC/first/.p.tmp" "$TOC/first/printf"
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

# --- Opus finding 3: control characters (a trailing newline) are refused, not stripped ----------------------------------------
sbx_mkdir "$SANDBOX/nl"
sbx_put "$SANDBOX/nl/tool" <<EOF
#!/bin/sh
touch "$SANDBOX/nl/tool-ran"
exit 0
EOF
chmod +x "$SANDBOX/nl/tool"
spike_resolve_path "$SANDBOX/nl/tool"$'\n' >/dev/null 2>&1
check "a path with a trailing newline does not resolve (the resolver never returns a different path than it was given)" test "$?" -ne 0
spike_resolve_path "$SANDBOX/nl/to"$'\n'"ol" >/dev/null 2>&1
check "a path with an embedded newline does not resolve" test "$?" -ne 0
SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 5 /dev/null "$2"' _ "$COMMON" "$SANDBOX/nl/tool"$'\n' >/dev/null 2>&1
eq "spike_run_live refuses a command path with a trailing newline (rc 2)" "2" "$?"
check "the tool was not run through the newline path" test ! -e "$SANDBOX/nl/tool-ran"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" claude' _ "$COMMON" "$RG/claude"$'\n' >/dev/null 2>&1
eq "spike_mark_verified refuses a path with a trailing newline (rc 2)" "2" "$?"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" claude' _ "$COMMON" "$RG/claude"$'\nforged-line' >/dev/null 2>&1
eq "spike_mark_verified refuses a path that would inject a registry line (rc 2)" "2" "$?"
check "no registry in this sandbox contains an injected line" /bin/bash -c '! grep -rq forged-line "$1"/spike-verify.*/.registry' _ "$SANDBOX"

# --- Opus finding 4: a path containing '=' runs that file, never a PATH program ----------------------------------------------
sbx_mkdir "$SANDBOX/e=q" "$SANDBOX/pwbin"
sbx_put "$SANDBOX/e=q/tool" <<EOF
#!/bin/sh
touch "$SANDBOX/e=q/tool-ran"
exit 0
EOF
chmod +x "$SANDBOX/e=q/tool"
sbx_put "$SANDBOX/pwbin/pwn" <<EOF
#!/bin/sh
touch "$SANDBOX/pwbin/pwned"
exit 0
EOF
chmod +x "$SANDBOX/pwbin/pwn"
SPIKE_LIVE=1 PATH="$SANDBOX/pwbin:$PATH" /bin/bash -c '. "$1"; spike_run_live 5 /dev/null "$2" pwn' _ "$COMMON" "$SANDBOX/e=q/tool" >/dev/null 2>&1
eq "a command path containing = runs (rc 0)" "0" "$?"
check "a command path containing = ran that file" test -e "$SANDBOX/e=q/tool-ran"
check "a command path containing = never ran a PATH program named by its next argument" test ! -e "$SANDBOX/pwbin/pwned"
# The same for the helper's own arguments: a path with = in the interpreter-side positions cannot reach env's parser.
mkmacho "$SANDBOX/e=q/claude" <<EOF
exit 0
EOF
env -u SPIKE_LIVE PATH="$SANDBOX/pwbin:$PATH" /bin/bash -c '. "$1"; spike_mark_verified "$2" claude && spike_run_status 5 /dev/null "$SPIKE_VERIFIED_COPY" --version' _ "$COMMON" "$SANDBOX/e=q/claude" >/dev/null 2>&1
eq "registering and running a binary whose original path contains = works (rc 0)" "0" "$?"
check "no PATH program ran during that registration" test ! -e "$SANDBOX/pwbin/pwned"

# --- CLI homes by (device, inode) (rule 4) -------------------------------------------------------------------------------
# Round 8: the names are NOT written in this suite or in runner.pl. They are read here, at run time, from the lead-owned
# compliance/denylist.txt, the same file the helper reads: every entry must be refused, as a directory and as a single file.
UH="$SANDBOX/uhome"
UH3="$SANDBOX/uhome3"
NAMES="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$DENYLIST_REAL" | grep -v '^$')"
if [ -n "$NAMES" ]; then ok "the denylist file lists at least one CLI home entry"; else bad "the denylist file lists at least one CLI home entry"; fi
eq "every denylist entry has the shape ^\\.[A-Za-z0-9._-]+\$" "0" "$(printf '%s\n' "$NAMES" | grep -cv '^\.[A-Za-z0-9._-][A-Za-z0-9._-]*$')"
sbx_mkdir "$UH/plain/bin" "$UH/.hidden-tool" "$SANDBOX/outside-real" "$UH3"
for nm in $NAMES; do
  sbx_mkdir "$UH/$nm"
  printf 'x\n' | sbx_put "$UH/$nm/canary"
  printf 'x\n' | sbx_put "$UH3/$nm"
done
sbx_mkdir "$UH/.claude"
printf 'x\n' | sbx_put "$UH/.claude/canary"
chmod +x "$UH/.claude/canary"
sbx_ln "$SANDBOX/outside-real" "$UH/.linked"
uhome() { # uhome <path>: 0 if spike_under_cli_home refuses it, with HOME set to the fake home
  /bin/bash -c 'export HOME="$1"; . "$2"; spike_under_cli_home "$3"' _ "$UH" "$COMMON" "$1" >/dev/null 2>&1
}
uhome3() { # uhome3 <path>: the same with HOME = $UH3, where each denylist entry is a single FILE
  /bin/bash -c 'export HOME="$1"; . "$2"; spike_under_cli_home "$3"' _ "$UH3" "$COMMON" "$1" >/dev/null 2>&1
}
for nm in $NAMES; do
  if uhome "$UH/$nm/canary"; then ok "CLI home: a file under the denylist entry $nm in HOME is refused"; else bad "CLI home: a file under the denylist entry $nm in HOME is refused"; fi
  if uhome3 "$UH3/$nm"; then ok "CLI home: the single-file denylist entry $nm is refused"; else bad "CLI home: the single-file denylist entry $nm is refused"; fi
done
if uhome "$UH/plain/bin/claude"; then bad "CLI home: an ordinary path under HOME is not refused"; else ok "CLI home: an ordinary path under HOME is not refused"; fi
# CHANGED in round 7: the list is exact, so an unrelated dot-directory is no longer refused (it was a superset in round 6).
if uhome "$UH/.hidden-tool/x"; then bad "CLI home: an unrelated dot-directory of HOME is not refused (exact list, round 7)"; else ok "CLI home: an unrelated dot-directory of HOME is not refused (exact list, round 7)"; fi
if uhome "$UH/.linked/x"; then bad "CLI home: an unrelated dot-entry symlink is not refused"; else ok "CLI home: an unrelated dot-entry symlink is not refused"; fi
sbx_mkdir "$SANDBOX/other"
if uhome "$SANDBOX/other/x"; then bad "CLI home: an outside path is not refused"; else ok "CLI home: an outside path is not refused"; fi
if uhome "$SANDBOX/no-such-dir/x"; then ok "CLI home: a path that cannot be resolved fails closed (refused)"; else bad "CLI home: a path that cannot be resolved fails closed (refused)"; fi
# Identity, not spelling: a symlink to the home, a '..' spelling, and a CLI home entry that is itself a symlink.
sbx_ln "$UH" "$SANDBOX/uhome-link"
if uhome "$SANDBOX/uhome-link/.claude/canary"; then ok "CLI home: a path through a symlink to HOME is refused (identity)"; else bad "CLI home: a path through a symlink to HOME is refused (identity)"; fi
if uhome "$UH/plain/../.claude/canary"; then ok "CLI home: a '..' spelling is refused (physical)"; else bad "CLI home: a '..' spelling is refused (physical)"; fi
UH2="$SANDBOX/uhome2"
sbx_mkdir "$UH2" "$SANDBOX/moved-home/deep"
printf 'x\n' | sbx_put "$SANDBOX/moved-home/deep/canary"
sbx_ln "$SANDBOX/moved-home" "$UH2/.claude"
uhome2() { /bin/bash -c 'export HOME="$1"; . "$2"; spike_under_cli_home "$3"' _ "$UH2" "$COMMON" "$1" >/dev/null 2>&1; }
if uhome2 "$SANDBOX/moved-home/deep/canary"; then ok "CLI home: a home entry that is a symlink refuses the directory it points at"; else bad "CLI home: a home entry that is a symlink refuses the directory it points at"; fi
# Opus finding 5: a hard link to a canary outside every home is refused (the link count cannot show where it leads).
sbx_mkdir "$SANDBOX/hl"
ln "$UH/.claude/canary" "$SANDBOX/hl/claude"
if uhome "$SANDBOX/hl/claude"; then ok "CLI home: a hard link to a canary is refused (identity, link count)"; else bad "CLI home: a hard link to a canary is refused (identity, link count)"; fi
env -u SPIKE_LIVE HOME="$UH" /bin/bash -c '. "$1"; spike_mark_verified "$2" claude' _ "$COMMON" "$SANDBOX/hl/claude" >/dev/null 2>&1
eq "registration refuses a hard link to a canary (rc 2)" "2" "$?"
reg_hl="$(env -u SPIKE_LIVE HOME="$UH" PATH="$SANDBOX/hl:$PATH" /bin/bash -c '. "$1"; spike_register_cli claude; echo "RC=$? STATUS=$SPIKE_REG_STATUS COPY=$SPIKE_VERIFIED_COPY"' _ "$COMMON" 2>/dev/null)"
has "spike_register_cli reports the hard link as refused" "$reg_hl" "STATUS=hardlink"
# CHANGED in round 8 (item 1): spike_run_timed accepts exactly `jq --version` and `git --version`; file(1) is gone, so it is
# refused whatever it is asked about (it was: refused on a canary and a hard link, still run on an ordinary file, rc 0).
: >| "$SANDBOX/probe-file.out"
HOME="$FH" spike_run_timed 5 "$SANDBOX/probe-file.out" file "$FH/.claude/canary" >/dev/null 2>&1
eq "spike_run_timed refuses file(1) on a canary inside a CLI home (rc 2)" "2" "$?"
HOME="$UH" spike_run_timed 5 "$SANDBOX/probe-file.out" file "$SANDBOX/hl/claude" >/dev/null 2>&1
eq "spike_run_timed refuses file(1) on a hard link to a canary (rc 2)" "2" "$?"
lacks "spike_run_timed never ran file(1) on the canary (nothing in the output file)" "$(cat "$SANDBOX/probe-file.out")" "text"
HOME="$UH" spike_run_timed 5 "$SANDBOX/probe-file.out" file "$SANDBOX/rp/real/target" >/dev/null 2>&1
eq "spike_run_timed now refuses file(1) even on an ordinary file (rc 2; file was dropped from the tool list)" "2" "$?"
eq "nothing was written to the probe output file by any refused probe" "" "$(cat "$SANDBOX/probe-file.out")"
check "the hard-linked canary was never copied anywhere" /bin/bash -c '! grep -rq "^x$" "$1"/spike-verify.*/claude 2>/dev/null' _ "$SANDBOX"
# Sonnet audit: HOME unset, relative or pointed away must not lift the refusal of the account's own home.
if /bin/bash -c 'unset HOME; . "$1"; spike_under_cli_home "$2"' _ "$COMMON" "$UH/plain/bin/claude" >/dev/null 2>&1; then bad "CLI home: HOME unset: an unrelated path is judged by the account home, not refused blindly"; else ok "CLI home: HOME unset: an unrelated path is judged by the account home, not refused blindly"; fi
PWHOME="$(/usr/bin/perl -e 'print((getpwuid($<))[7])')"
eq "candidate homes include the password-database home when HOME is unset" "$PWHOME" "$(libp 'candidate_homes($ARGV[0], undef)' "$PWHOME")"
eq "candidate homes include the password-database home when HOME points away" "$PWHOME|$SANDBOX/elsewhere" "$(libp 'candidate_homes($ARGV[0], $ARGV[1])' "$PWHOME" "$SANDBOX/elsewhere")"
eq "candidate homes ignore a relative HOME and keep the password-database home" "$PWHOME" "$(libp 'candidate_homes($ARGV[0], $ARGV[1])' "$PWHOME" "relative/home")"
eq "candidate homes ignore a HOME of /" "$PWHOME" "$(libp 'candidate_homes($ARGV[0], "/")' "$PWHOME")"
eq "candidate homes ignore a HOME with a control character" "$PWHOME" "$(libp 'candidate_homes($ARGV[0], "/x\ny")' "$PWHOME")"
eq "the helper's current homes (no HOME given) are the password-database home" "$PWHOME" "$(libp 'current_homes()')"
# Opus finding 6: the verify directory cannot be a CLI home, nor live inside one.
denied "spike_run_status with the verify directory variable pointed at a CLI home (rc 3)" "export HOME='$FH'; _SPIKE_VERIFY_DIR='$FH/.claude'; spike_run_status 5 /dev/null '$FH/.claude/claude' --version"
sbx_mkdir "$FH/.claude/spike-verify.abcdef12"
chmod 700 "$FH/.claude/spike-verify.abcdef12"
: >| "$FH/.claude/spike-verify.abcdef12/.registry"
denied "spike_run_status with a look-alike verify directory inside a CLI home (rc 3)" "export HOME='$FH'; _SPIKE_VERIFY_DIR='$FH/.claude/spike-verify.abcdef12'; spike_run_status 5 /dev/null '$FH/.claude/spike-verify.abcdef12/claude' --version"
env -u SPIKE_LIVE HOME="$FH" TMPDIR="$FH/.claude" /bin/bash -c '. "$1"; spike_verify_init' _ "$COMMON" >/dev/null 2>&1
eq "the helper refuses to create the verify directory inside a CLI home (rc 5)" "5" "$?"
eq "no verify directory was created inside the CLI home (only the look-alike made by this test is there)" "1" "$(count_glob "$FH/.claude"/spike-verify.*)"
sbx_mkdir "$SANDBOX/loose-tmp"
chmod 777 "$SANDBOX/loose-tmp"
env -u SPIKE_LIVE TMPDIR="$SANDBOX/loose-tmp" /bin/bash -c '. "$1"; spike_verify_init' _ "$COMMON" >/dev/null 2>&1
eq "the helper refuses to create the verify directory in a world-writable non-sticky directory (rc 5)" "5" "$?"

# --- Opus finding 8: timeouts are decimal, leading zeros are not octal -----------------------------------------------------
tsec() { /bin/bash -c '. "$1"; _spike_secs "$2"' _ "$COMMON" "$1" 2>/dev/null; }
eq "timeout 08 is decimal 8" "8" "$(tsec 08)"
eq "timeout 010 is decimal 10 (not octal 8)" "10" "$(tsec 010)"
eq "timeout 0005 is decimal 5" "5" "$(tsec 0005)"
eq "timeout 3600 is accepted" "3600" "$(tsec 3600)"
eq "timeout 0 is refused" "" "$(tsec 0)"
eq "timeout 000 is refused" "" "$(tsec 000)"
eq "timeout 3601 is refused" "" "$(tsec 3601)"
eq "timeout 99999999999999999999 is refused" "" "$(tsec 99999999999999999999)"
eq "timeout 1e3 is refused" "" "$(tsec 1e3)"
eq "timeout -5 is refused" "" "$(tsec -5)"
eq "timeout with a space is refused" "" "$(tsec '5 ')"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 08 /dev/null true' _ "$COMMON" >/dev/null 2>&1
eq "spike_run_timeout 08 runs (decimal, rc 0)" "0" "$?"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 010 /dev/null true' _ "$COMMON" >/dev/null 2>&1
eq "spike_run_timeout 010 runs (decimal, rc 0)" "0" "$?"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 0 /dev/null true' _ "$COMMON" >/dev/null 2>&1
eq "spike_run_timeout 0 is a usage error (rc 2)" "2" "$?"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 7200 /dev/null true' _ "$COMMON" >/dev/null 2>&1
eq "spike_run_timeout 7200 is a usage error (rc 2)" "2" "$?"

# --- Opus finding 9: no spike-verify.* temporary file outside the private directory, and none left after a TERM ------------
fsmode slow
rm -f "$SANDBOX"/leak.ready
/bin/bash -c '. "$1"; : >| "$3"; spike_mark_verified "$2" claude' _ "$COMMON" "$RG/claude" "$SANDBOX/leak.ready" >/dev/null 2>&1 &
LEAKPID=$!
n=0
while [ ! -e "$SANDBOX/leak.ready" ] && [ "$n" -lt 30 ]; do sleep 0.1; n=$((n + 1)); done
sleep 0.5
kill -s TERM "$LEAKPID" 2>/dev/null
{ wait "$LEAKPID"; } 2>/dev/null
fsmode good
leaked=0
for f in "$SANDBOX"/spike-verify.* "$SANDBOX"/spike-preflight.*; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  if [ ! -d "$f" ] || [ -L "$f" ]; then leaked=$((leaked + 1)); echo "leaked non-directory: $f"; fi
done
eq "TERM during a registration leaves no temporary file outside a private verify directory" "0" "$leaked"
eq "common.sh never makes a spike-verify.* scratch file itself (the signer text is read from a pipe inside the helper)" "0" "$(grep -c 'spike-verify\.X' "$COMMON_REAL")"

# --- Round 8, item 1: spike_run_timed runs exactly `jq --version` and `git --version`, nothing else ------------------------
# (This replaces the round-7 block that ran a fake jq from PATH and read its environment: a script first on PATH is now refused
# and never run. The closed environment of a child is proven for every mode by the "closed set" tests below, which use the same
# code path in the helper.) The wrappers below leave a marker file if they are ever started.
sbx_mkdir "$SANDBOX/probebin"
for t in jq git; do
  sbx_put "$SANDBOX/probebin/$t" <<EOF
#!/bin/sh
touch "$SANDBOX/probebin/ran-$t-\$\$"
echo "$t-wrapper"
EOF
  chmod +x "$SANDBOX/probebin/$t"
done
pran() { count_glob "$SANDBOX/probebin"/ran-*; }
PROBE="$SANDBOX/probe.out"
: >| "$PROBE"
JQ_PHYS="$(spike_resolve_path "$JQ_BIN")"
case "$JQ_PHYS" in
  /bin/*|/usr/*|/opt/homebrew/*)
    spike_run_timed 5 "$PROBE" jq --version
    eq "spike_run_timed runs the real jq --version (rc 0)" "0" "$?"
    has "spike_run_timed captured the real jq version" "$(cat "$PROBE")" "jq-"
    : >| "$PROBE"
    spike_run_timed 5 "$PROBE" "$JQ_PHYS" --version
    eq "spike_run_timed runs jq --version given by its absolute path (rc 0)" "0" "$?"
    ;;
  *) printf 'skip spike_run_timed positive jq tests: jq is not in a system or package-manager prefix (%s)\n' "$JQ_PHYS" ;;
esac
: >| "$PROBE"
spike_run_timed 5 "$PROBE" git --version
eq "spike_run_timed runs the real git --version (rc 0)" "0" "$?"
has "spike_run_timed captured the real git version" "$(cat "$PROBE")" "git version"
: >| "$PROBE"
# probe_refused <label> <args...>: spike_run_timed must refuse (rc 2), start nothing and write nothing.
probe_refused() {
  local label="$1" rc
  shift
  : >| "$PROBE"
  spike_run_timed 5 "$PROBE" "$@" >/dev/null 2>&1
  rc=$?
  eq "spike_run_timed refuses $label (rc 2)" "2" "$rc"
  eq "spike_run_timed $label: nothing was written" "" "$(cat "$PROBE")"
  eq "spike_run_timed $label: no wrapper or alias ran" "0" "$(pran)"
}
probe_refused "git -c with an alias that runs a program" git -c "alias.v=!touch $SANDBOX/probebin/ran-alias-1" v
probe_refused "git --version followed by an alias definition" git --version -c "alias.v=!touch $SANDBOX/probebin/ran-alias-2"
probe_refused "git with an exec-path option" git --exec-path="$SANDBOX/probebin" --version
probe_refused "git status" git status
probe_refused "git with no argument" git
probe_refused "jq -L (module search path)" jq -L "$SANDBOX/probebin" --version
probe_refused "jq -n with an import program" jq -n 'import "x" as x; .'
probe_refused "jq --version with an extra option" jq --version --help
probe_refused "jq with a control character argument" jq $'--version\n'
probe_refused "jq --version followed by a newline argument" jq --version $'\n'
probe_refused "jq --version with a provider name" jq --version claude
probe_refused "file(1)" file --version
probe_refused "a provider CLI name" claude --version
probe_refused "a shell" sh -c true
probe_refused "an empty argument" jq ""
# A jq (or git) WRAPPER first on PATH is refused and never started, and there is no fallthrough to the real tool behind it.
for t in jq git; do
  : >| "$PROBE"
  PATH="$SANDBOX/probebin:$PATH" spike_run_timed 5 "$PROBE" "$t" --version >/dev/null 2>&1
  eq "spike_run_timed refuses a $t wrapper first on PATH (rc 2)" "2" "$?"
  eq "the $t wrapper first on PATH was never started (marker absent)" "0" "$(pran)"
  eq "the $t wrapper first on PATH wrote nothing" "" "$(cat "$PROBE")"
  spike_run_timed 5 "$PROBE" "$SANDBOX/probebin/$t" --version >/dev/null 2>&1
  eq "spike_run_timed refuses the $t wrapper by absolute path (rc 2)" "2" "$?"
  eq "the $t wrapper by absolute path was never started" "0" "$(pran)"
done
# A native binary copied into a user directory is not a system tool either.
sbx_mkdir "$SANDBOX/probebin2"
sbx_cp "$(type -P true)" "$SANDBOX/probebin2/jq"
PATH="$SANDBOX/probebin2:$PATH" spike_run_timed 5 "$PROBE" jq --version >/dev/null 2>&1
eq "spike_run_timed refuses a native copy named jq in a user directory (rc 2)" "2" "$?"
# tool-path (preflight's presence check) applies the same identity test.
eq "spike_tool_path finds no wrapper first on PATH" "" "$(PATH="$SANDBOX/probebin:$PATH" spike_tool_path jq)"
case "$JQ_PHYS" in
  /bin/*|/usr/*|/opt/homebrew/*) eq "spike_tool_path finds the real jq" "$JQ_PHYS" "$(spike_tool_path jq)" ;;
esac

# --- spike_resolve_path / spike_run_timeout --------------------------------------------------------------------------
sbx_mkdir "$SANDBOX/rp/real"
printf 'x\n' | sbx_put "$SANDBOX/rp/real/target"
sbx_ln real/target "$SANDBOX/rp/link1"
sbx_ln "$SANDBOX/rp/link1" "$SANDBOX/rp/link2"
eq "resolve_path follows a symlink chain" "$SANDBOX/rp/real/target" "$(spike_resolve_path "$SANDBOX/rp/link2")"

spike_run_timeout 5 /dev/null true
eq "run_timeout returns 0 for true" "0" "$?"
spike_run_timeout 5 /dev/null false
eq "run_timeout returns the command exit code" "1" "$?"
START="$(date +%s)"
spike_run_timeout 1 /dev/null sleep 5
eq "run_timeout returns 124 on timeout" "124" "$?"
check "run_timeout returned promptly" test "$(($(date +%s) - START))" -lt 4

# Environment is scrubbed (rules 2 and 4): only PATH HOME TMPDIR LANG TERM (and USER, LOGNAME) reach the child.
ENVOUT="$SANDBOX/env.out"
: >| "$ENVOUT"
SPIKE_TEST_SECRET=hunter2 SPIKE_LIVE=1 USER=tu LOGNAME=tu spike_run_live 5 "$ENVOUT" env
has "run_timeout passes PATH" "$(cat "$ENVOUT")" "PATH="
has "run_timeout passes HOME" "$(cat "$ENVOUT")" "HOME="
has "run_timeout passes USER (CLIs look up their own login by account name)" "$(cat "$ENVOUT")" "USER=tu"
lacks "run_timeout drops other variables" "$(cat "$ENVOUT")" "hunter2"
lacks "run_timeout drops SPIKE_LIVE" "$(cat "$ENVOUT")" "SPIKE_LIVE"
lacks "run_timeout drops the helper's own SPIKE_IN_ inputs" "$(cat "$ENVOUT")" "SPIKE_IN_"
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
: >| "$ENVOUT"
SPIKE_LIVE=1 spike_run_live 5 "$ENVOUT" env
closed_set_check "env" "$ENVOUT"
lacks "probe FOO_API_KEY is not passed" "$(cat "$ENVOUT")" "FOO_API_KEY"
lacks "probe FOO_HOME is not passed" "$(cat "$ENVOUT")" "FOO_HOME"
lacks "probe FOO_CONFIG_DIR is not passed" "$(cat "$ENVOUT")" "FOO_CONFIG_DIR"
: >| "$ENVOUT"
SPIKE_LIVE=1 spike_run_live 5 "$ENVOUT" /bin/sh -c env
closed_set_check "sh -c env" "$ENVOUT"
: >| "$ENVOUT"
SPIKE_LIVE=1 spike_run_live 5 "$ENVOUT" /bin/bash -c env
closed_set_check "bash -c env" "$ENVOUT"
unset FOO_API_KEY FOO_HOME FOO_CONFIG_DIR BAR_TOKEN HTTPS_PROXY SSH_AUTH_SOCK XDG_CONFIG_HOME

# The whole process group dies on timeout: a launcher that spawns a grandchild leaves no orphan.
sbx_put "$SANDBOX/launcher.sh" <<EOF
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
sbx_put "$SANDBOX/leaver.sh" <<EOF
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
/usr/bin/perl -e 'my $p = fork; exit 0 unless $p; open my $f, ">", $ARGV[0] or exit 1; print $f "$p\n"; close $f; sleep 6' \
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
  sbx_put "$SANDBOX/siglauncher.sh" <<EOF
#!/bin/sh
sleep 33 &
echo "\$\$ \$!" > "$SANDBOX/sig.pids.tmp"
mv "$SANDBOX/sig.pids.tmp" "$SANDBOX/sig.pids"
wait
EOF
  chmod +x "$SANDBOX/siglauncher.sh"
  SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 60 /dev/null "$2"; echo AFTER' _ "$COMMON" "$SANDBOX/siglauncher.sh" >| "$SANDBOX/sig.out" 2>/dev/null &
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

# Orphan sweep: the caller is killed with SIGKILL, so no trap can run. The helper notices that its parent changed and kills
# the command's group: the CLI and its grandchild must be gone within 3 s (bounded poll, gone_within).
sbx_put "$SANDBOX/orphan.sh" <<EOF
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

# Signal race: the window between `&` and `$!` is a few microseconds, so the handler is tested directly. A signal that
# arrives before the helper's pid is known is recorded and nothing exits.
out="$(/bin/bash -c '. "$1"; _SPIKE_BG=""; _spike_forward 143; echo "PEND=$_SPIKE_BG_PENDING"; echo CONTINUED' _ "$COMMON" 2>/dev/null)"
has "caller: a signal before the helper exists is recorded for the handoff" "$out" "PEND=143"
has "caller: a signal before the helper exists does not exit" "$out" "CONTINUED"

# Stress: TERM or HUP sent right after the start of a live run leaves no command running. This exercises the path; it does
# not prove the few-microsecond window is hit on every run.
sbx_put "$SANDBOX/strl.sh" <<EOF
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
sbx_mkdir "$CAPREPO"
check "the capture repo directory exists" test -d "$CAPREPO"
git -C "$CAPREPO" init -q
SPIKE_CAPTURES_ROOT="$CAPREPO/captures" spike_capture_dir demo >/dev/null 2>&1
eq "capture dir refuses a root inside a repo that does not ignore it (rc)" "2" "$?"
check "refused capture root was not created" test ! -e "$CAPREPO/captures"
printf 'captures/\n' | sbx_put "$CAPREPO/.gitignore"
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

# =====================================================================================================================
# Round 8 (policy)
# =====================================================================================================================
fsmode good

# --- item 3: the load-once guard looks for the function, not for an inherited variable ------------------------------------
out="$(SPIKE_COMMON_LOADED=1 env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_require_live; echo CONTINUED' _ "$COMMON" 2>/dev/null)"
eq "an inherited SPIKE_COMMON_LOADED does not skip loading: the live gate still stops the script (rc 3)" "3" "$?"
lacks "an inherited SPIKE_COMMON_LOADED does not skip loading: the script is stopped" "$out" "CONTINUED"
out="$(SPIKE_COMMON_LOADED=1 /bin/bash -c '. "$1"; declare -F spike_run_live spike_require_live | wc -l' _ "$COMMON" 2>/dev/null)"
eq "an inherited SPIKE_COMMON_LOADED does not skip loading: the functions are defined" "2" "$(printf '%s' "$out" | tr -d ' ')"
out="$(env -u SPIKE_LIVE /bin/bash -c '. "$1"; . "$1"; echo SECOND-OK; spike_require_live; echo CONTINUED' _ "$COMMON" 2>&1)"
has "sourcing the library twice in one shell is harmless (no readonly error)" "$out" "SECOND-OK"
lacks "sourcing the library twice prints no readonly error" "$out" "readonly"
lacks "the library is still loaded after the second source (the gate stops the script)" "$out" "CONTINUED"
eq "common.sh no longer reads a SPIKE_COMMON_LOADED variable" "0" "$(grep -c 'SPIKE_COMMON_LOADED' "$COMMON_REAL")"
has "common.sh guards loading with declare -F spike_require_live" "$(cat "$COMMON_REAL")" 'declare -F spike_require_live'

# --- item 5: CLI-home names come from compliance/denylist.txt at run time; an unusable file fails closed ------------------
lacks "runner.pl no longer builds CLI home names from parts" "$(cat "$RUNNER_REAL")" "'cod' . 'ex'"
has "runner.pl reads the lead-owned denylist file" "$(cat "$RUNNER_REAL")" 'compliance/denylist.txt'
sbx_put "$SANDBOX/dl-run.sh" <<EOF
#!/bin/sh
touch "$SANDBOX/dl-marker"
exit 0
EOF
chmod +x "$SANDBOX/dl-run.sh"
DLN=0
mkdl() { # mkdl: a sandbox copy of the repo layout WITHOUT a denylist; sets DLROOT
  DLN=$((DLN + 1))
  DLROOT="$SANDBOX/dl$DLN"
  sbx_mkdir "$DLROOT/spike/lib" "$DLROOT/compliance"
  sbx_cp "$COMMON_REAL" "$DLROOT/spike/lib/common.sh"
  sed "s|^use constant CODESIGN_BIN => .*|use constant CODESIGN_BIN => \"$FSCS\";|" "$RUNNER_REAL" | sbx_put "$DLROOT/spike/lib/runner.pl"
}
dl_closed() { # dl_closed <label>: the layout in $DLROOT must refuse everything with rc 121 and the fixed message
  local label="$1" c="$DLROOT/spike/lib/common.sh" o rc
  rm -f "$SANDBOX/dl-marker"
  o="$(SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 5 /dev/null "$2"; echo "RC=$?"' _ "$c" "$SANDBOX/dl-run.sh" 2>&1)"
  has "denylist $label: a live run is refused with rc 121" "$o" "RC=121"
  has "denylist $label: the fixed message is printed" "$o" "the CLI-home denylist (compliance/denylist.txt) is missing, empty or malformed"
  check_absent "denylist $label: the command did not run (marker absent)" "$SANDBOX/dl-marker"
  env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null true' _ "$c" >/dev/null 2>&1
  eq "denylist $label: even the ungated 'true' is refused (rc 121)" "121" "$?"
  /bin/bash -c '. "$1"; spike_under_cli_home "$2"' _ "$c" "$SANDBOX/other/x" >/dev/null 2>&1
  eq "denylist $label: spike_under_cli_home refuses every path (fail closed, rc 0)" "0" "$?"
  /bin/bash -c '. "$1"; spike_resolve_path /usr/bin' _ "$c" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then ok "denylist $label: even resolving a path is refused"; else bad "denylist $label: even resolving a path is refused"; fi
  env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" claude' _ "$c" "$RG/claude" >/dev/null 2>&1
  eq "denylist $label: registration is refused (rc 2)" "2" "$?"
  /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/perl "$DLROOT/spike/lib/runner.pl" resolve /usr/bin >/dev/null 2>&1
  eq "denylist $label: the helper itself exits with the distinct status 121" "121" "$?"
  /bin/bash -c '. "$1"; spike_root' _ "$c" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then ok "denylist $label: spike_root refuses (cannot check the scratch root)"; else bad "denylist $label: spike_root refuses (cannot check the scratch root)"; fi
}
mkdl
dl_closed "missing file"
mkdl
sbx_put "$DLROOT/compliance/denylist.txt" </dev/null
dl_closed "empty file"
mkdl
printf '# only comments\n\n   \n# and blanks\n' | sbx_put "$DLROOT/compliance/denylist.txt"
dl_closed "comments and blank lines only"
for bad_entry in 'claude' '.a/b' '..' '.' '.a b' '/etc' '.ok\n.bad entry' '.ok\r' '.ok\0.bad' '-x' '.a*'; do
  mkdl
  printf -- "$bad_entry\\n" | sbx_put "$DLROOT/compliance/denylist.txt"
  dl_closed "malformed entry [$bad_entry]"
done
mkdl
sbx_ln "$DENYLIST_REAL" "$DLROOT/compliance/denylist.txt"
dl_closed "denylist is a symlink (opened O_NOFOLLOW)"
mkdl
sbx_mkdir "$DLROOT/compliance/denylist.txt"
dl_closed "denylist is a directory"
# Positive controls: comments, blank lines, indentation and trailing comments are accepted; ONLY the listed names are refused.
mkdl
printf '# header\n\n  .alpha-home  \n.beta # trailing comment\n' | sbx_put "$DLROOT/compliance/denylist.txt"
DLH="$SANDBOX/dlhome"
sbx_mkdir "$DLH/.alpha-home" "$DLH/.beta" "$DLH/.claude" "$DLH/plain"
for d in .alpha-home .beta .claude plain; do printf 'x\n' | sbx_put "$DLH/$d/f"; done
dlhome() { /bin/bash -c 'export HOME="$1"; . "$2"; spike_under_cli_home "$3"' _ "$DLH" "$DLROOT/spike/lib/common.sh" "$1" >/dev/null 2>&1; }
if dlhome "$DLH/.alpha-home/f"; then ok "denylist: an indented entry of the file is refused"; else bad "denylist: an indented entry of the file is refused"; fi
if dlhome "$DLH/.beta/f"; then ok "denylist: an entry with a trailing comment is refused"; else bad "denylist: an entry with a trailing comment is refused"; fi
if dlhome "$DLH/.claude/f"; then bad "denylist: a name that is NOT in the file is not refused (the list is the file, not code)"; else ok "denylist: a name that is NOT in the file is not refused (the list is the file, not code)"; fi
if dlhome "$DLH/plain/f"; then bad "denylist: an ordinary path is not refused"; else ok "denylist: an ordinary path is not refused"; fi
# the real file, read from this very sandbox copy, is what the earlier loop used: it must equal the lead-owned file
eq "the sandbox copy of the denylist used by the other tests is the lead-owned file" "" "$(diff "$DENYLIST_REAL" "$SANDBOX/ut/compliance/denylist.txt")"

# --- item 6: the child's HOME is always the password-database home; another HOME refuses the run (rc 125) -----------------
sbx_put "$SANDBOX/homeprobe.sh" <<EOF
#!/bin/sh
touch "$SANDBOX/home-ran"
exit 0
EOF
chmod +x "$SANDBOX/homeprobe.sh"
sbx_mkdir "$SANDBOX/elsewhere"
sbx_ln "$PWHOME" "$SANDBOX/homelink"
HOMEOUT="$SANDBOX/home.out"
# chome <HOME value | -unset> [cmd...]: a live run of `env` with that HOME; sets CRC and CHOME (the HOME line the child printed)
chome() {
  local h="$1"
  : >| "$HOMEOUT"
  rm -f "$SANDBOX/home-ran"
  if [ "$h" = "-unset" ]; then
    env -u HOME SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 5 "$2" env' _ "$COMMON" "$HOMEOUT" >/dev/null 2>&1
  else
    env HOME="$h" SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 5 "$2" env' _ "$COMMON" "$HOMEOUT" >/dev/null 2>&1
  fi
  CRC=$?
  CHOME="$(grep '^HOME=' "$HOMEOUT")"
}
chome "$PWHOME"
eq "HOME = the account home: the run proceeds (rc 0)" "0" "$CRC"
eq "HOME = the account home: the child's HOME is the account home" "HOME=$PWHOME" "$CHOME"
chome -unset
eq "HOME unset: the run proceeds (rc 0)" "0" "$CRC"
eq "HOME unset: the child's HOME is the account home" "HOME=$PWHOME" "$CHOME"
chome ""
eq "HOME empty: the run proceeds (rc 0)" "0" "$CRC"
eq "HOME empty: the child's HOME is the account home" "HOME=$PWHOME" "$CHOME"
chome "$SANDBOX/homelink"
eq "HOME = a symlink to the account home (same device and inode): the run proceeds (rc 0)" "0" "$CRC"
eq "HOME = a symlink to the account home: the child's HOME is the account home, not the link" "HOME=$PWHOME" "$CHOME"
for h in "$SANDBOX/elsewhere" "$SANDBOX/no-such-home" "relative/home" "/"; do
  chome "$h"
  eq "HOME pointed away [$h]: the run is refused (rc 125)" "125" "$CRC"
  eq "HOME pointed away [$h]: the child printed nothing" "" "$(cat "$HOMEOUT")"
done
rm -f "$SANDBOX/home-ran"
HOME="$SANDBOX/elsewhere" SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 5 /dev/null "$2"' _ "$COMMON" "$SANDBOX/homeprobe.sh" >/dev/null 2>&1
eq "HOME pointed away: a live run of a marker script is refused (rc 125)" "125" "$?"
check_absent "HOME pointed away: the marker script was never started" "$SANDBOX/home-ran"
HOME="$SANDBOX/elsewhere" env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_run_timeout 5 /dev/null true' _ "$COMMON" >/dev/null 2>&1
eq "HOME pointed away: an ungated run (true) is refused too (rc 125)" "125" "$?"
HOME="$SANDBOX/elsewhere" /bin/bash -c '. "$1"; spike_run_timed 5 /dev/null git --version' _ "$COMMON" >/dev/null 2>&1
eq "HOME pointed away: a git --version probe is refused too (rc 125)" "125" "$?"
# The fixed codesign the helper starts for registration also gets the account home, never the caller's HOME.
: >| "$FSDIR/homelog"
HOME="$SANDBOX/elsewhere" env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" claude' _ "$COMMON" "$RG/claude" >/dev/null 2>&1
eq "registration with HOME pointed away still registers (it runs nothing of the caller's)" "0" "$?"
has "the fake codesign ran with the account home" "$(cat "$FSDIR/homelog")" "HOME=$PWHOME"
lacks "the fake codesign never saw the caller's alternate HOME" "$(cat "$FSDIR/homelog")" "elsewhere"
has "runner.pl documents the HOME refusal in its check (rc 125 text)" "$(cat "$RUNNER_REAL")" 'HOME is not the account home'

# --- item 2: the output file ----------------------------------------------------------------------------------------------
# These runs use the ut2 layout, whose account home is the fake home $FH, so HOME=$FH is a legitimate caller and a CLI home
# under it is a real CLI home to the helper.
sbx_put "$SANDBOX/outprobe.sh" <<EOF
#!/bin/sh
touch "$SANDBOX/outprobe-ran"
echo OUTPUT-LINE
exit 0
EOF
chmod +x "$SANDBOX/outprobe.sh"
out2() { # out2 <outfile>: live run of the probe script with HOME = the ut2 account home; sets ORC
  rm -f "$SANDBOX/outprobe-ran"
  HOME="$FH" SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 5 "$2" "$3"' _ "$COMMON2" "$1" "$SANDBOX/outprobe.sh" >/dev/null 2>&1
  ORC=$?
}
printf 'CANARY-ROOT-9d1e\n' >| "$FH/.claude/canary"
out2 "$SANDBOX/out-new"
eq "outfile: a new file under the sandbox is written (rc 0)" "0" "$ORC"
eq "outfile: the child's output went to the new file" "OUTPUT-LINE" "$(cat "$SANDBOX/out-new")"
eq "outfile: the new file has mode 0600" "-rw-------" "$(ls -l "$SANDBOX/out-new" | cut -c1-10)"
printf 'before\n' | sbx_put "$SANDBOX/out-app"
out2 "$SANDBOX/out-app"
eq "outfile: an existing file is appended to (rc 0)" "0" "$ORC"
eq "outfile: the earlier content of the appended file is kept" "before OUTPUT-LINE" "$(tr '\n' ' ' < "$SANDBOX/out-app" | sed 's/ $//')"
out2 /dev/null
eq "outfile: the null device is accepted (rc 0)" "0" "$ORC"
check_present() { if [ -e "$2" ]; then ok "$1"; else bad "$1"; fi; }
check_present "outfile: the null-device run started the command" "$SANDBOX/outprobe-ran"
( cd "$SANDBOX" && HOME="$FH" SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 5 out-rel "$2"' _ "$COMMON2" "$SANDBOX/outprobe.sh" >/dev/null 2>&1 )
eq "outfile: a relative path works (rc 0)" "0" "$?"
eq "outfile: the relative file was written in the cwd" "OUTPUT-LINE" "$(cat "$SANDBOX/out-rel" 2>/dev/null)"
# refusals: each is rc 125, nothing runs, nothing is written where it must not be
sbx_ln "$FH/.claude/canary" "$SANDBOX/out-link-canary"
out2 "$SANDBOX/out-link-canary"
eq "outfile: a symlink into a fake CLI home is refused (rc 125)" "125" "$ORC"
eq "outfile: nothing was written to the canary through the symlink" "CANARY-ROOT-9d1e" "$(cat "$FH/.claude/canary")"
check_absent "outfile: the command did not run for the symlink into a CLI home" "$SANDBOX/outprobe-ran"
sbx_ln "$FH/.claude/new-target" "$SANDBOX/out-link-dangling"
out2 "$SANDBOX/out-link-dangling"
eq "outfile: a dangling symlink into a fake CLI home is refused (rc 125)" "125" "$ORC"
check_absent "outfile: the dangling symlink's target inside the CLI home was not created" "$FH/.claude/new-target"
printf 'plain\n' | sbx_put "$SANDBOX/out-plain"
sbx_ln "$SANDBOX/out-plain" "$SANDBOX/out-link-plain"
out2 "$SANDBOX/out-link-plain"
eq "outfile: a symlink to an ordinary file is refused too (rc 125)" "125" "$ORC"
eq "outfile: the file behind that symlink is unchanged" "plain" "$(cat "$SANDBOX/out-plain")"
out2 "$FH/.claude/out-direct"
eq "outfile: a new file whose parent is a CLI home is refused (rc 125)" "125" "$ORC"
check_absent "outfile: the file inside the CLI home was not created" "$FH/.claude/out-direct"
sbx_ln "$FH/.claude" "$SANDBOX/dirlink"
out2 "$SANDBOX/dirlink/out-via"
eq "outfile: a file whose parent directory is a symlink into a CLI home is refused (rc 125)" "125" "$ORC"
check_absent "outfile: nothing was created through the symlinked parent" "$FH/.claude/out-via"
printf 'CANARY-ENTRY\n' | sbx_put "$FH/.cl""aude.json"
out2 "$FH/.cl""aude.json"
eq "outfile: a single-file CLI home entry directly under the home is refused (rc 125)" "125" "$ORC"
eq "outfile: that entry is unchanged" "CANARY-ENTRY" "$(cat "$FH/.cl""aude.json")"
printf 'orig\n' | sbx_put "$SANDBOX/out-hl-a"
ln "$SANDBOX/out-hl-a" "$SANDBOX/out-hl-b"
out2 "$SANDBOX/out-hl-b"
eq "outfile: a hard-linked file is refused (rc 125)" "125" "$ORC"
eq "outfile: the hard-linked file is unchanged" "orig" "$(cat "$SANDBOX/out-hl-a")"
ln "$FH/.claude/canary" "$SANDBOX/out-hl-canary"
out2 "$SANDBOX/out-hl-canary"
eq "outfile: a hard link to a canary is refused (rc 125)" "125" "$ORC"
eq "outfile: the canary behind the hard link is unchanged" "CANARY-ROOT-9d1e" "$(cat "$FH/.claude/canary")"
mkfifo "$SANDBOX/out-fifo"
out2 "$SANDBOX/out-fifo"
eq "outfile: a FIFO is refused without blocking (rc 125)" "125" "$ORC"
sbx_mkdir "$SANDBOX/out-dir"
out2 "$SANDBOX/out-dir"
eq "outfile: a directory is refused (rc 125)" "125" "$ORC"
out2 "$SANDBOX/no-such-parent/out"
eq "outfile: a missing parent directory is refused (rc 125)" "125" "$ORC"
check_absent "outfile: none of the refused runs started the command" "$SANDBOX/outprobe-ran"
sbx_ln "$SANDBOX/out-plain" "$SANDBOX/out-link-plain2"
HOME="$PWHOME" SPIKE_LIVE=1 /bin/bash -c '. "$1"; spike_run_live 5 "$2" "$3"' _ "$COMMON" "$SANDBOX/out-link-plain2" "$SANDBOX/outprobe.sh" >/dev/null 2>&1
eq "outfile: the same symlink refusal holds under the real-account layout (rc 125)" "125" "$?"
has "runner.pl opens the outfile O_NOFOLLOW|O_APPEND with mode 0600" "$(cat "$RUNNER_REAL")" 'O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NOCTTY, 0600'

# --- item 7: the narrow binary exception: a file inside a CLI home must look like a vendor binary BEFORE it is opened --------
NB="$SANDBOX/nbin"
sbx_mkdir "$NB" "$FH/.claude/bin"
printf 'CANARY-NARROW-5b1c\n' | sbx_put "$FH/.claude/smallcred"
chmod 600 "$FH/.claude/smallcred"
sbx_ln "$FH/.claude/smallcred" "$NB/claude"
reg2() { # reg2 <dir holding a claude entry>: spike_register_cli claude under ut2 with that dir first on PATH
  env -u SPIKE_LIVE HOME="$FH" PATH="$1:$PATH" /bin/bash -c '. "$1"; spike_register_cli claude; echo "RC=$? STATUS=$SPIKE_REG_STATUS KIND=$SPIKE_REG_KIND COPY=$SPIKE_VERIFIED_COPY"' _ "$COMMON2" 2>/dev/null
}
padexact() { # padexact <file> <size>: append zero bytes (after the script body, which never reaches them) up to exactly <size>
  local f="$1" want="$2" have
  sbx_parent_ok "$f" || return 1
  have="$(wc -c < "$f" | tr -d ' ')"
  [ "$want" -gt "$have" ] && head -c "$((want - have))" /dev/zero >> "$f"
  return 0
}
r="$(reg2 "$NB")"
case "$r" in *STATUS=clihome*|*STATUS=notfound*) ok "narrow exception: a symlink named claude to a small 0600 file in a CLI home is refused (not executable: not even found, so never opened)" ;; *) bad "narrow exception: a symlink named claude to a small 0600 file in a CLI home is refused ($r)" ;; esac
eq "narrow exception: ...and nothing was copied (no copy path reported)" "" "${r#*COPY=}"
chmod 700 "$FH/.claude/smallcred"
r="$(reg2 "$NB")"
has "narrow exception: a small file is refused even when it has the owner-execute bit" "$r" "STATUS=clihome"
chmod 600 "$FH/.claude/smallcred"
printf '\317\372\355\376\nexit 0\n' | sbx_put "$FH/.claude/bigplain"
padexact "$FH/.claude/bigplain" 1100000
chmod 600 "$FH/.claude/bigplain"
sbx_ln "$FH/.claude/bigplain" "$NB/claude"
r="$(reg2 "$NB")"
case "$r" in *STATUS=clihome*|*STATUS=notfound*) ok "narrow exception: a big Mach-O-headed file WITHOUT the owner-execute bit is refused" ;; *) bad "narrow exception: a big Mach-O-headed file WITHOUT the owner-execute bit is refused ($r)" ;; esac
chmod 700 "$FH/.claude/bigplain"
r="$(reg2 "$NB")"
has "narrow exception: the same big file WITH the owner-execute bit is registered (status verified)" "$r" "STATUS=verified"
has "narrow exception: ...as a mach-o" "$r" "KIND=mach-o"
CPY="${r#*COPY=}"
eq "narrow exception: the WHOLE vendor binary is copied for verification (same size)" "$(wc -c < "$FH/.claude/bigplain" | tr -d ' ')" "$(wc -c < "$CPY" 2>/dev/null | tr -d ' ')"
printf '\317\372\355\376\nexit 0\n' | sbx_put "$FH/.claude/edge-low"
padexact "$FH/.claude/edge-low" 1048575
chmod 700 "$FH/.claude/edge-low"
sbx_ln "$FH/.claude/edge-low" "$NB/claude"
r="$(reg2 "$NB")"
has "narrow exception: 1 MiB minus one byte is refused" "$r" "STATUS=clihome"
printf '\317\372\355\376\nexit 0\n' | sbx_put "$FH/.claude/edge-ok"
padexact "$FH/.claude/edge-ok" 1048576
chmod 700 "$FH/.claude/edge-ok"
sbx_ln "$FH/.claude/edge-ok" "$NB/claude"
r="$(reg2 "$NB")"
has "narrow exception: exactly 1 MiB with the owner-execute bit is accepted" "$r" "STATUS=verified"
printf '\177ELF\002\001\001\000 not a mach-o\n' | sbx_put "$FH/.claude/bigelf"
padexact "$FH/.claude/bigelf" 1100000
chmod 700 "$FH/.claude/bigelf"
sbx_ln "$FH/.claude/bigelf" "$NB/claude"
r="$(reg2 "$NB")"
has "narrow exception: a big executable that is not a Mach-O is still refused (not read beyond the magic, not copied)" "$r" "STATUS=clihome"
eq "narrow exception: the canary text was never copied into a verify directory" "0" "$(grep -rl 'CANARY-NARROW-5b1c' "$SANDBOX" 2>/dev/null | grep -c 'spike-verify')"
# "never opened": proven by a seam (open_ro recorded) and, where strace works, by the system-call trace.
VD2="$(/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C SPIKE_IN_PATH="$PATH" SPIKE_IN_TMPDIR="$SANDBOX" SPIKE_IN_HOME="$FH" /usr/bin/perl "$RUNNER2" vdir-create $$)"
check_present "narrow exception: the seam test has a private verify directory" "$VD2/.registry"
printf 'CANARY-SEAM-77aa\n' | sbx_put "$FH/.claude/smallexec"
chmod 700 "$FH/.claude/smallexec"
seam_register() { # seam_register <path>: cmd_register in path mode with open_ro recorded; prints the opened paths
  /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /usr/bin/perl -e '
    my ($rf, $vd, $p) = @ARGV;
    require $rf;
    no warnings "redefine";
    my @opened;
    my $orig = \&main::open_ro;
    *main::open_ro = sub { push @opened, $_[0]; return $orig->(@_); };
    open(my $save, ">&", \*STDOUT);
    open(STDOUT, ">", "/dev/null");
    main::cmd_register($vd, "claude", "path", $p);
    open(STDOUT, ">&", $save);
    print "OPENED=" . join(",", @opened) . "\n";' "$RUNNER2" "$VD2" "$1"
}
r="$(seam_register "$FH/.claude/smallexec")"
lacks "seam: a small executable file inside a CLI home was never opened" "$r" "smallexec"
r="$(seam_register "$FH/.claude/bigplain")"
has "seam control: the big executable vendor-like file IS opened (the seam sees opens)" "$r" "bigplain"
if command -v strace >/dev/null 2>&1 && strace -f -o "$SANDBOX/strace.probe" -e trace=file /usr/bin/true >/dev/null 2>&1; then
  chmod 700 "$FH/.claude/smallcred"
  sbx_ln "$FH/.claude/smallcred" "$NB/claude"
  VD3="$(/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C SPIKE_IN_PATH="$PATH" SPIKE_IN_TMPDIR="$SANDBOX" SPIKE_IN_HOME="$FH" /usr/bin/perl "$RUNNER2" vdir-create $$)"
  strace -f -e trace=file -o "$SANDBOX/strace.out" /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C SPIKE_IN_PATH="$NB:$PATH" SPIKE_IN_TMPDIR="$SANDBOX" SPIKE_IN_HOME="$FH" /usr/bin/perl "$RUNNER2" register "$VD3" claude name claude >/dev/null 2>&1
  if [ "$(grep -c 'runner.pl' "$SANDBOX/strace.out" 2>/dev/null)" -gt 0 ]; then ok "strace: the trace of the registration run was captured"; else bad "strace: the trace of the registration run was captured"; fi
  if [ "$(grep -c 'smallcred' "$SANDBOX/strace.out" 2>/dev/null)" -gt 0 ]; then ok "strace: the helper looked at the small credential-like file (lstat/readlink)"; else bad "strace: the helper looked at the small credential-like file (lstat/readlink)"; fi
  eq "strace: the small credential-like file inside a CLI home was never opened (no open/openat/creat on it)" "0" "$(grep -E '(open|openat|openat2|creat)\(' "$SANDBOX/strace.out" | grep -c 'smallcred')"
else
  printf 'skip strace test of the narrow exception: strace is not available or may not trace here (the seam test above covers it)\n'
fi
sbx_ln "$FH/.claude/smallcred" "$NB/claude"

# --- round 9: the `magic` subcommand and spike_magic_ok are gone (dead code that could open a file in a CLI home) --------------
chmod 700 "$FH/.claude/smallcred"
magic_run() { # magic_run <file>: runner.pl magic <file> under the ut2 layout; prints "RC=<n>" then the combined output
  local out rc
  out="$(/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C SPIKE_IN_PATH="$PATH" SPIKE_IN_TMPDIR="$SANDBOX" SPIKE_IN_HOME="$FH" /usr/bin/perl "$RUNNER2" magic "$1" 2>&1)"
  rc=$?
  printf 'RC=%s\n%s\n' "$rc" "$out"
}
r="$(magic_run "$FH/.claude/smallcred")"
has "magic: 'runner.pl magic <file>' is an unknown subcommand" "$r" "unknown subcommand: magic"
case "$r" in RC=0*) bad "magic: the unknown subcommand exits non-zero" ;; RC=*) ok "magic: the unknown subcommand exits non-zero" ;; *) bad "magic: the unknown subcommand exits non-zero" ;; esac
lacks "magic: the canary content of a file in a fake CLI home is not printed" "$r" "CANARY-NARROW"
r="$(magic_run "$SANDBOX/ut2/spike/lib/runner.pl")"
has "magic: an ordinary file is refused the same way (the subcommand does not exist at all)" "$r" "unknown subcommand: magic"
lacks "magic: runner.pl defines no cmd_magic" "$(cat "$RUNNER_REAL")" "cmd_magic"
lacks "magic: runner.pl dispatches no 'magic' subcommand" "$(cat "$RUNNER_REAL")" "eq 'magic'"
r="$(/bin/bash -c '. "$1"; if declare -F spike_magic_ok >/dev/null 2>&1; then echo DEFINED; else echo ABSENT; fi' _ "$COMMON2" 2>/dev/null)"
eq "magic: spike_magic_ok is not defined after sourcing common.sh" "ABSENT" "$r"
lacks "magic: common.sh does not mention spike_magic_ok" "$(cat "$COMMON_REAL")" "spike_magic_ok"
if command -v strace >/dev/null 2>&1 && strace -f -o "$SANDBOX/strace.probe2" -e trace=file /usr/bin/true >/dev/null 2>&1; then
  strace -f -e trace=file -o "$SANDBOX/strace.magic" /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C SPIKE_IN_PATH="$PATH" SPIKE_IN_TMPDIR="$SANDBOX" SPIKE_IN_HOME="$FH" /usr/bin/perl "$RUNNER2" magic "$FH/.claude/smallcred" >/dev/null 2>&1
  if [ "$(grep -c 'runner.pl' "$SANDBOX/strace.magic" 2>/dev/null)" -gt 0 ]; then ok "magic strace: the trace of the magic run was captured"; else bad "magic strace: the trace of the magic run was captured"; fi
  eq "magic strace: the canary file in a fake CLI home was never opened (no open/openat/creat on it)" "0" "$(grep -E '(open|openat|openat2|creat)\(' "$SANDBOX/strace.magic" | grep -c 'smallcred')"
else
  printf 'skip strace test of the removed magic subcommand: strace is not available or may not trace here (the unknown-subcommand test above covers it)\n'
fi

# --- item 8: capture and scratch roots inside a CLI home are refused -----------------------------------------------------------
EH="$SANDBOX/emptyhome"
sbx_mkdir "$EH/captures-ok"
FIRST="$(printf '%s\n' "$NAMES" | sed -n 1p)"
caproot() { # caproot <root>: spike_capture_dir demo with HOME = $EH or $FH as given by CAPHOME; prints the dir, returns its rc
  ( export HOME="${CAPHOME:-$EH}"; SPIKE_CAPTURES_ROOT="$1" spike_capture_dir demo )
}
CAPHOME="$FH" caproot "$FH/.claude/caps" >/dev/null 2>&1
eq "capture dir: a root inside an existing CLI home is refused (rc 2)" "2" "$?"
check_absent "capture dir: nothing was created inside the CLI home" "$FH/.claude/caps"
CAPHOME="$EH" caproot "$EH/$FIRST/a/b" >/dev/null 2>&1
eq "capture dir: a root under a not-yet-existing CLI home entry [$FIRST] is refused (rc 2)" "2" "$?"
check_absent "capture dir: the CLI home entry [$FIRST] was not created by mkdir -p" "$EH/$FIRST"
sbx_ln "$FH/.claude" "$SANDBOX/caplink"
CAPHOME="$FH" caproot "$SANDBOX/caplink/caps2" >/dev/null 2>&1
eq "capture dir: a root reached through a symlink into a CLI home is refused (rc 2)" "2" "$?"
check_absent "capture dir: nothing was created behind the symlink" "$FH/.claude/caps2"
CAPHOME="$EH" caproot "$EH/captures-ok" >/dev/null 2>&1
eq "capture dir: an ordinary root under the home is accepted (rc 0)" "0" "$?"
CAPHOME="$EH" caproot "$EH/captures-ok/" >/dev/null 2>&1
eq "capture dir: a root with a trailing slash is accepted (rc 0)" "0" "$?"
o="$(HOME="$FH" TMPDIR="$FH/.claude/tmp" spike_root 2>/dev/null)"
eq "spike_root: a TMPDIR inside a CLI home is refused (rc 1)" "1" "$(HOME="$FH" TMPDIR="$FH/.claude/tmp" spike_root >/dev/null 2>&1; echo $?)"
eq "spike_root: ...and it prints no root" "" "$o"
eq "spike_root: a TMPDIR under a not-yet-existing CLI home entry is refused (rc 1)" "1" "$(HOME="$EH" TMPDIR="$EH/$FIRST/tmp" spike_root >/dev/null 2>&1; echo $?)"
HOME="$FH" TMPDIR="$FH/.claude" spike_scratch_repo >/dev/null 2>&1
if [ "$?" -ne 0 ]; then ok "scratch repo: refused when TMPDIR is inside a CLI home"; else bad "scratch repo: refused when TMPDIR is inside a CLI home"; fi
check_absent "scratch repo: no harness-spike directory was created inside the CLI home" "$FH/.claude/harness-spike"
HOME="$FH" TMPDIR="$FH/.claude" spike_cleanup "$FH/.claude/harness-spike/run-x" >/dev/null 2>&1
eq "cleanup: refused when TMPDIR is inside a CLI home (rc 2)" "2" "$?"
eq "spike_root: an ordinary TMPDIR still works" "$SANDBOX/harness-spike" "$(spike_root)"
env -u SPIKE_LIVE HOME="$FH" TMPDIR="$FH/.claude" /bin/bash -c '. "$1"; spike_verify_init' _ "$COMMON" >/dev/null 2>&1
eq "verify directory: a parent inside a CLI home is still refused (rc 5)" "5" "$?"

# --- item 10a: the codesign the helper starts is watched and killed with its group -----------------------------------------
cs_gone() { # cs_gone <label>: the fake codesign (pids in cs.pids) and its sleep are gone within 3 s
  local cp cc
  read -r cp cc < "$FSDIR/cs.pids" 2>/dev/null
  if [ -n "$cp" ] && [ -n "$cc" ] && gone_within 30 "$cp" "$cc"; then ok "$1"; else bad "$1"; kill -9 "$cp" "$cc" 2>/dev/null; fi
}
fsmode hang
rm -f "$FSDIR/cs.pids"
# The helper is started as a direct child of an intermediate shell (so its parent is that shell), which is then SIGKILLed.
CSVD="$(rawhelper vdir-create $$)"
/bin/bash -c '"$@" & wait' _ /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C SPIKE_IN_PATH="$PATH" SPIKE_IN_TMPDIR="$SANDBOX" SPIKE_IN_HOME="$SANDBOX/home" /usr/bin/perl "$RUNNER" register "$CSVD" claude path "$RG/claude" >/dev/null 2>&1 &
CSCALLER=$!
n=0
while [ ! -s "$FSDIR/cs.pids" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
read -r CSP CSC < "$FSDIR/cs.pids" 2>/dev/null
if [ -n "$CSP" ] && alive "$CSP" && alive "$CSC"; then ok "codesign watch: the fake codesign hangs inside the registration"; else bad "codesign watch: the fake codesign hangs inside the registration"; fi
kill -9 "$CSCALLER" 2>/dev/null
cs_gone "codesign watch: after kill -9 of the caller, the codesign and its child are gone within 3 s (no orphan under init)"
{ wait "$CSCALLER"; } 2>/dev/null
rm -f "$FSDIR/cs.pids"
env -u SPIKE_LIVE /bin/bash -c '. "$1"; spike_mark_verified "$2" claude; echo "AFTER rc=$?"' _ "$COMMON" "$RG/claude" >| "$SANDBOX/cs-term.out" 2>&1 &
CSCALLER=$!
n=0
while [ ! -s "$FSDIR/cs.pids" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
HELPERPID="$(ps -eo pid=,args= | awk -v r="$RUNNER" 'index($0, r " register") > 0 && index($0, "awk") == 0 {print $1; exit}')"
if [ -n "$HELPERPID" ] && alive "$HELPERPID"; then ok "codesign watch: the registration helper is running (pid found)"; else bad "codesign watch: the registration helper is running (pid found)"; fi
[ -n "$HELPERPID" ] && kill -s TERM "$HELPERPID" 2>/dev/null
cs_gone "codesign watch: after TERM to the helper, the codesign and its child are gone within 3 s"
if gone_within 30 "$HELPERPID"; then ok "codesign watch: the helper itself ended after the TERM"; else bad "codesign watch: the helper itself ended after the TERM"; kill -9 "$HELPERPID" 2>/dev/null; fi
{ wait "$CSCALLER"; } 2>/dev/null
has "codesign watch: the caller survived the helper's TERM and saw a failed registration" "$(cat "$SANDBOX/cs-term.out")" "AFTER rc=2"
fsmode good

# --- item 10c: a sticky temporary directory owned by another user is refused ---------------------------------------------------
if [ "$(id -u)" = "0" ]; then
  sbx_mkdir "$SANDBOX/foreign-sticky" "$SANDBOX/root-sticky"
  chmod 1777 "$SANDBOX/foreign-sticky" "$SANDBOX/root-sticky"
  chown 65534 "$SANDBOX/foreign-sticky" 2>/dev/null
  if [ "$(ls -ldn "$SANDBOX/foreign-sticky" | awk '{print $3}')" = "65534" ]; then
    env -u SPIKE_LIVE TMPDIR="$SANDBOX/foreign-sticky" /bin/bash -c '. "$1"; spike_verify_init' _ "$COMMON" >/dev/null 2>&1
    eq "sticky temporary directory owned by another user is refused (rc 5)" "5" "$?"
    eq "no verify directory was created in the foreign sticky directory" "" "$(ls -A "$SANDBOX/foreign-sticky")"
  else
    printf 'skip foreign sticky test: chown is not permitted here\n'
  fi
  env -u SPIKE_LIVE TMPDIR="$SANDBOX/root-sticky" /bin/bash -c '. "$1"; spike_verify_init' _ "$COMMON" >/dev/null 2>&1
  eq "sticky temporary directory owned by root (the invoking user) is accepted (rc 0)" "0" "$?"
else
  printf 'skip foreign sticky test: needs root to hand a directory to another user\n'
fi
if [ "$(ls -ldn "$PHYS_TMP" | awk '{print $3}')" = "0" ] && [ -k "$PHYS_TMP" ]; then
  if libt 'parent_ok($ARGV[0])' "$PHYS_TMP"; then ok "a sticky temporary directory owned by root is an acceptable parent"; else bad "a sticky temporary directory owned by root is an acceptable parent"; fi
fi

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
